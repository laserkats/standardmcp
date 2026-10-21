module StandardMCP
  module Schema
    # What a caller can ask of a list or calculate for one controller's model:
    # the keys `where` and `order` take, the operators, and the associations
    # that can be included or reached through. The `describe_query` tool and the
    # schema resource return it, as one compact JSON document for an LLM to
    # read (no JSON Schema keywords; empty values and false flags are left out).
    #
    # The keys of `where` are what the ACL's `wheres` permit, which are
    # attributes (columns, or the where-dependent definitions of
    # `model_attribute_definitions`), `filter_on` filters and other names
    # permitted as they are. A column the ACL doesn't permit can't be filtered
    # on and isn't listed. Operators are given once per type; a key whose ACL
    # entry lists operators carries its own list. Associations are named with the
    # resource behind them and nothing more: to see an association's keys, describe
    # that resource.
    #
    # Sections the caller can't use are absent: `where` needs index or
    # calculate, `order` needs index, `include` needs index, show, create or
    # update.
    module QueryDocument
      WHERE_RULES = <<~TEXT.squish.freeze
        Every key takes an operator object, e.g. {"size": {"gte": 1000}}, {"name": {"eq": null}} for is null,
        {"name": {"not": null}} for is not null; all keys must match.
        To combine filters, pass an array alternating filters with "AND" or "OR", e.g. [{...}, "OR", {...}];
        it is evaluated left to right with no precedence.
        A key with an enum takes the "enum" operators. A "filter" key takes the value that filter expects.
      TEXT

      NESTING = <<~TEXT.squish.freeze
        To filter on an association's attributes, nest them under its name, e.g. {"%s": {...}};
        to see an association's keys, call describe_query on its resource.
      TEXT

      OPERATOR_NOTES = {
        text: 'For strings, like is a case-sensitive SQL pattern (% matches any run of characters), ilike is ' \
          'case-insensitive, and ts_match takes Postgres to_tsquery syntax or [query, language].',
        array: 'Array operators take lists.',
        json: 'For json, eq and not take null only.'
      }.freeze

      ORDER_RULES = <<~TEXT.squish.freeze
        Keys are applied in the order given. Each takes asc or desc, or {"asc": "nulls_first"} / {"desc": "nulls_last"}
        to place NULLs.
      TEXT

      class << self
        # +controller+ is an instance from Registry.controller_for. +actions+
        # are the ones allowed for the caller, +links+ maps a model to the
        # resource name that serves it, and +where+ is the where the agent will
        # list with (some keys depend on it). +definitions+ is the
        # Definitions::Result for it when the caller has built one.
        def for(controller, name:, actions:, links: {}, where: nil, definitions: nil)
          model = controller.class.model
          definitions ||= Definitions.for(controller, model, where)

          {
            'resource' => name,
            'description' => Description.table(model),
            'groups' => definitions.groups,
            'where' => ((actions & %i[index calculate]).any? ? where_section(controller, model, definitions, links) : nil),
            'order' => (actions.include?(:index) ? order_section(controller, model, definitions, links) : nil),
            'include' => ((actions & %i[index show create update]).any? ? include_section(controller, model, links) : nil)
          }.compact_blank
        end

        private

        # --- where

        def where_section(controller, model, definitions, links)
          permits = Query.permits(controller, model)
          keys = []
          associations = []
          operators = {}

          # The definitions' order first, then the other permitted names.
          names = definitions.names.select { |name| permits.key?(name) } | permits.keys

          names.each do |name|
            kind, reflection = Query.classify(model, definitions, name)

            case kind
            when :association
              association = Query.association_entry(model, reflection.name, links, kind: false)
              associations << association if association
            when :filter
              keys << { 'name' => name, 'kind' => 'filter' }
            when :attribute
              keys << attribute_key(controller, model, definition_for(model, definitions, name), permits[name], operators)
            else
              keys << { 'name' => name }
            end
          end

          {
            'keys' => keys,
            'operators' => operators,
            'associations' => associations,
            'rules' => where_rules(model, definitions, associations, operators)
          }.compact_blank
        end

        # The definition of a permitted attribute, or one made from its column
        # when the definitions leave it out.
        def definition_for(model, definitions, name)
          definitions.find(name) || begin
            column = model.columns_hash.fetch(name.split('.').first)
            { 'name' => name, 'type' => column.type.to_s, 'array' => column.array, 'comment' => column.comment }.compact
          end
        end

        def attribute_key(controller, model, definition, permitted, operators)
          name = definition['name']
          key = { 'name' => name }
          key['type'] = Definitions.type_label(definition)
          key['types'] = definition['types']
          key['enum'] = Input.definition_enum(model, definition)
          key['description'] = definition['comment'].presence || Description.column(model, name)
          key['only_in'] = definition['only_in']

          tables = operator_tables(model, definition)
          if permitted == :all
            tables.each { |label, table| operators[label] ||= table.keys }
          else
            key['operators'] = tables.values.flat_map { |table| Query.allowed_operators(controller, table.keys, permitted) }.uniq
          end

          key.compact_blank
        end

        # { label => operators } for the kinds of value an attribute holds: one,
        # or one per type when its type differs between groups. The label is
        # the type, or 'enum' for an attribute restricted to a list of values
        # (which takes equality and membership only).
        def operator_tables(model, definition)
          return { 'enum' => Input.definition_operators(model, definition) } if Input.definition_enum(model, definition)

          labels = definition['types'] ? definition['types'].values.uniq : [Definitions.type_label(definition)]
          labels.to_h do |label|
            [label || 'other', Input.definition_operators(model, typed(definition, label))]
          end
        end

        # +definition+ as it is for the type +label+ ("integer", "string[]").
        def typed(definition, label)
          return definition if label.nil? || definition['types'].nil?

          array = label.end_with?('[]')
          { 'name' => nil, 'type' => label.delete_suffix('[]'), 'array' => array }
        end

        def where_rules(model, definitions, associations, operators)
          notes = operator_notes(operators.keys)
          nesting = (format(NESTING, associations.first['name']) if associations.any?)
          [WHERE_RULES, notes, nesting].compact.join(' ')
        end

        # Sentences for the operator quirks of the types the document lists.
        def operator_notes(labels)
          kinds = labels.map { |label| label.end_with?('[]') ? :array : Input.type_kind(label) }.uniq
          kinds.filter_map { |kind| OPERATOR_NOTES[kind] }.join(' ').presence
        end

        # --- order

        def order_section(controller, model, definitions, links)
          keys = []
          associations = []

          Input.orders(controller).each do |entry|
            names = entry.is_a?(Hash) ? entry.keys : [entry]
            names.each do |name|
              reflection = model.reflect_on_association(name) unless model.columns_hash.key?(name) || definitions.find(name)
              if reflection
                association = Query.association_entry(model, name, links, kind: false)
                associations << association if association
              else
                keys << order_key(model, definitions, name)
              end
            end
          end

          rules = ORDER_RULES
          rules += " To order through an association, e.g. {\"#{associations.first['name']}\": {...}}, " \
            'see its keys with describe_query on its resource.' if associations.any?

          { 'keys' => keys, 'associations' => associations, 'rules' => rules }.compact_blank
        end

        def order_key(model, definitions, name)
          column = model.columns_hash[name]
          definition = definitions.find(name)
          definition ||= { 'name' => name, 'type' => column.type.to_s, 'array' => column.array } if column
          return { 'name' => name } unless definition

          { 'name' => name, 'type' => Definitions.type_label(definition), 'types' => definition['types'],
            'only_in' => definition['only_in'] }.compact_blank
        end

        # --- include

        def include_section(controller, model, links)
          Input.includes(controller).keys.filter_map { |name| Query.association_entry(model, name, links) }
        end
      end
    end
  end
end
