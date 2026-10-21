module StandardMCP
  class Configuration
    # Name reported to MCP clients in the initialize handshake.
    attr_writer :server_name

    # Version reported to MCP clients.
    attr_writer :server_version

    # Controller class (name) the generated MCP endpoint inherits from.
    attr_accessor :parent_controller

    # The server instructions sent to clients (see StandardMCP::Instructions).
    # nil (the default) sends the generated ones: the database comment, the
    # resources with their table comments and tools, and the shared conventions.
    #
    # - a String, or a callable taking the request (`->(request) { "..." }`),
    #   replaces them entirely;
    # - a callable taking the request and the generated text
    #   (`->(request, default) { "#{default}\n\n..." }`) adds to them;
    # - false sends none.
    #
    # A callable that returns nothing falls back to the generated ones.
    attr_accessor :instructions

    # Columns `rake standard_mcp:lint` doesn't expect a comment on.
    attr_accessor :lint_ignore_columns

    # Callable `->(request) { {} }` returning extra Rack env entries merged into
    # the in-process request dispatched to a StandardAPI controller action.
    attr_accessor :dispatch_env

    # Page size for `index` when the controller defines no `default_limit` and
    # the caller sends no `limit`. StandardAPI rejects an index without a limit
    # in that case, so a tool must always send one.
    attr_accessor :default_limit

    # The most records one `list_*` call may ask for, separate from the
    # controller's `resource_limit` (which bounds the JSON API): the `limit`
    # schema's maximum is the smaller of the two, and the default page size is
    # held to it. A bigger `limit` is rejected by schema validation. nil turns
    # this cap off, leaving the controller's alone.
    attr_reader :max_limit

    # How many association levels the `where` schema nests: 0 offers only the
    # model's own columns, 1 (the default) adds the columns of its permitted
    # includes, 2 theirs in turn, and so on. Always bounded by what the
    # model's ACL `includes` permits; `include` itself is not limited.
    # Only used when `input_schema_depth` is 'deep' (nested records of a write
    # are typed to any depth, cycles aside).
    attr_accessor :where_depth

    # How much the input schemas spell out.
    #
    # 'shallow' (the default): `where`, `order`, `include` and the written record
    # are loose objects with a sentence pointing at `describe_query` or
    # `describe_attributes` for the keys. No column, key or association list is in
    # `tools/list`, which keeps it small however wide the models are. Calls are
    # checked before they run (StandardMCP::Schema::Where), answering a mistake
    # with a readable tool error that names the describe call to make.
    #
    # 'deep' (opt-in): the typed schemas. `where` is fully typed (a filter
    # definition per column type, inline enums, nested association columns
    # bounded by `where_depth`) but only offers the keys and operators the
    # ACL's `wheres` permit, and the MCP server rejects a bad filter by schema
    # validation. The nested records of create and update are typed from their
    # own ACL too. Deep types real columns only: attributes that depend on the
    # where (`model_attribute_definitions`) are not in it, and `tools/list`
    # grows with the models.
    #
    # Accepts a String or Symbol.
    attr_reader :input_schema_depth

    INPUT_SCHEMA_DEPTHS = %w[shallow deep].freeze

    # Whether tools declare an `outputSchema` (and a server can validate
    # results against it). Off by default: it lists every column of every model
    # again, which next to the small shallow input schemas is most of the
    # tools/list payload. `structuredContent` and the text content are returned
    # either way.
    attr_accessor :output_schema

    # Whether the endpoint validates tool results against their output schema
    # (only meaningful with `output_schema`). Defaults to on outside production:
    # it catches schema drift in development and tests, and costs time per call
    # that production doesn't need. nil (the default) means that rule.
    attr_writer :validate_results

    # Which resource templates the endpoint serves (StandardMCP::Resources):
    # `schema` is `standardmcp://schema/{resource}`, what
    # `describe_query` and `describe_attributes` return for a controller (with
    # no where); `records` is
    # `standardmcp://<resource>/{id}` per controller that allows show, so a
    # client can attach a record as context. An Array of Symbols or Strings;
    # [] serves none (and the endpoint doesn't advertise `resources`).
    attr_reader :resources

    RESOURCE_KINDS = %i[schema records].freeze

    # Whether the `describe_query` and `describe_attributes` tools are listed,
    # and the tool schemas and descriptions point to them. Together they return
    # what the `schema` resource does, for clients that can't read resources
    # (and for a where the resource can't take).
    attr_accessor :describe_tools

    # URI scheme of the resource templates. RFC 3986: a letter, then letters,
    # digits, `+`, `-` or `.`.
    attr_reader :resource_scheme

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
      @lint_ignore_columns = %w[id created_at updated_at]
      @dispatch_env = ->(request) { {} }
      @default_limit = 25
      @max_limit = 100
      @where_depth = 1
      @input_schema_depth = 'shallow'
      @output_schema = false
      @validate_results = nil
      @exception_reporter = nil
      @allowed_origins = nil
      @resources = RESOURCE_KINDS
      @describe_tools = true
      @resource_scheme = 'standardmcp'
    end

    def max_limit=(value)
      unless value.nil? || (value.is_a?(Integer) && value > 0)
        raise ArgumentError, "max_limit must be a positive Integer or nil, got #{value.inspect}"
      end

      @max_limit = value
    end

    def resources=(value)
      kinds = Array(value).map { |kind| kind.respond_to?(:to_sym) ? kind.to_sym : kind }.uniq
      unknown = kinds - RESOURCE_KINDS
      if unknown.any?
        raise ArgumentError, "resources must be a list of #{RESOURCE_KINDS.join(', ')}, got #{unknown.map(&:inspect).join(', ')}"
      end

      @resources = kinds.freeze
    end

    def resource_scheme=(value)
      unless value.is_a?(String) && value.match?(/\A[A-Za-z][A-Za-z0-9+.-]*\z/)
        raise ArgumentError, "resource_scheme must be an RFC 3986 URI scheme (letters, digits, +, - and .), got #{value.inspect}"
      end

      @resource_scheme = value
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
