require 'json'

module StandardMCP
  module Schema
    # JSON Schema for the `structuredContent` a tool returns, matching the
    # wrapping StandardMCP::Response applies.
    #
    # The record schema is StandardAPI's `read_schema_for`, built on the
    # caller's controller, so the comments, nullability and every permitted
    # include come from the one builder StandardAPI already has. It describes
    # a record as `show` and `index` render it, so it is used as it is, apart
    # from the includes no longer being required (see optional_includes).
    module Output
      module_function

      # +controller+ is an instance from Registry.controller_for, so ACL
      # methods resolve for the caller. Not cached: each call builds the
      # schema, so build once per request and reuse.
      def for(controller, action)
        action = action.to_sym
        case action
        when :index then index(record(controller))
        when :show then show(record(controller))
        when :calculate then calculate
        when :create, :update then written(record(controller))
        when :destroy then destroyed
        else
          raise ArgumentError, "Unknown action #{action.inspect}. Valid actions: #{Controller::ACTIONS.map(&:inspect).join(', ')}"
        end
      end

      # One record, with every association the caller may include.
      def record(controller)
        model = controller.class.model
        raise ArgumentError, "#{controller.class} has no model" unless model

        includes = controller.send(:normalize_includes, controller.send(:includes_for, model))
        schema = controller.send(:read_schema_for, model, includes)
        # Embedded in the tool's schema, which has its own.
        schema.delete('$schema')
        optional_includes(schema, includes)
      end

      # read_schema describes a record rendered with exactly these includes, so
      # it requires them. A call picks its own, so none is required (the
      # associations stay described for when it asks for them).
      def optional_includes(schema, includes)
        includes.each do |name, nested|
          property = schema.dig('properties', name.to_s) or next

          schema['required'] = schema['required'] - [name.to_s] if schema['required']
          optional_includes(property['items'] || property, nested) if nested.is_a?(Hash)
        end
        schema
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

      # The saved record, plus the keys of the submitted attributes the ACL
      # dropped (only present when there were some).
      def written(record)
        schema = show(record)
        schema['properties']['ignored_attributes'] = {
          'type' => 'array',
          'items' => { 'type' => 'string' },
          'description' => 'Submitted attributes that were not saved because the caller may not set them.'
        }
        schema
      end

      # `affected_rows` is left out when StandardAPI sends no Affected-Rows header.
      def destroyed
        {
          'type' => 'object',
          'properties' => {
            'success' => { 'type' => 'boolean' },
            'affected_rows' => { 'type' => 'integer', 'description' => 'Number of records deleted.' }
          },
          'required' => %w[success]
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
    end
  end
end
