module StandardMCP
  # Builds the MCP tools for one request: one MCP::Tool per allowed
  # (controller, action), named from the controller path (index
  # `list_accounts`, show `get_account`, create `create_account`, update
  # `update_account`, destroy `delete_account`, calculate `calculate_accounts`).
  #
  # Tools are built per request because the ACL-derived schemas and `if:`
  # conditions depend on the caller. Each tool closes over that request and
  # runs through Dispatcher with it, so the request that decided what to
  # advertise is the one the call is authorized and executed against. The
  # `server_context` the mcp server passes is accepted and ignored; transport
  # code only has to build a server from `Tools.for(request)` per request.
  #
  # Arguments are validated against the tool's input schema by the mcp server
  # (`validate_tool_call_arguments`, on by default) before the tool runs: a
  # failure comes back as an `isError` result. That is what keeps a calculate
  # with two aggregates under group_by from reaching StandardAPI, which would
  # 500, so a server built from these tools must not switch it off.
  #
  # The shallow `where` schema (the default) is a loose object, so a call's
  # filter is checked against the model before it is dispatched
  # (Schema::Where.errors) and a problem comes back as an `isError` result.
  # With `input_schema_depth = 'deep'` the schema rejects bad filters itself.
  module Tools
    ACTIONS = %i[index show create update destroy calculate].freeze

    VERBS = {
      index: 'list', show: 'get', create: 'create', update: 'update', destroy: 'delete', calculate: 'calculate'
    }.freeze

    # Actions on one record, named for its singular (`get_account`).
    SINGULAR = %i[show create update destroy].freeze

    # MCP spec: 1-64 characters. (The mcp gem allows 128.)
    MAX_NAME_LENGTH = 64

    READ_ONLY = {
      read_only_hint: true,
      destructive_hint: false,
      idempotent_hint: true,
      open_world_hint: false
    }.freeze

    # Update overwrites and delete removes, so both are destructive; repeating
    # either leaves the same state (a repeated delete finds nothing). A create
    # makes a new record each time.
    ANNOTATIONS = {
      index: READ_ONLY,
      show: READ_ONLY,
      calculate: READ_ONLY,
      create: { read_only_hint: false, destructive_hint: false, idempotent_hint: false, open_world_hint: false },
      update: { read_only_hint: false, destructive_hint: true, idempotent_hint: true, open_world_hint: false },
      destroy: { read_only_hint: false, destructive_hint: true, idempotent_hint: true, open_world_hint: false }
    }.freeze

    class << self
      # Array of MCP::Tool subclasses for +request+ (an ActionDispatch::Request).
      #
      # +only+ is a tool name: just that tool is built (none when it doesn't
      # exist). Building is what costs (schemas, descriptions), so a tools/call
      # needn't pay for every tool. The per-request `allow_mcp` conditions
      # still decide first, so a tool hidden from this caller is never built.
      def for(request, only: nil)
        tools = Registry.allowed(request).flat_map do |klass, actions|
          # StandardAPI infers the model from the controller's name.
          raise Error, "#{klass.name} allows MCP actions but has no model" unless klass.model

          controller = Registry.controller_for(klass, request)
          # Total needs calculate, which may be hidden from this caller.
          countable = actions.include?(:calculate)
          wanted = (actions & ACTIONS)
          wanted = wanted.select { |action| tool_name(klass, action) == only } if only
          wanted.map { |action| build(request, klass, controller, action, countable) }
        end

        duplicates = tools.group_by(&:name_value).select { |_, group| group.size > 1 }.keys
        raise Error, "Duplicate MCP tool names: #{duplicates.join(', ')}" if duplicates.any?

        tools
      end

      def tool_name(klass, action)
        segments = klass.controller_path.split('/')
        segments[-1] = segments[-1].singularize if SINGULAR.include?(action)
        name = "#{VERBS.fetch(action)}_#{segments.join('_')}"
        return name if name.length <= MAX_NAME_LENGTH

        raise Error, "MCP tool name #{name.inspect} for #{klass.name} exceeds #{MAX_NAME_LENGTH} characters"
      end

      # Runs one tool call. Public because the tool body is a block evaluated
      # on the tool class, so it can't reach private methods here.
      def run(request, klass, action, args, limit: nil, countable: false)
        args = (args || {}).to_h.deep_stringify_keys
        errors = filter_errors(request, klass, args['where'])
        return Response.error(errors.join('; '), errors: errors) if errors.any?

        dispatcher = Dispatcher.new(request)

        if action == :index
          args = { 'limit' => limit, 'offset' => 0 }.compact.merge(args)
          result = dispatcher.call(klass, :index, args)
          Response.from(result, action: :index, extra: pagination(dispatcher, klass, args, result, countable))
        elsif action == :create || action == :update
          # Worked out before the write, while an update's record is as it was.
          ignored = ignored_attributes(request, dispatcher, klass, action, args)
          result = dispatcher.call(klass, action, args)
          Response.from(result, action: action, extra: ({ ignored_attributes: ignored } if ignored.any?))
        else
          Response.from(dispatcher.call(klass, action, args), action: action)
        end
      rescue ActionNotAllowed
        Response.not_allowed(action)
      end

      private

      def build(request, klass, controller, action, countable)
        input = Schema::Input.for(controller, action)
        limit = input.dig('properties', 'limit', 'default')
        words = klass.controller_path.tr('/', ' ').humanize
        words = words.singularize if SINGULAR.include?(action)

        MCP::Tool.define(
          name: tool_name(klass, action),
          title: "#{VERBS.fetch(action).capitalize} #{words.downcase}",
          description: Description.for(controller, action),
          input_schema: input,
          output_schema: (Schema::Output.for(controller, action) if StandardMCP.config.output_schema),
          annotations: ANNOTATIONS.fetch(action)
        ) do |server_context: nil, **args|
          Tools.run(request, klass, action, args, limit: limit, countable: countable)
        end
      end

      # The submitted attributes StandardAPI will drop (IgnoredAttributes). An
      # update asks the ACL about the record as StandardAPI will find it, with
      # the controller's own `resources`, so `mask_for` applies and a record
      # the caller can't see is no different from a missing one (nothing is
      # reported; the update answers not found). If the lookup fails otherwise
      # the nil-record list stands in. Only once the action is allowed.
      def ignored_attributes(request, dispatcher, klass, action, args)
        return [] unless dispatcher.allowed?(klass, action)

        model = klass.model
        submitted = args[model.model_name.singular]
        return [] unless submitted.is_a?(Hash) && submitted.any?

        controller = Registry.controller_for(klass, request)
        record = begin
          action == :create ? model.new : controller.send(:resources).find(args['id'])
        rescue ActiveRecord::RecordNotFound
          return []
        rescue StandardError
          nil
        end

        IgnoredAttributes.for(controller, model, record, submitted)
      end

      # Problems with the call's `where` that the input schema didn't catch.
      # A shallow schema leaves the filter loose, so it is checked against the
      # model here; a deep one has already been validated by the server.
      def filter_errors(request, klass, where)
        return [] if where.nil? || StandardMCP.config.deep_input_schema?

        Schema::Where.errors(Registry.controller_for(klass, request), where)
      end

      # { offset:, next_offset:, total: } for a page. nil when the page didn't
      # render, so Response reports the failure on its own.
      def pagination(dispatcher, klass, args, result, countable)
        return unless (200..299).cover?(result.status)

        records = result.json
        return unless records.is_a?(Array)

        offset = args['offset']
        seen = offset + records.size
        total = count(dispatcher, klass, args) if countable
        more = total ? seen < total : records.size == args['limit']

        # next_offset stays when nil (last page); total is omitted when unknown.
        extra = { offset: offset, next_offset: (seen if more) }
        extra[:total] = total if total
        extra
      end

      # Matching rows for the same filter, or nil when it can't be counted.
      def count(dispatcher, klass, args)
        key = klass.model.primary_key
        key = 'id' unless key.is_a?(String)
        counted = args['distinct'] ? { 'distinct' => key } : '*'
        params = { 'select' => [{ 'count' => counted }], 'where' => args['where'] }.compact

        result = dispatcher.call(klass, :calculate, params)
        total = result.json&.first if result.status == 200 && result.json.is_a?(Array)
        total if total.is_a?(Integer)
      rescue ActionNotAllowed
        nil
      end
    end
  end
end
