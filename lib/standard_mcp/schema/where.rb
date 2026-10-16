require 'json'
require 'json_schemer'

module StandardMCP
  module Schema
    # The `where` filter in shallow mode (Configuration#input_schema_depth).
    #
    # The schema is a loose object and the description carries the rules the
    # deep schema enforces: the operator object every column takes, the
    # operators per type, the filterable columns and the associations that can
    # be nested. Because the schema no longer rejects a bad filter, +errors+
    # checks a call against the model, with the same operator tables the deep
    # schema is built from, so the model gets a readable message instead of an
    # exception from activerecord-filter or Postgres.
    #
    # Hidden columns and associations, and associations the controller does
    # not permit to include, don't exist as far as a filter is concerned.
    module Where
      # Operators for each family of columns. Only the families a model has
      # are described.
      OPERATORS = {
        ordered: 'eq, not, in, not_in, gt, gte, lt, lte',
        text: 'like (case-sensitive SQL pattern, % matches any run of characters), ilike (case-insensitive pattern), ' \
          'ts_match (Postgres to_tsquery syntax, or [query, language])',
        boolean: 'eq, not',
        other: 'eq, not, in, not_in',
        array: 'eq, not, contains, contained_by, overlaps, excludes',
        json: 'eq and not (null only), contains, contained_by, has_key, has_keys, has_any_key',
        range: 'eq, not, contains, contained_by, overlaps',
        geometry: 'eq, contains, within, intersects, overlaps'
      }.freeze

      FAMILY_NAMES = { array: 'array columns', json: 'json', range: 'ranges', geometry: 'geometry' }.freeze

      NUMBERS = %i[integer bigint float decimal].freeze

      # Past this many characters a rejected value is cut in the message.
      VALUE_LENGTH = 60

      class << self
        # The `where` property of a tool's input schema. +tree+ is
        # Input.includes(controller). A filter is an object, or an array
        # alternating filters with AND/OR, hence both types.
        def schema(controller, model, tree)
          { 'type' => %w[object array], 'description' => description(controller, model, tree) }
        end

        # Why +where+ can't run, as messages for the model; empty when it can.
        # +where+ is String-keyed: a Hash, or an array alternating filters
        # with AND/OR.
        def errors(controller, where)
          check = Check.new(controller, Input.includes(controller))
          check.run(controller.class.model, where)
          check.errors
        end

        # The reflection when a filter can nest through +name+, else nil: the
        # controller must permit the include (+tree+), its class must resolve,
        # it can't be polymorphic, and a visible column of the same name wins.
        def association(controller, model, tree, name)
          return unless tree.key?(name.to_s)
          return if visible_columns(controller, model).any? { |column| column.name == name.to_s }

          reflection = model.reflect_on_association(name)
          reflection if reflection && !reflection.polymorphic? && Input.klass_for(reflection)
        end

        # "string", "string[]", or "office|retail" for an enum.
        def label(model, column)
          values = Input.allowed_values(model, column)
          return values.join('|') if values

          column.array ? "#{column.type}[]" : column.type.to_s
        end

        private

        def description(controller, model, tree)
          columns = visible_columns(controller, model)

          [
            'Filter records; all keys must match. Every key is a column or an association name, and every column ' \
              'takes an operator object, e.g. {"size": {"gte": 1000}}, {"kind": {"in": ["office", "retail"]}}, ' \
              '{"name": {"eq": null}} for is null, {"name": {"not": null}} for is not null.',
            operators(model, columns),
            "Columns:\n#{columns.map { |column| column_line(model, column) }.join("\n")}",
            associations(controller, model, tree),
            'To combine filters, pass an array alternating filters with "AND" or "OR", e.g. [{...}, "OR", {...}]; ' \
              'it is evaluated left to right with no precedence.'
          ].compact.join("\n")
        end

        def visible_columns(controller, model)
          hidden = Input.hidden(controller, model)
          model.columns.reject { |column| hidden.include?(column.name) }
        end

        # :enum for a column restricted to a list of values, else the kind
        # Input uses to pick its operators.
        def kind(model, column)
          Input.allowed_values(model, column) ? :enum : Input.column_kind(column)
        end

        def operators(model, columns)
          kinds = columns.map { |column| kind(model, column) }.uniq
          lines = []

          if kinds.include?(:ordered) || kinds.include?(:text)
            ordered = columns.select { |column| kind(model, column) == :ordered }
            words = []
            words << 'numbers' if ordered.any? { |column| NUMBERS.include?(column.type) }
            words << 'dates' if ordered.any? { |column| !NUMBERS.include?(column.type) }
            words << 'strings' if kinds.include?(:text)
            lines << "#{words.to_sentence(two_words_connector: ' and ', last_word_connector: ' and ')}: #{OPERATORS[:ordered]}"
          end
          lines << "strings also: #{OPERATORS[:text]}" if kinds.include?(:text)
          lines << "booleans: #{OPERATORS[:boolean]}" if kinds.include?(:boolean)
          lines << "enums, uuids and other types: #{OPERATORS[:other]}" if kinds.include?(:enum) || kinds.include?(:other)
          FAMILY_NAMES.each { |kind, name| lines << "#{name}: #{OPERATORS[kind]}" if kinds.include?(kind) }

          "Operators by column type:\n#{lines.join("\n")}"
        end

        # name (string): Display name of the organization.
        # kind (office|retail): Asset class of the property.
        def column_line(model, column)
          line = "#{column.name} (#{label(model, column)})"
          comment = Description.column(model, column.name)
          comment ? "#{line}: #{comment}" : line
        end

        # Every permitted include can be filtered through, at any depth;
        # where_depth only bounds the deep schema.
        def associations(controller, model, tree)
          entries = association_entries(controller, model, tree, nil)
          return if entries.empty?

          example = association_example(controller, model, tree)
          heading = 'Associations (filter on their columns by nesting them'
          heading += ", e.g. #{example}" if example
          heading += '; a dotted name nests inside the first: properties.photos is {"properties": {"photos": {...}}}' if entries.any? { |path, _| path.include?('.') }

          "#{heading}):\n#{entries.map(&:last).join("\n")}"
        end

        # [dotted path, "path: table comment"] for each association.
        def association_entries(controller, model, tree, prefix)
          tree.flat_map do |name, subtree|
            reflection = association(controller, model, tree, name)
            next [] unless reflection

            path = [prefix, name].compact.join('.')
            description = Input.association_description(model, reflection)
            [[path, description ? "#{path}: #{description}" : path]] +
              association_entries(controller, reflection.klass, subtree, path)
          end
        end

        # {"properties": {"name": {"eq": "Example"}}}, using a string column of
        # the first association when it has one.
        def association_example(controller, model, tree)
          name = tree.keys.find { |key| association(controller, model, tree, key) }
          return unless name

          klass = model.reflect_on_association(name).klass
          columns = visible_columns(controller, klass)
          column = columns.find { |c| kind(klass, c) == :text } || columns.first
          return unless column

          value = kind(klass, column) == :text ? '"Example"' : 'null'
          %({"#{name}": {"#{column.name}": {"eq": #{value}}}})
        end
      end

      # One walk over a where value, collecting every problem rather than
      # stopping at the first so the model can fix them together.
      class Check
        attr_reader :errors

        def initialize(controller, tree)
          @controller = controller
          @tree = tree
          @errors = []
        end

        def run(model, where)
          if where.is_a?(Array)
            sequence(model, where)
          else
            filter(model, where, nil, @tree)
          end
        end

        private

        def sequence(model, parts)
          alternating = parts.size.odd? && parts.each_with_index.all? do |part, index|
            index.odd? ? %w[AND OR].include?(part) : part.is_a?(Hash)
          end

          unless alternating
            @errors << 'A where array must alternate filter objects with "AND" or "OR", e.g. [{...}, "OR", {...}]'
            return
          end

          parts.each_slice(2) { |part, _| filter(model, part, nil, @tree) }
        end

        # +trail+ is the dotted path of associations that led to +model+.
        def filter(model, value, trail, tree)
          unless value.is_a?(Hash)
            @errors << "The filter#{" on #{trail}" if trail} must be an object of columns, got #{show(value)}"
            return
          end

          hidden = Input.hidden(@controller, model)
          value.each do |key, argument|
            key = key.to_s
            path = [trail, key].compact.join('.')
            column = model.columns_hash[key] unless hidden.include?(key)

            if column
              check_column(model, column, argument, path)
            elsif (reflection = Where.association(@controller, model, tree, key))
              filter(reflection.klass, argument, path, tree[key])
            else
              unknown(model, key, hidden, tree)
            end
          end
        end

        def unknown(model, key, hidden, tree)
          known = "columns: #{(model.column_names - hidden).join(', ')}"
          associations = tree.keys.select { |name| Where.association(@controller, model, tree, name) }
          known += "; associations: #{associations.join(', ')}" if associations.any?
          @errors << "Unknown column '#{key}' for #{model.table_name} (#{known})"
        end

        def check_column(model, column, value, path)
          operators = Input.column_operators(model, column)

          unless value.is_a?(Hash) && value.any?
            @errors << "#{path} takes an operator object such as {\"eq\": ...}, got #{show(value)}; " \
              "operators: #{operators.keys.join(', ')}"
            return
          end

          value.each do |operator, argument|
            schema = operators[operator.to_s]
            if schema.nil?
              @errors << "Unsupported operator '#{operator}' for #{path} (#{Where.label(model, column)}); " \
                "use #{operators.keys.join(', ')}"
            elsif !JSONSchemer.schema(schema).valid?(argument)
              @errors << "Invalid value for #{path}: #{show(argument)} (#{operator} expects #{expects(schema)})"
            end
          end
        end

        def show(value)
          text = JSON.generate(value)
          text.length > VALUE_LENGTH ? "#{text[0, VALUE_LENGTH]}..." : text
        end

        # A short phrase for what a value schema accepts.
        def expects(schema)
          if schema['enum']
            "one of #{schema['enum'].map { |v| v.nil? ? 'null' : v }.join(', ')}"
          elsif schema['anyOf']
            schema['anyOf'].map { |branch| expects(branch) }.join(' or ')
          elsif schema['type']
            Array(schema['type']).map { |type| expects_type(type, schema) }.join(' or ')
          else
            'a different value'
          end
        end

        # " of integers", " of values from a, b", or nothing when untyped.
        def items(schema)
          if schema.nil?
            ''
          elsif schema['enum']
            " of values from #{schema['enum'].join(', ')}"
          elsif schema['type'].is_a?(String)
            noun = { 'date' => 'dates', 'date-time' => 'datetimes' }[schema['format']] || "#{schema['type']}s"
            " of #{noun}"
          else
            ''
          end
        end

        def expects_type(type, schema)
          case type
          when 'array' then "an array#{items(schema['items'])}"
          when 'string'
            case schema['format']
            when 'date' then 'a date (YYYY-MM-DD)'
            when 'date-time' then 'a datetime (ISO 8601)'
            else 'a string'
            end
          when 'integer' then 'an integer'
          when 'number' then 'a number'
          when 'boolean' then 'a boolean'
          when 'object' then 'an object'
          else type
          end
        end
      end
    end
  end
end
