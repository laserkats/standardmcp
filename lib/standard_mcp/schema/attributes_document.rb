module StandardMCP
  module Schema
    # What a record of one controller's model contains, for reads and writes:
    # each attribute's type, comment, enum and whether the caller can write it,
    # must send it on create, or may find it withheld for privacy. The
    # `describe_attributes` tool and the schema resource return it, as one
    # compact JSON document for an LLM to read (empty values and false flags
    # are left out).
    #
    # The attributes are the definitions of `model_attribute_definitions` for
    # the where the agent passed, so a where that selects a group of records
    # shows that group's attributes, and a where spanning groups shows all of
    # them, marked `only_in` or `types` (see Definitions). Attributes an ACL
    # `excludes` hides are absent.
    #
    # `writable` needs the caller to be allowed create or update and the
    # definition to say the attribute can be set: not `read_only`, a primary
    # key, filled in by the database, or a timestamp. `required` needs create
    # and a definition that says `required` with no default. StandardAPI's
    # `required` follows presence validators and NOT NULL columns, which misses
    # the foreign key of a `belongs_to` that must be present, so that counts too,
    # as it does for the write tools' schemas (Schema::Attributes).
    #
    # Associations are the ones the caller can include and, for a writer, the
    # ACL's `nested` ones, by name, kind and the resource behind them.
    module AttributesDocument
      NOTES = {
        'withheld' => 'withheld: the value may be left out of a record for privacy.',
        'writable' => 'writable: create_*/update_* can set it.',
        'required' => 'required: create_* must send it.',
        'only_in' => 'only_in: the attribute exists only in those groups.',
        'types' => 'types: its type in each group.'
      }.freeze

      NESTED = 'writable "nested": records of the association can be written through this one.'.freeze

      class << self
        # See QueryDocument.for for the arguments.
        def for(controller, name:, actions:, links: {}, where: nil, definitions: nil)
          model = controller.class.model
          definitions ||= Definitions.for(controller, model, where)
          permitted = Attributes.permitted(controller, model)
          belongs = Attributes.required_foreign_keys(model)

          attributes = definitions.entries.map { |definition| attribute(model, definition, actions, permitted, belongs) }
          associations = associations(controller, model, actions, links)

          {
            'resource' => name,
            'description' => Description.table(model),
            'groups' => definitions.groups,
            'attributes' => attributes,
            'associations' => associations,
            'notes' => notes(attributes, associations)
          }.compact_blank
        end

        private

        def attribute(model, definition, actions, permitted, belongs)
          name = definition['name']
          writable = writable?(model, definition, actions, permitted)

          {
            'name' => name,
            'type' => Definitions.type_label(definition),
            'types' => definition['types'],
            'enum' => Input.definition_enum(model, definition),
            'nullable' => (true if definition['null']),
            'description' => definition['comment'].presence || Description.column(model, name),
            'writable' => (true if writable),
            'required' => (true if writable && required?(definition, actions, belongs)),
            'withheld' => (true if definition['withheld']),
            'only_in' => definition['only_in']
          }.compact_blank
        end

        def writable?(model, definition, actions, permitted)
          writes = %i[create update].select { |action| actions.include?(action) }
          return false if writes.empty?

          name = definition['name']
          return false if definition.fetch('read_only') { permitted.exclude?(name) }

          column = model.columns_hash[name]
          if column
            writes.any? { |action| Attributes.writable?(model, column, action) }
          else
            !definition['primary_key'] && !definition['auto_populated'] && !Attributes.timestamps(model).include?(name)
          end
        end

        # Only a create has to send it, and a default fills it in otherwise.
        def required?(definition, actions, belongs)
          return false unless actions.include?(:create) && definition['default'].nil?

          definition['required'] == true || belongs.include?(definition['name'])
        end

        def associations(controller, model, actions, links)
          includable = (actions & %i[index show create update]).any? ? Input.includes(controller).keys : []
          nested = (actions & %i[create update]).any? ? Attributes.nested(controller, model).map { |reflection| reflection.name.to_s } : []
          hidden = Input.hidden(controller, model)

          (includable + nested).uniq.filter_map do |name|
            next if hidden.include?(name)

            entry = Query.association_entry(model, name, links)
            entry['writable'] = 'nested' if entry && nested.include?(name)
            entry
          end
        end

        def notes(attributes, associations)
          flags = attributes.flat_map(&:keys)
          sentences = NOTES.filter_map { |flag, sentence| sentence if flags.include?(flag) }
          sentences << NESTED if associations.any? { |association| association['writable'] }
          sentences.join(' ')
        end
      end
    end
  end
end
