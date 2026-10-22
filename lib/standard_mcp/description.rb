module StandardMCP
  # Tool descriptions for LLMs. The table comment carries the application
  # context; the rest is short guidance that the input schema doesn't already
  # give (it lists each parameter itself). No column, key or association is
  # listed: the schemas and descriptions point to `describe_query` and
  # `describe_attributes` for those.
  #
  # Nothing is memoized: comments change with migrations and dev reloads.
  module Description
    IGNORED = "Attributes the record's rules don't allow are not saved and come back in ignored_attributes.".freeze

    class << self
      # +controller+ is an instance from Registry.controller_for.
      def for(controller, action)
        action = action.to_sym
        model = controller.class.model
        plural = model.model_name.plural.humanize.downcase
        singular = model.model_name.human.downcase

        sentence, guidance = case action
        when :index
          ["List #{plural}.", 'Filter with where; page with limit and offset, using next_offset from the result.']
        when :show
          ["Get one #{singular} by id.", nil]
        when :calculate
          ["Aggregate #{plural} (count, sum, min, max, average), optionally grouped.",
            'Filter with where; group with group_by.']
        when :create
          ["Create one #{singular}.", ignored(controller)]
        when :update
          ["Update one #{singular} by id.", "Send only the attributes to change. #{ignored(controller)}"]
        when :destroy
          ["Delete one #{singular} by id.", 'This is permanent.']
        else
          raise ArgumentError, "Unknown action #{action.inspect}. Valid actions: #{Controller::ACTIONS.map(&:inspect).join(', ')}"
        end

        [sentence, table(model), guidance].compact_blank.join(' ')
      end

      # The table's comment, or nil.
      def table(model)
        model.with_connection { |connection| connection.table_comment(model.table_name) }.presence
      end

      # The column's comment, or nil (also for names that aren't columns).
      def column(model, column_name)
        model.columns_hash[column_name.to_s]&.comment.presence
      end

      # The call that tells more about a controller's model, e.g.
      # `describe_query {"resource": "accounts"}`, once the shallow schemas stop
      # short of it. +tool+ is 'describe_query' or 'describe_attributes'. nil
      # when the describe tools are off.
      def describe_call(controller, tool)
        return unless StandardMCP.config.describe_tools

        %(#{tool} {"resource": "#{Resources.resource_name(controller.class)}"})
      end

      private

      # What a write does with attributes it may not set, and where to find the
      # ones it may.
      def ignored(controller)
        call = describe_call(controller, 'describe_attributes')
        call ? "#{IGNORED} Writable and required attributes: #{call}." : IGNORED
      end
    end
  end
end
