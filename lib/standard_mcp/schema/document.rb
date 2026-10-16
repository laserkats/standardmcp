module StandardMCP
  module Schema
    # The full detail of one controller's model for the caller, as one compact
    # JSON document for an LLM to read (no JSON Schema keywords): the
    # `standardmcp://schema/{resource}` resource and the `describe` tool return
    # it. The shallow tool schemas stay small and point here for the rest.
    #
    # Everything comes from the helpers the tool schemas are built with
    # (hidden columns, operator tables, enums, permitted includes and orders,
    # the ACL's attributes and nested), so it can't drift from what the tools
    # accept. Columns and associations an ACL hides are absent.
    #
    # Filter operators are given once per column type in `where`, not per
    # column: the type is on each column, and repeating the lists was most of
    # the document.
    #
    # Flags (nullable, orderable, writable, includable, filterable) are present
    # only when true, and empty values are left out. `writable` also needs the
    # caller to be allowed create or update.
    module Document
      KINDS = {
        belongs_to: 'belongs_to',
        has_many: 'has_many',
        has_one: 'has_one',
        has_and_belongs_to_many: 'habtm'
      }.freeze

      class << self
        # +controller+ is an instance from Registry.controller_for. +actions+
        # are the ones allowed for the caller. +links+ maps a model to the
        # resource name that serves it, for associations whose schema can be
        # read too.
        def for(controller, name:, actions:, links: {})
          klass = controller.class
          model = klass.model
          tree = Input.includes(controller)
          writes = (actions & %i[create update]).any?

          {
            'resource' => name,
            'table' => model.table_name,
            'description' => Description.table(model),
            'tools' => Tools::ACTIONS.select { |action| actions.include?(action) }.map { |action| Tools.tool_name(klass, action) },
            'columns' => columns(controller, model, actions),
            'associations' => associations(controller, model, tree, writes, links),
            'where' => Where.rules(controller, model, tree)
          }.compact_blank
        end

        private

        def columns(controller, model, actions)
          orders = Input.orders(controller).grep(String)
          permitted = Attributes.permitted(controller, model)

          Where.visible_columns(controller, model).map do |column|
            name = column.name
            entry = { 'name' => name, 'type' => type(column) }
            entry['nullable'] = true if column.null
            entry['description'] = Description.column(model, name)
            entry['enum'] = Input.allowed_values(model, column)
            entry['orderable'] = true if orders.include?(name)
            entry['writable'] = true if permitted.include?(name) && writable?(model, column, actions)
            entry.compact_blank
          end
        end

        # "integer", "string[]".
        def type(column)
          type = (column.type || column.sql_type).to_s
          column.array ? "#{type}[]" : type
        end

        def writable?(model, column, actions)
          %i[create update].any? { |action| actions.include?(action) && Attributes.writable?(model, column, action) }
        end

        # The associations the caller can include or write through, in the
        # order of the include tree.
        def associations(controller, model, tree, writes, links)
          nested = writes ? Attributes.nested(controller, model).map { |reflection| reflection.name.to_s } : []
          hidden = Input.hidden(controller, model)

          (tree.keys + nested).uniq.filter_map do |name|
            reflection = model.reflect_on_association(name)
            next if reflection.nil? || hidden.include?(name)

            klass = Input.klass_for(reflection) unless reflection.polymorphic?
            entry = { 'name' => name, 'kind' => KINDS.fetch(reflection.macro, reflection.macro.to_s) }
            entry['resource'] = links[klass] if klass
            entry['description'] = describe(model, reflection)
            entry['includable'] = true if tree.key?(name)
            entry['filterable'] = true if Where.association(controller, model, tree, name)
            entry['writable'] = 'nested' if nested.include?(name)
            entry.compact_blank
          end
        end

        # A polymorphic association has no class to take a comment from.
        def describe(model, reflection)
          if reflection.polymorphic?
            Description.column(model, reflection.foreign_key)
          else
            Input.association_description(model, reflection)
          end
        end
      end
    end
  end
end
