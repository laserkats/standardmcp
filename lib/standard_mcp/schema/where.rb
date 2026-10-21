require 'json'
require 'json_schemer'

module StandardMCP
  module Schema
    # The `where` filter in shallow mode (Configuration#input_schema_depth), and
    # the checks every call's filter, order and include go through.
    #
    # The shallow schema is a loose object and a sentence: the keys, operators
    # and associations are what `describe_query` returns (QueryDocument), not
    # something every tool list repeats. Because the schema doesn't reject a bad
    # filter, +errors+ checks a call against the model the way StandardAPI will,
    # with the same operator tables the deep schema is built from, so the agent
    # gets a readable message, one that names the describe call to make, instead
    # of an exception from activerecord-filter or Postgres.
    #
    # Nothing is stateful: no describe call is needed first. A key is resolved
    # against the ACL's `wheres` of the model and, at the top level, the
    # definitions for the where the agent passed (Definitions); records reached
    # through an association are judged by their own ACL, with the definitions
    # for no where.
    module Where
      # The filter doesn't hold up. +errors+ are messages for the agent.
      class Invalid < StandardMCP::Error
        attr_reader :errors

        def initialize(errors)
          @errors = errors
          super(errors.join('; '))
        end
      end

      # Past this many characters a rejected value is cut in the message.
      VALUE_LENGTH = 60

      AGGREGATES = %w[minimum maximum average sum count].freeze

      class << self
        # The `where` property of a tool's input schema in shallow mode. A
        # filter is an object, or an array alternating filters with AND/OR,
        # hence both types.
        def schema(controller)
          call = Description.describe_call(controller, 'describe_query')
          sentences = ['Filter records with operator objects, e.g. {"size": {"gte": 1000}}; all keys must match.']
          sentences << "Keys, operators and associations: #{call} (pass the same where)." if call

          { 'type' => %w[object array], 'description' => sentences.join(' ') }
        end

        # Why +where+ can't run, as messages for the agent; empty when it can.
        # +where+ is String-keyed: a Hash, or an array alternating filters with
        # AND/OR. +definitions+ is the Definitions::Result for it when the
        # caller already has one (the hook is asked once per call).
        def errors(controller, where, definitions: nil)
          return [] if where.nil?

          shape = Check.shape_errors(where)
          return shape if shape.any?

          definitions ||= Definitions.for(controller, controller.class.model, where)
          check = Check.new(controller, definitions)
          check.run(where)
          check.errors
        end

        # The definitions for +where+, once it has checked out; raises Invalid
        # with the problems when it hasn't. For the describe tools, which tell
        # the agent about a where it could not use.
        def checked_definitions(controller, where)
          model = controller.class.model
          return Definitions.for(controller, model, nil) if where.nil?

          shape = Check.shape_errors(where)
          raise Invalid, shape if shape.any?

          definitions = Definitions.for(controller, model, where)
          problems = errors(controller, where, definitions: definitions)
          raise Invalid, problems if problems.any?

          definitions
        end

        # Problems with a call's top-level `order` and `include` (the keys of
        # nested ones are StandardAPI's to check).
        def order_errors(controller, order)
          return [] if order.nil?

          permitted = Input.orders(controller).flat_map { |entry| entry.is_a?(Hash) ? entry.keys : [entry] }
          unknown = keys_of(order).reject { |key| permitted.include?(key.split('.').first) }
          unknown.map do |key|
            ["Unknown order key '#{key}' for #{Resources.resource_name(controller.class)}.",
              hint(controller, 'to see the keys you can order by')].compact.join(' ')
          end
        end

        def include_errors(controller, include)
          return [] if include.nil?

          permitted = Input.includes(controller).keys
          unknown = keys_of(include).reject { |key| permitted.include?(key) }
          unknown.map do |key|
            ["Unknown include key '#{key}' for #{Resources.resource_name(controller.class)}.",
              hint(controller, 'to see the associations you can include')].compact.join(' ')
          end
        end

        # Problems with a calculate's `select` and `group_by`, which are
        # aggregated in SQL and so name real columns only (never a dotted name,
        # which StandardAPI would turn into a model).
        def calculate_errors(controller, select, group_by)
          return [] if select.nil? && group_by.nil?

          model = controller.class.model
          resource = Resources.resource_name(controller.class)
          hidden = Input.hidden(controller, model)
          columns = model.columns.reject { |column| hidden.include?(column.name) }
          names = Input.aggregate_names(columns)
          unknown = ->(name, where) do
            ["Unknown attribute #{show(name)} in #{where} for #{resource}.",
              hint(controller, 'to see the attributes', tool: 'describe_attributes')].compact.join(' ')
          end
          errors = []

          Array(select).each do |item|
            next unless item.is_a?(Hash)

            item.each do |function, argument|
              function = function.to_s
              unless AGGREGATES.include?(function)
                errors << "Unknown aggregate '#{function}' in select; use #{AGGREGATES.join(', ')}."
                next
              end

              column = argument.is_a?(Hash) ? argument['distinct'] : argument
              takes = names.fetch(function, [])
              if argument.is_a?(Hash) && %w[minimum maximum].include?(function)
                errors << "#{function} doesn't take distinct."
              elsif takes.include?(column) || (function == 'count' && column == '*' && !argument.is_a?(Hash))
                next
              elsif columns.none? { |candidate| candidate.name == column }
                errors << unknown.call(column, "select")
              else
                errors << "#{function} can't be used on '#{column}'#{"; it takes: #{takes.join(', ')}" if takes.any?}."
              end
            end
          end

          if group_by
            groupable = columns.reject { |column| Input.ungroupable?(column) }.map(&:name)
            errors << unknown.call(group_by, 'group_by') unless groupable.include?(group_by)
          end

          errors
        end

        # "Call describe_query {...} to see the keys you can filter on.", or nil
        # without the describe tools. +with_where+ says the where passed
        # matters to the answer.
        def hint(controller, purpose, resource: nil, with_where: false, tool: 'describe_query')
          return unless StandardMCP.config.describe_tools

          call = %(#{tool} {"resource": "#{resource || Resources.resource_name(controller.class)}"})
          "Call #{call}#{' with this where' if with_where} #{purpose}."
        end

        # A value as it reads in a message, cut when long.
        def show(value)
          text = JSON.generate(value)
          text.length > VALUE_LENGTH ? "#{text[0, VALUE_LENGTH]}..." : text
        end

        private

        # The names an `order` or `include` argument uses at its top level: a
        # Hash's keys, an Array's Strings and Hash keys, or a String.
        def keys_of(value)
          case value
          when Hash then value.keys.map(&:to_s)
          when Array then value.flatten.flat_map { |item| keys_of(item) }
          when String, Symbol then [value.to_s]
          else []
          end
        end
      end

      # One walk over a where value, collecting every problem rather than
      # stopping at the first so the agent can fix them together.
      class Check
        attr_reader :errors

        # The messages for a where that isn't a filter or an AND/OR array of
        # them, which can't be walked at all.
        def self.shape_errors(where)
          case where
          when Hash then []
          when Array
            alternating = where.size.odd? && where.each_with_index.all? do |part, index|
              index.odd? ? %w[AND OR].include?(part) : part.is_a?(Hash)
            end
            alternating ? [] : ['A where array must alternate filter objects with "AND" or "OR", e.g. [{...}, "OR", {...}]']
          else
            ["The filter must be an object of keys, got #{Where.show(where)}"]
          end
        end

        # +definitions+ is the Definitions::Result of the controller's model for
        # the where being checked.
        def initialize(controller, definitions)
          @controller = controller
          @definitions = definitions
          @errors = []
          @permits = {}
        end

        def run(where)
          model = @controller.class.model
          if where.is_a?(Array)
            where.each_slice(2) { |part, _| filter(model, part, nil, @definitions) }
          else
            filter(model, where, nil, @definitions)
          end
        end

        private

        # +trail+ is the dotted path of associations that led to +model+;
        # +definitions+ is nil below the top level.
        def filter(model, value, trail, definitions)
          unless value.is_a?(Hash)
            @errors << "The filter#{" on #{trail}" if trail} must be an object of keys, got #{show(value)}"
            return
          end

          permits = permits(model)
          value.each do |key, argument|
            key = key.to_s
            path = [trail, key].compact.join('.')
            permitted = permits.fetch(key.split('.').first) do
              permits[(key.sub(/_ids\z/, 's') if key.end_with?('_ids'))]
            end

            if permitted.nil?
              unknown(model, key, trail)
              next
            end

            kind, reflection = Query.classify(model, definitions, key)
            case kind
            when :attribute
              check_attribute(model, definitions, key, permitted, argument, path)
            when :association
              below(model, reflection, argument, path)
            when :other
              ids = model.reflect_on_association(key.sub(/_ids\z/, 's')) if key.end_with?('_ids')
              below(model, ids, { 'id' => argument }, path) if ids
            end
          end
        end

        # What is below an association is judged by the associated model's own
        # ACL. A polymorphic association has no model until `as` names one,
        # which StandardAPI checks.
        def below(model, reflection, argument, path)
          return if reflection.polymorphic?

          klass = Input.klass_for(reflection)
          filter(klass, argument, path, nil) if klass
        end

        def permits(model)
          @permits[model] ||= Query.permits(@controller, model)
        end

        def unknown(model, key, trail)
          resource = resource_for(model)
          under = " (under #{trail})" if trail
          hint = Where.hint(@controller, 'to see the keys you can filter on', resource: resource, with_where: trail.nil?)
          @errors << ["Unknown filter key '#{key}' for #{resource}#{under}.", hint].compact.join(' ')
        end

        # The resource that serves +model+, else its table.
        def resource_for(model)
          return Resources.resource_name(@controller.class) if model == @controller.class.model

          links[model] || model.table_name
        end

        # { model => resource name }, to name the resource behind an association.
        # A registry that can't be built (duplicate names, which Tools.for
        # reports) leaves the tables to name them.
        def links
          @links ||= Resources.links(Resources.entries(Registry.allowed(@controller.request)))
        rescue StandardMCP::Error
          @links = {}
        end

        def check_attribute(model, definitions, key, permitted, value, path)
          name = key.split('.').first
          definition = definitions&.find(name) || { 'name' => name }
          operators = Input.definition_operators(model, definition)
          allowed = Query.allowed_operators(@controller, operators.keys, permitted)

          unless value.is_a?(Hash) && value.any?
            @errors << "#{path} takes an operator object such as {\"eq\": ...}, got #{show(value)}; " \
              "operators: #{allowed.join(', ')}"
            return
          end

          value.each do |operator, argument|
            operator = operator.to_s
            schema = operators[operator]

            if schema.nil?
              @errors << "Unsupported operator '#{operator}' for #{path} (#{label(model, definition)}); use #{allowed.join(', ')}"
            elsif allowed.exclude?(operator)
              @errors << "Operator '#{operator}' isn't allowed on #{resource_for(model)}.#{key} (allowed: #{allowed.join(', ')})."
            elsif !JSONSchemer.schema(schema).valid?(argument)
              @errors << "Invalid value for #{path}: #{show(argument)} (#{operator} expects #{expects(schema)})"
            end
          end
        end

        # "string", "string[]", or "office|retail" for an enum.
        def label(model, definition)
          values = Input.definition_enum(model, definition)
          values ? values.join('|') : Definitions.type_label(definition) || 'value'
        end

        def show(value)
          Where.show(value)
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
