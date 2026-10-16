require 'json'

module StandardMCP
  module Schema
    # JSON Schema for the `structuredContent` a tool returns, matching the
    # wrapping StandardMCP::Response applies.
    #
    # The record schema is StandardAPI's own `json_schema` view, rendered for
    # the caller's controller so the table/column comments, ACL readOnly marks
    # and every permitted include come from the one builder StandardAPI already
    # has. It is then adapted for output: StandardAPI's schema describes what
    # a valid *input* looks like, so constraints that only make sense for input
    # are removed rather than risk rejecting a real response.
    module Output
      # Keywords StandardAPI derives from validators and column defaults. They
      # describe valid input, and legacy rows need not satisfy them.
      INPUT_ONLY_KEYWORDS = %w[
        default const pattern minLength maxLength
        minimum maximum exclusiveMinimum exclusiveMaximum enum
      ].freeze

      module_function

      # +controller+ is an instance from Registry.controller_for, so ACL
      # methods resolve for the caller. Not cached: each call renders the
      # view, so build once per request and reuse.
      def for(controller, action)
        action = action.to_sym
        case action
        when :index then index(record(controller))
        when :show then show(record(controller))
        when :calculate then calculate
        when :create, :update, :destroy
          raise NotImplementedError, "Output schema for #{action} is not implemented"
        else
          raise ArgumentError, "Unknown action #{action.inspect}. Valid actions: #{Controller::ACTIONS.map(&:inspect).join(', ')}"
        end
      end

      # One record, with every association the caller may include.
      def record(controller)
        model = controller.class.model
        raise ArgumentError, "#{controller.class} has no model" unless model

        includes = StandardAPI::Includes.normalize(controller.send(:model_includes))
        adapt(render(controller, includes), model, controller, nil)
      end

      def index(record)
        {
          'type' => 'object',
          'properties' => {
            'records' => { 'type' => 'array', 'items' => record, 'description' => 'The matching records.' },
            'offset' => { 'type' => 'integer', 'description' => 'Number of records skipped.' },
            'next_offset' => { 'type' => %w[integer null], 'description' => 'Offset of the next page, or null on the last page.' },
            'total' => { 'type' => 'integer', 'description' => 'Total number of matching records.' }
          },
          'required' => %w[records]
        }
      end

      def show(record)
        {
          'type' => 'object',
          'properties' => { 'record' => record },
          'required' => %w[record]
        }
      end

      # An array of values, or an object when grouped, so `result` is untyped.
      def calculate
        {
          'type' => 'object',
          'properties' => {
            'result' => { 'description' => 'Aggregate values: an array, or an object keyed by group.' }
          },
          'required' => %w[result]
        }
      end

      # Renders StandardAPI's json_schema template in +controller+ itself, so
      # the view sees the caller's ACL (`controller.model_attributes`) and
      # whichever handler (jbuilder or turbostreamer) the app has. Dispatching
      # the `json_schema` action instead would have to bypass Dispatcher's
      # allow_mcp check, and `ApplicationController.renderer` has no caller.
      def render(controller, includes)
        had_includes = controller.instance_variable_defined?(:@includes)
        previous = controller.instance_variable_get(:@includes)
        controller.instance_variable_set(:@includes, includes)

        JSON.parse(controller.render_to_string(template: 'application/json_schema', formats: [:json], layout: false))
      ensure
        if had_includes
          controller.instance_variable_set(:@includes, previous)
        else
          controller.remove_instance_variable(:@includes) if controller.instance_variable_defined?(:@includes)
        end
      end

      # Turns an input schema into an output one, in place, walking the model
      # alongside it to find each property's column or association.
      def adapt(schema, model, controller, inherited)
        excluded = StandardAPI::Excludes.deep_merge(probe_excludes(controller, model), inherited)
        properties = schema['properties']

        # Only `id` is guaranteed; StandardAPI's `required` is for input.
        schema.delete('required')
        schema['required'] = %w[id] if properties.key?('id')
        # Serializers and custom partials may add keys.
        schema['additionalProperties'] = true

        properties.keys.each do |name|
          if excluded[name] == true
            properties.delete(name)
          elsif (column = model.columns_hash[name])
            adapt_column(properties[name], model, column)
          elsif (association = model.reflect_on_association(name))
            sub = excluded[name] if excluded[name].is_a?(Hash)
            if association.collection?
              adapt(properties[name]['items'], association.klass, controller, sub)
            else
              adapt(properties[name], association.klass, controller, sub)
              nullable!(properties[name])
            end
          end
        end

        schema
      end

      def adapt_column(property, model, column)
        target = column.array && property['items'] ? property['items'] : property
        [property, target].uniq.each { |s| s.except!(*INPUT_ONLY_KEYWORDS) }
        # The view nests an array column's whole schema, comment included,
        # under items; the comment describes the column.
        if !target.equal?(property) && target.key?('description')
          property['description'] ||= target.delete('description')
        end

        # BigDecimal serializes as a string; accept either form.
        target['type'] = %w[number string] if column.type == :decimal
        # json columns hold any JSON value, not only objects.
        target.delete('type') if %i[json jsonb].include?(column.type)

        if (labels = model.defined_enums[column.name]&.keys)
          target['enum'] = column.null ? labels + [nil] : labels
        end

        nullable!(property) if column.null
      end

      def nullable!(schema)
        return unless schema['type']

        schema['type'] = (Array(schema['type']) | %w[null])
      end

      # Excludes are resolved per record, so the view can't apply them and a
      # blank record stands in. The result is only a hint: it can miss a
      # record-dependent exclude, which is why records allow additional
      # properties and nothing here is `required`. An ACL that can't answer
      # for a blank record gets no pruning.
      def probe_excludes(controller, model)
        controller.send(:excludes, model.new)
      rescue StandardError
        nil
      end
    end
  end
end
