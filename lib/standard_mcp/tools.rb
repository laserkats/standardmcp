module StandardMCP
  # Builds the MCP tools for one request: one MCP::Tool per allowed
  # (controller, action), named from the controller path (index
  # `list_accounts`, show `get_account`, create `create_account`, update
  # `update_account`, destroy `delete_account`, calculate `calculate_accounts`),
  # and the `describe_query` and `describe_attributes` tools when the caller has
  # any resource (see Resources).
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
  # The shallow schemas (the default) are loose objects, so a call's `where`,
  # `order` and `include` are checked against the model before it is
  # dispatched (Schema::Where) and a problem comes back as an `isError` result
  # that names the describe call to make. With `input_schema_depth = 'deep'` the
  # schema rejects most of them itself, and the checks still run.
  module Tools
    ACTIONS = %i[index show create update destroy calculate].freeze

    VERBS = {
      index: 'list', show: 'get', create: 'create', update: 'update', destroy: 'delete', calculate: 'calculate'
    }.freeze

    # Actions on one record, named for its singular (`get_account`).
    SINGULAR = %i[show create update destroy].freeze

    # The tools that return Resources' documents, for clients that can't read
    # resources (and for a where the resource template can't take). Listed when
    # the caller has any resource.
    DESCRIBE_QUERY = 'describe_query'.freeze
    DESCRIBE_ATTRIBUTES = 'describe_attributes'.freeze
    DESCRIBES = [DESCRIBE_QUERY, DESCRIBE_ATTRIBUTES].freeze

    DESCRIBE_TEXT = {
      DESCRIBE_QUERY => {
        title: 'Describe what a resource can be queried by',
        description: 'Describe how to query a resource: the keys of where and order with their types and operators, ' \
          'and the associations to include. Pass the same where you will list with.'
      },
      DESCRIBE_ATTRIBUTES => {
        title: 'Describe what a resource contains',
        description: "Describe a resource's records as JSON Schemas: \"read\" is a record as the list and get tools " \
          'return it and, for callers who may write, "write" is what create and update accept (types, enums, defaults, ' \
          'readOnly, required and validation constraints). Pass the where you will use so attributes that depend ' \
          'on it are included.'
      }
    }.freeze

    WHERE_PARAMETER = {
      type: %w[object array],
      description: 'Optional. The where you will use to list records, because some attributes and keys depend ' \
        'on it. describe_query marks a key only_in the groups that have it, or with its types per group, ' \
        'when the app says so.'
    }.freeze

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
        allowed = Registry.allowed(request)
        tools = allowed.flat_map do |klass, actions|
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

        if StandardMCP.config.describe_tools
          DESCRIBES.each { |name| tools << describe_tool(request, allowed, name) if only.nil? || only == name }
        end
        tools.compact
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
        errors = filter_errors(request, klass, action, args)
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

      # Runs one describe call: the +tool+ ('describe_query' or
      # 'describe_attributes') document of resource +name+ for +where+: the keys
      # of the query, or the read and write JSON Schemas StandardAPI renders. A
      # where that couldn't be used to list or calculate is an error, as it would
      # be there.
      def describe(request, entries, tool, name, where = nil)
        where = JSON.parse(JSON.generate(where)) unless where.nil?

        if tool == DESCRIBE_ATTRIBUTES
          response = Resources.attributes(request, entries, name.to_s, where)
          return response || Response.error("Unknown resource #{name.to_s.inspect}")
        end

        document = Resources.document(request, entries, name.to_s, where: where)
        return Response.error("Unknown resource #{name.to_s.inspect}") unless document

        MCP::Tool::Response.new([{ type: 'text', text: JSON.generate(document) }], structured_content: document)
      rescue Schema::Where::Invalid => e
        Response.error(e.message, errors: e.errors)
      end

      private

      # nil when the caller has no resource.
      def describe_tool(request, allowed, name)
        entries = Resources.entries(allowed)
        return if entries.empty?

        MCP::Tool.define(
          name: name,
          title: DESCRIBE_TEXT.fetch(name).fetch(:title),
          description: DESCRIBE_TEXT.fetch(name).fetch(:description),
          input_schema: {
            type: 'object',
            properties: { resource: { type: 'string', enum: entries.map(&:name) }, where: WHERE_PARAMETER },
            required: ['resource'],
            additionalProperties: false
          },
          annotations: READ_ONLY
        ) do |server_context: nil, **args|
          Tools.describe(request, entries, name, args[:resource], args[:where])
        end
      end

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

      # Problems with the call's `where`, `order`, `include` and, for a
      # calculate, `select` and `group_by` that the input schema didn't catch: a
      # shallow schema leaves them loose, and neither depth knows the ACL's
      # operator lists or the definitions for the where.
      def filter_errors(request, klass, action, args)
        controller = Registry.controller_for(klass, request)
        errors = Schema::Where.errors(controller, args['where']) +
          Schema::Where.order_errors(controller, args['order']) +
          Schema::Where.include_errors(controller, args['include']) +
          Schema::Where.calculate_errors(controller, args['select'], args['group_by'])

        # The record of a write: a shallow schema leaves it loose.
        if %i[create update].include?(action) && !StandardMCP.config.deep_input_schema?
          errors += Schema::Attributes.errors(controller, action, args[klass.model.model_name.singular])
        end
        errors
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
