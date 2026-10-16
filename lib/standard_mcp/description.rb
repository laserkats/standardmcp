module StandardMCP
  # Tool descriptions for LLMs. The table comment carries the application
  # context; the rest is short guidance that the input schema doesn't already
  # give (it lists each parameter itself).
  #
  # Nothing is memoized: comments change with migrations and dev reloads.
  module Description
    class << self
      # +controller+ is an instance from Registry.controller_for.
      def for(controller, action)
        action = action.to_sym
        model = controller.class.model
        plural = model.model_name.plural.humanize.downcase
        singular = model.model_name.human.downcase

        sentence, guidance = case action
        when :index
          ["List #{plural}.", index_guidance(controller)]
        when :show
          ["Get one #{singular} by id.", names('Includes', Schema::Input.includes(controller))]
        when :calculate
          ["Aggregate #{plural} (count, sum, min, max, average), optionally grouped.",
            'Filter with where; group with group_by.']
        when :create, :update, :destroy
          raise NotImplementedError, "Description for #{action} is not implemented"
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

      private

      def index_guidance(controller)
        order = Schema::Input.orders(controller).flat_map { |o| o.is_a?(Hash) ? o.keys : [o] }
        [
          'Filter with where; page with limit and offset, using next_offset from the result.',
          names('Includes', Schema::Input.includes(controller)),
          names('Order by', order)
        ].compact.join(' ')
      end

      # "Includes: a, b, b.c." for a tree or a list; nil when empty.
      def names(label, source)
        list = source.is_a?(Hash) ? paths(source) : source
        "#{label}: #{list.join(', ')}." if list.any?
      end

      def paths(tree, prefix = nil)
        tree.flat_map do |name, subtree|
          path = [prefix, name].compact.join('.')
          [path] + paths(subtree, path)
        end
      end
    end
  end
end
