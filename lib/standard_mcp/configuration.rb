module StandardMCP
  class Configuration
    # Name reported to MCP clients in the initialize handshake.
    attr_writer :server_name

    # Version reported to MCP clients.
    attr_writer :server_version

    # Controller class (name) the generated MCP endpoint inherits from.
    attr_accessor :parent_controller

    # nil, a String, or a callable (`->(request) { "..." }`) producing the
    # server instructions sent to clients.
    attr_accessor :instructions

    # Callable `->(request) { {} }` returning extra Rack env entries merged into
    # the in-process request dispatched to a StandardAPI controller action.
    attr_accessor :dispatch_env

    # Page size for `index` when the controller defines no `default_limit` and
    # the caller sends no `limit`. StandardAPI rejects an index without a limit
    # in that case, so a tool must always send one.
    attr_accessor :default_limit

    # How many association levels the `where` schema nests: 0 offers only the
    # model's own columns, 1 (the default) adds the columns of its permitted
    # includes, 2 theirs in turn, and so on. Always bounded by what the
    # controller's `model_includes` permits; `include` itself is not limited.
    # Only used when `input_schema_depth` is 'deep'; the shallow `where` lists
    # every permitted association and checks calls against the model instead.
    attr_accessor :where_depth

    # How much of the `where` filter the input schemas spell out.
    #
    # 'shallow' (the default): `where` is a bare object and the tool
    # description lists the filterable columns, operators and associations in
    # prose. That is a fraction of the tokens, and calls are checked against
    # the model before they run (StandardMCP::Schema::Where), answering with
    # a readable tool error.
    #
    # 'deep': `where` is fully typed (a filter definition per column type,
    # inline enums, nested association columns bounded by `where_depth`) and the
    # MCP server rejects a bad filter by schema validation.
    #
    # Accepts a String or Symbol.
    attr_reader :input_schema_depth

    INPUT_SCHEMA_DEPTHS = %w[shallow deep].freeze

    # Whether tools declare an `outputSchema` (and a server can validate
    # results against it). Off by default: it is about a quarter of the
    # tools/list payload. `structuredContent` and the text content are
    # returned either way.
    attr_accessor :output_schema

    # Whether the endpoint validates tool results against their output schema
    # (only meaningful with `output_schema`). Defaults to on outside production:
    # it catches schema drift in development and tests, and costs time per call
    # that production doesn't need. nil (the default) means that rule.
    attr_writer :validate_results

    # Callable `->(exception, server_context) { ... }` the endpoint's MCP server
    # reports unexpected errors to (an error tracker, say). nil keeps the mcp
    # gem's default (its own, global, reporter).
    attr_accessor :exception_reporter

    # Origins (the `Origin` request header) the endpoint accepts besides its
    # own. nil or empty accepts requests without an `Origin` (non-browser
    # clients) and same-origin ones, which refuses a cross-site page driving the
    # endpoint with the caller's cookies. An Array of Strings (exact,
    # case-insensitive, e.g. 'https://claude.ai') and/or Regexps widens that.
    # Regexps must match the whole origin; they are anchored for you.
    # Anything else is answered with 403.
    attr_accessor :allowed_origins

    def initialize
      @server_name = nil
      @server_version = nil
      @parent_controller = "ApplicationController"
      @instructions = nil
      @dispatch_env = ->(request) { {} }
      @default_limit = 25
      @where_depth = 1
      @input_schema_depth = 'shallow'
      @output_schema = false
      @validate_results = nil
      @exception_reporter = nil
      @allowed_origins = nil
    end

    def validate_results
      @validate_results.nil? ? !Rails.env.production? : @validate_results
    end

    def input_schema_depth=(value)
      depth = value.to_s if value.is_a?(String) || value.is_a?(Symbol)
      unless INPUT_SCHEMA_DEPTHS.include?(depth)
        raise ArgumentError, "input_schema_depth must be one of #{INPUT_SCHEMA_DEPTHS.join(', ')}, got #{value.inspect}"
      end

      @input_schema_depth = depth
    end

    def deep_input_schema?
      input_schema_depth == 'deep'
    end

    def server_name
      @server_name || default_server_name
    end

    def server_version
      @server_version || StandardMCP::VERSION
    end

    private

    def default_server_name
      app_class = defined?(Rails) && Rails.respond_to?(:application) && Rails.application&.class
      if app_class && app_class.respond_to?(:module_parent_name) && app_class.module_parent_name
        app_class.module_parent_name.underscore
      else
        "standardmcp"
      end
    end
  end
end
