module StandardMCP
  module Schema
    # JSON Schema for a tool's arguments, derived from what StandardAPI would
    # accept for the caller: the model's columns, and the controller's ACL
    # `orders` and `includes`, resolved on a controller bound to the request.
    # Database comments become descriptions so the model can read the schema
    # as documentation of the domain.
    #
    # Schemas are built per call and never memoized: they depend on the
    # caller, and on the database, which can change under a dev reload.
    module Input
      ACTIONS = %i[index show create update destroy calculate].freeze

      # Keys StandardAPI accepts next to association names inside an include
      # tree; they scope the query rather than name a relation.
      RESERVED = StandardAPI::Controller::RESERVED_INCLUDE_KEYS

      # json_column_schema lives in a helper module meant for views.
      TYPES = Object.new.extend(StandardAPI::Helpers)
      private_constant :TYPES

      # The operators are documented here once rather than on every column's
      # filter; the filter definitions only enforce them.
      WHERE_DESCRIPTION = <<~TEXT.squish.freeze
        Filter records. Each key is a column, or an included association to filter on its columns; all keys must match.
        Every column takes an operator object, e.g. {"size": {"gte": 1000}}, {"kind": {"in": ["office", "retail"]}},
        {"name": {"eq": null}} for is null, {"name": {"not": null}} for is not null.
        Operators by column type:
        numbers, dates and strings: eq, not, in, not_in, gt, gte, lt, lte;
        strings also: like (case-sensitive SQL pattern, % matches any run of characters), ilike (case-insensitive pattern),
        ts_match (Postgres to_tsquery syntax, or [query, language]);
        booleans: eq, not;
        enums, uuids and other types: eq, not, in, not_in;
        array columns: eq, not, contains, contained_by, overlaps, excludes;
        json: eq and not (null only), contains, contained_by, has_key, has_keys, has_any_key;
        ranges: eq, not, contains, contained_by, overlaps;
        geometry: eq, contains, within, intersects, overlaps.
        To combine filters, pass an array alternating filters with "AND" or "OR", e.g. [{...}, "OR", {...}];
        it is evaluated left to right with no precedence.
      TEXT

      class << self
        # +controller+ is an instance from Registry.controller_for, so ACL
        # methods reflect the caller. Returns a String-keyed Hash.
        def for(controller, action)
          action = action.to_sym
          case action
          when :index then index(controller)
          when :show then show(controller)
          when :calculate then calculate(controller)
          when :create, :update then write(controller, action)
          when :destroy then destroy(controller)
          else
            raise ArgumentError, "Unknown action #{action.inspect}. Valid actions: #{ACTIONS.map(&:inspect).join(', ')}"
          end
        end

        # The includes the caller may request, as a String-keyed tree
        # ({ 'properties' => { 'photos' => {} } }). Associations that an ACL
        # `excludes` hides are dropped, as are StandardAPI's reserved keys.
        def includes(controller)
          tree = controller.send(:normalize_includes, controller.send(:includes_for, controller.class.model))
          prune_includes(controller, controller.class.model, tree)
        end

        # The ACL `orders` the caller may use: Strings, and Hashes for ordering
        # through an association ({ 'account' => ['name'] }). Hidden columns are
        # dropped.
        def orders(controller)
          prune_orders(controller, controller.class.model, controller.send(:orders_for, controller.class.model))
        end

        # Column and association names an ACL `excludes` removes from every
        # response. Excludes are decided per record, so this asks about a new
        # one; anything it can't answer for is treated as visible.
        def hidden(controller, model)
          return [] if model.nil?

          controller.send(:excludes, model.new).select { |_, v| v == true }.keys.map(&:to_s)
        rescue StandardError
          []
        end

        private

        def index(controller)
          model = controller.class.model
          tree = includes(controller)
          sorts = order_properties(model, orders(controller))
          defs = {}
          properties = { 'where' => where_property(controller, model, tree, defs) }
          if sorts.any?
            defs['direction'] = direction_schema
            properties['order'] = {
              'type' => 'object',
              'properties' => sorts,
              'additionalProperties' => false,
              'description' => 'Sort order, keyed by column. Keys apply in the order given.'
            }
          end
          properties['include'] = include_schema(model, tree) if tree.any?
          properties['limit'] = limit_schema(controller)
          properties['offset'] = { 'type' => 'integer', 'minimum' => 0, 'description' => 'Number of records to skip.' }
          properties['distinct'] = {
            'type' => 'boolean',
            'description' => 'Remove duplicate records. Use when filtering through a has-many association.'
          }

          root(properties, [], defs)
        end

        def show(controller)
          model = controller.class.model
          tree = includes(controller)
          properties = { 'id' => id_schema(model) }
          properties['include'] = include_schema(model, tree) if tree.any?

          root(properties, ['id'])
        end

        def calculate(controller)
          model = controller.class.model
          hide = hidden(controller, model)
          columns = model.columns.reject { |c| hide.include?(c.name) }
          defs = {}
          properties = {
            'where' => where_property(controller, model, includes(controller), defs),
            'select' => select_schema(columns),
            'group_by' => {
              'enum' => columns.reject { |c| ungroupable?(c) }.map(&:name),
              'description' => 'Column to group by; the result is then keyed by its value. Takes a single aggregate in select.'
            }
          }

          # StandardAPI builds the grouped result with Hash[[key, value], ...],
          # so a second aggregate raises (a 500) instead of failing validation.
          root(properties, ['select'], defs).merge(
            'if' => { 'required' => ['group_by'] },
            'then' => { 'properties' => { 'select' => {
              'maxItems' => 1,
              'items' => { 'maxProperties' => 1 }
            } } }
          )
        end

        # The record goes under its singular name, which is the key StandardAPI
        # requires (`params.require(:property)`); an update also names the
        # record to change.
        def write(controller, action)
          model = controller.class.model
          tree = includes(controller)
          key = model.model_name.singular
          properties = {}
          properties['id'] = id_schema(model) if action == :update
          properties[key] = Attributes.schema(controller, model, action)
          properties['include'] = include_schema(model, tree) if tree.any?

          root(properties, action == :update ? ['id', key] : [key])
        end

        def destroy(controller)
          root({ 'id' => id_schema(controller.class.model, one: true) }, ['id'])
        end

        def root(properties, required, defs = {})
          schema = { 'type' => 'object', 'properties' => properties, 'required' => required, 'additionalProperties' => false }
          schema['$defs'] = defs if defs.any?
          schema
        end

        # --- where

        # The `where` property for the configured depth. In deep mode the typed
        # filter is registered in +defs+ (the property refers to it).
        def where_property(controller, model, tree, defs)
          return Where.schema(controller, model, tree) unless StandardMCP.config.deep_input_schema?

          defs['where'] = where_object(controller, model, tree, defs)
          where_schema
        end

        # A filter, or an AND/OR sequence of filters. The filter lives in
        # $defs so the sequence can refer back to it.
        def where_schema
          {
            'description' => WHERE_DESCRIPTION,
            'anyOf' => [
              { '$ref' => '#/$defs/where' },
              {
                'type' => 'array',
                'minItems' => 1,
                'items' => { 'anyOf' => [{ '$ref' => '#/$defs/where' }, { 'enum' => %w[AND OR] }] }
              }
            ]
          }
        end

        # +depth+ is how many association levels may still nest below this
        # model (Configuration#where_depth at the top).
        def where_object(controller, model, tree, defs, depth = StandardMCP.config.where_depth.to_i)
          hidden = hidden(controller, model)
          properties = {}

          model.columns.each do |column|
            next if hidden.include?(column.name)

            properties[column.name] = column_filter(model, column, defs)
          end

          tree.each do |name, subtree|
            break unless depth > 0

            reflection = model.reflect_on_association(name)
            klass = klass_for(reflection)
            next if klass.nil? || reflection.polymorphic? || properties.key?(name)

            description = association_description(model, reflection)
            object = where_object(controller, klass, subtree, defs, depth - 1)
            properties[name] = description ? { 'description' => description }.merge(object) : object
          end

          { 'type' => 'object', 'properties' => properties, 'additionalProperties' => false }
        end

        # A belongs_to column's comment describes the relation better than the
        # target table's; collections and throughs have no FK on this table.
        def association_description(model, reflection)
          fk = Description.column(model, reflection.foreign_key) if reflection.belongs_to?
          fk || Description.table(klass_for(reflection))
        end

        # nil for a reflection whose class doesn't exist (or no reflection).
        def klass_for(reflection)
          reflection&.klass
        rescue NameError
          nil
        end

        # Every column takes only an operator object; activerecord-filter's
        # shorthands (scalar, list, null, bare true/false) are sugar for it and
        # are left out so there is one shape to learn. The filters for columns
        # of the same type are identical apart from the comment, so they are
        # shared through $defs (one per type, e.g. integer_filter). An enum
        # column instead gets its own filter with the values inline.
        def column_filter(model, column, defs)
          schema = {}
          comment = Description.column(model, column.name)
          schema['description'] = comment if comment

          values = allowed_values(model, column)
          return schema.merge(enum_filter(values)) if values

          kind = column_kind(column)
          value = value_schema(column)
          schema.merge('$ref' => "#/$defs/#{define(defs, filter_name(kind, column, value), type_filter(kind, value))}")
        end

        # The operators (String-keyed, each mapped to the schema of its value) a
        # column accepts: what column_filter enforces in deep mode and
        # Schema::Where checks calls against in shallow mode.
        def column_operators(model, column)
          values = allowed_values(model, column)
          return enum_filter(values)['properties'] if values

          operators(column_kind(column), value_schema(column))
        end

        # Equality and membership only; comparing or pattern matching an enum
        # would be meaningless.
        def enum_filter(values)
          list = { 'type' => 'array', 'items' => { 'enum' => values } }
          nullable = { 'enum' => values + [nil] }

          {
            'type' => 'object',
            'additionalProperties' => false,
            'minProperties' => 1,
            'properties' => { 'eq' => nullable, 'not' => nullable, 'in' => list, 'not_in' => list }
          }
        end

        # integer_filter, string_filter, date_filter, datetime_filter,
        # string_array_filter, json_filter, ...
        def filter_name(kind, column, value)
          label = case value['format']
          when 'date' then 'date'
          when 'date-time' then 'datetime'
          else value['type']
          end

          case kind
          when :text then 'string_filter'
          when :array then "#{label || 'any'}_array_filter"
          when :ordered then "#{label}_filter"
          when :other then "#{column.type}_filter"
          else "#{kind}_filter"
          end
        end

        def type_filter(kind, value)
          { 'type' => 'object', 'additionalProperties' => false, 'minProperties' => 1, 'properties' => operators(kind, value) }
        end

        # [type, 'null'] in place of an anyOf with a null branch. A value
        # without a type already allows null.
        def nullable(value)
          value['type'].is_a?(String) ? value.merge('type' => [value['type'], 'null']) : value
        end

        # Registers +schema+ under +name+ (or +name+_2, ... when a different
        # schema already holds it, e.g. two column types sharing a label) and
        # returns the name used.
        def define(defs, name, schema)
          candidate = name
          suffix = 1
          while defs.key?(candidate) && defs[candidate] != schema
            suffix += 1
            candidate = "#{name}_#{suffix}"
          end
          defs[candidate] = schema
          candidate
        end

        # The activerecord-filter operators that make sense for a kind of
        # column (predicate_builder_extension.rb, expand_filter_for_arel_attribute).
        # Only canonical names are listed; it also accepts aliases such as
        # equal_to, neq and gteq.
        # Documented once, in WHERE_DESCRIPTION.
        def operators(kind, value)
          nullable = nullable(value)
          list = { 'type' => 'array', 'items' => value }
          equality = { 'eq' => nullable, 'not' => nullable }
          membership = { 'in' => list, 'not_in' => list }
          comparison = { 'gt' => value, 'gte' => value, 'lt' => value, 'lte' => value }

          case kind
          when :boolean
            equality
          when :ordered
            equality.merge(membership, comparison)
          when :text
            equality.merge(membership, comparison,
              'like' => { 'type' => 'string' },
              'ilike' => { 'type' => 'string' },
              'ts_match' => {
                'anyOf' => [{ 'type' => 'string' }, { 'type' => 'array', 'items' => { 'type' => 'string' }, 'minItems' => 1, 'maxItems' => 2 }]
              })
          when :array
            # eq and not compare whole arrays: a scalar is not cast (only the
            # bare shorthand wraps it), so every operator takes a list.
            whole = { 'type' => %w[array null], 'items' => value }
            { 'eq' => whole, 'not' => whole, 'contains' => list, 'contained_by' => list,
              'overlaps' => list, 'excludes' => list }
          when :json
            keys = { 'type' => 'array', 'items' => { 'type' => 'string' } }
            # eq and not take null only (is null / is not null).
            { 'eq' => { 'type' => 'null' }, 'not' => { 'type' => 'null' }, 'contains' => {}, 'contained_by' => {},
              'has_key' => { 'type' => 'string' }, 'has_keys' => keys, 'has_any_key' => keys }
          when :range
            { 'eq' => {}, 'not' => {}, 'contains' => {}, 'contained_by' => {}, 'overlaps' => {} }
          when :geometry
            shape = { 'anyOf' => [{ 'type' => 'string' }, { 'type' => 'object' }] }
            { 'eq' => shape, 'contains' => shape, 'within' => shape, 'intersects' => shape, 'overlaps' => shape }
          else
            equality.merge(membership)
          end
        end

        def column_kind(column)
          sql_type = column.sql_type.to_s.downcase
          return :array if column.array
          return :geometry if sql_type.start_with?('geometry')
          return :range if sql_type.end_with?('range')

          case column.type
          when :json, :jsonb, :hstore then :json
          when :boolean then :boolean
          when :string, :text, :citext then :text
          when :integer, :bigint, :float, :decimal, :date, :datetime, :time, :timestamp, :timestamptz then :ordered
          else :other
          end
        end

        # The JSON type of one value of the column: StandardAPI's mapping for
        # the json_schema view.
        def value_schema(column)
          (TYPES.json_column_schema(column.sql_type) || fallback_type(column)).transform_keys(&:to_s)
        end

        def fallback_type(column)
          scalar_schema(column.type)
        end

        # The JSON type of an ActiveRecord type (a symbol such as :integer).
        def scalar_schema(type)
          case type
          when :integer, :bigint then { type: 'integer' }
          when :float, :decimal then { type: 'number' }
          when :boolean then { type: 'boolean' }
          when :string, :text, :citext, :uuid, :inet then { type: 'string' }
          when :date then { type: 'string', format: 'date' }
          when :datetime, :time, :timestamp, :timestamptz then { type: 'string', format: 'date-time' }
          else {}
          end
        end

        def allowed_values(model, column)
          if model.type_for_attribute(column.name).is_a?(ActiveRecord::Enum::EnumType)
            return model.defined_enums.fetch(column.name).keys
          end

          model.validators_on(column.name.to_sym).each do |validator|
            next unless validator.is_a?(ActiveModel::Validations::InclusionValidator)
            next if validator.options[:if] || validator.options[:unless] || validator.options[:on]

            values = validator.options[:in] || validator.options[:within]
            return values.as_json if values.is_a?(Array)
          end
          nil
        end

        # --- order

        def order_properties(model, permit)
          permit.each_with_object({}) do |entry, properties|
            if entry.is_a?(Hash)
              entry.each { |name, sub| properties[name] = nested_order(model, name, sub) }
            else
              properties[entry] = { '$ref' => '#/$defs/direction' }
              comment = Description.column(model, entry)
              properties[entry]['description'] = comment if comment
            end
          end
        end

        # Ordering through an association: { 'account' => { 'name' => 'asc' } }.
        def nested_order(model, name, sub)
          reflection = model.reflect_on_association(name)
          description = association_description(model, reflection)
          schema = description ? { 'description' => description } : {}
          schema.merge(
            'type' => 'object',
            'properties' => order_properties(klass_for(reflection), sub),
            'additionalProperties' => false
          )
        end

        def direction_schema
          {
            'description' => 'asc or desc, or {"asc": "nulls_first"} / {"desc": "nulls_last"} to place NULLs.',
            'anyOf' => [
              { 'enum' => %w[asc desc] },
              {
                'type' => 'object',
                'properties' => {
                  'asc' => { 'enum' => %w[nulls_first nulls_last] },
                  'desc' => { 'enum' => %w[nulls_first nulls_last] }
                },
                'additionalProperties' => false,
                'minProperties' => 1,
                'maxProperties' => 1
              }
            ]
          }
        end

        # Associations whose class can't be resolved are dropped: there is
        # nothing to describe them with.
        def prune_orders(controller, model, permit)
          hidden = hidden(controller, model)

          Array(permit).flatten.each_with_object([]) do |entry, pruned|
            if entry.is_a?(Hash)
              entry.each do |name, sub|
                klass = klass_for(model.reflect_on_association(name))
                next if klass.nil? || hidden.include?(name.to_s)

                pruned << { name.to_s => prune_orders(controller, klass, sub) }
              end
            else
              pruned << entry.to_s unless hidden.include?(entry.to_s)
            end
          end
        end

        # --- include

        def include_schema(model, tree)
          {
            'type' => 'object',
            'properties' => include_properties(model, tree),
            'additionalProperties' => false,
            'description' => 'Associations to load with each record; nest to load deeper, e.g. {"properties": {"photos": {}}}.'
          }
        end

        def include_properties(model, tree)
          tree.each_with_object({}) do |(name, subtree), properties|
            reflection = model&.reflect_on_association(name)
            nested = include_properties(klass_for(reflection), subtree)
            if reflection&.collection?
              nested['limit'] = { 'type' => 'integer', 'minimum' => 1, 'description' => 'Maximum number of associated records.' }
            end

            schema = {
              'anyOf' => [
                { 'const' => true },
                { 'type' => 'object', 'properties' => nested, 'additionalProperties' => false }
              ]
            }
            description = reflection && association_description(model, reflection)
            schema['description'] = description if description
            properties[name] = schema
          end
        end

        def prune_includes(controller, model, tree)
          hidden = hidden(controller, model)

          tree.each_with_object({}) do |(name, subtree), pruned|
            next if RESERVED.include?(name.to_s) || hidden.include?(name.to_s)

            klass = klass_for(model&.reflect_on_association(name))
            pruned[name.to_s] = prune_includes(controller, klass, subtree)
          end
        end

        # --- limit, id

        def limit_schema(controller)
          maximum = controller.send(:resource_limit)
          default = controller.send(:default_limit) || StandardMCP.config.default_limit
          default = [default, maximum].min if default && maximum

          schema = { 'type' => 'integer', 'minimum' => 1 }
          schema['maximum'] = maximum if maximum
          schema['default'] = default if default
          schema['description'] = 'Maximum number of records to return.'
          schema
        end

        # +one+ for destroy, which StandardAPI also takes a comma-separated list
        # of ids for; a string id must not be able to name several records.
        def id_schema(model, one: false)
          column = model.columns_hash[model.primary_key] if model.primary_key.is_a?(String)
          type = column ? value_schema(column).slice('type', 'format') : { 'type' => 'string' }
          type['pattern'] = '^[^,]+$' if one && type['type'] == 'string'
          type.merge('description' => "ID of the #{model.model_name.human.downcase}")
        end

        # --- calculate

        def ungroupable?(column)
          %i[json jsonb hstore binary].include?(column.type)
        end

        def select_schema(columns)
          scalar = columns.reject { |c| c.array || ungroupable?(c) }
          orderable = scalar.select { |c| column_kind(c) == :text || column_kind(c) == :ordered }.reject { |c| c.type == :uuid }
          numeric = scalar.select { |c| %i[integer bigint float decimal].include?(c.type) }

          functions = {}
          functions['minimum'] = { 'enum' => orderable.map(&:name) } if orderable.any?
          functions['maximum'] = { 'enum' => orderable.map(&:name) } if orderable.any?
          functions['average'] = aggregate_argument(numeric.map(&:name)) if numeric.any?
          functions['sum'] = aggregate_argument(numeric.map(&:name)) if numeric.any?
          functions['count'] = aggregate_argument(scalar.map(&:name), star: true)

          {
            'type' => 'array',
            'minItems' => 1,
            'items' => { 'type' => 'object', 'properties' => functions, 'additionalProperties' => false, 'minProperties' => 1 },
            'description' => 'Aggregates to compute, e.g. [{"count": "*"}, {"maximum": "size"}, {"count": {"distinct": "name"}}].'
          }
        end

        # A column name, or {"distinct": column}. Only count takes '*'.
        def aggregate_argument(names, star: false)
          {
            'anyOf' => [
              { 'enum' => star ? names + ['*'] : names },
              {
                'type' => 'object',
                'properties' => { 'distinct' => { 'enum' => names } },
                'required' => ['distinct'],
                'additionalProperties' => false
              }
            ]
          }
        end

        # Shared with Schema::Where, which describes and checks filters with the
        # same tables, and Schema::Attributes, which types the written record.
        public :column_kind, :column_operators, :allowed_values, :klass_for, :association_description,
          :value_schema, :scalar_schema, :nullable, :id_schema
      end
    end
  end
end
