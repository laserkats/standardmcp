require 'stringio'
require 'active_support/concern'

module StandardMCP
  # The MCP transport as a controller action: `handle` answers the JSON-RPC
  # messages POSTed to it (the MCP "Streamable HTTP" transport) with the tools
  # from `StandardMCP::Tools.for(request)` and the resource templates from
  # `StandardMCP::Resources.for(request)`. Include it in a controller and route
  # to `handle` (`standard_mcp '/mcp', to: 'mcp#handle'`), or use the default
  # `StandardMCP::ServerController`, which does exactly that.
  #
  # The gem does no authentication. The including controller's own callbacks
  # (its parent's `before_action`s) run first like on any other action, and
  # whatever they render (a 401) is what the client sees.
  #
  # Stateless and JSON-only: a server is built for every request, which is what
  # lets the tools depend on the caller, and a response is one JSON object (no
  # SSE stream, so no sessions, GET stream or server-initiated messages).
  #
  # What the mcp transport enforces and what is added here:
  #
  # - Content-Type must be application/json (415 otherwise), Accept must allow
  #   it (406), the body is capped (413) and parsed (400), and the
  #   MCP-Protocol-Version header is checked. In stateless mode GET is a 405 and
  #   DELETE a no-op 200. All the transport's.
  # - CSRF protection is skipped for `handle`. That is safe because a cross-site
  #   page can't send application/json without a CORS preflight, which the
  #   endpoint doesn't grant, and the transport refuses every other content type
  #   (what a plain <form> or `text/plain` fetch can send). Don't loosen that.
  # - The transport's Origin/Host check (DNS rebinding) is turned off, because
  #   its Host rule only knows loopback names, which would refuse every real
  #   deployment. Origin is checked here instead (`config.allowed_origins`);
  #   Host is Rails' job (`config.hosts`, ActionDispatch::HostAuthorization).
  module Endpoint
    extend ActiveSupport::Concern

    # Methods that answer with the server's instructions.
    INSTRUCTION_METHODS = ['initialize', 'server/discover'].freeze

    included do
      # An API-only parent has no forgery protection to skip.
      skip_forgery_protection if respond_to?(:skip_forgery_protection)

      # Before the parent's callbacks too: a refused origin shouldn't get as far
      # as authenticating.
      prepend_before_action :verify_mcp_origin
      rescue_from ActionDispatch::Http::Parameters::ParseError, with: :render_mcp_parse_error
    end

    def handle
      transport = MCP::Server::Transports::StreamableHTTPTransport.new(
        mcp_server,
        stateless: true,
        enable_json_response: true,
        dns_rebinding_protection: false,
        # A buffered response can't hold an open stream; answer 404 instead.
        serve_subscriptions_listen: false
      )

      # Rails has consumed the body to parse params; hand the transport the
      # cached copy on a fresh stream.
      env = request.env.merge('rack.input' => StringIO.new(request.raw_post))
      status, headers, rack_body = transport.call(env)

      body = +''
      rack_body.each { |chunk| body << chunk }
      rack_body.close if rack_body.respond_to?(:close)

      content_type = headers.find { |key, _| key.casecmp?('content-type') }&.last || 'application/json'
      headers.each { |key, value| response.headers[key] = value unless key.casecmp?('content-type') }
      render body: body, status: status, content_type: content_type
    end

    private

    def mcp_server
      MCP::Server.new(
        name: StandardMCP.config.server_name,
        version: StandardMCP.config.server_version,
        instructions: mcp_instructions,
        tools: mcp_tools,
        resource_templates: mcp_resource_templates,
        configuration: mcp_configuration
      ).tap do |server|
        # Nothing to read or list, so don't claim to serve resources.
        server.capabilities = server.capabilities.except(:resources) if StandardMCP.config.resources.empty?
      end
    end

    # `validate_tool_call_arguments` stays on: the input schemas are what keep
    # invalid calls (and bad `where` filters in deep mode) away from StandardAPI.
    def mcp_configuration
      config = StandardMCP.config
      MCP::Configuration.new(
        validate_tool_call_arguments: true,
        validate_tool_call_results: !!(config.output_schema && config.validate_results),
        exception_reporter: config.exception_reporter
      )
    end

    # Nothing to advertise for GET/DELETE or a body that isn't JSON (the
    # transport refuses or ignores them), and a tools/call only needs its own
    # tool, since building tools is what costs. Anything else (a batch, which
    # the transport rejects anyway) gets them all.
    def mcp_tools
      return [] unless request.post? && request.media_type == 'application/json'

      StandardMCP::Tools.for(request, only: mcp_called_tool_name)
    end

    # Only the methods that use the templates build them: a read needs the one
    # its URI matches (and answers "Resource not found" for any other), the
    # listing needs them all (cheaply, nothing is rendered until a read), and
    # everything else, tools/list and initialize included, none.
    def mcp_resource_templates
      return [] unless request.post? && request.media_type == 'application/json'

      case mcp_method_name
      when MCP::Methods::RESOURCES_READ
        # A request without a usable URI finds nothing, like any unknown one.
        StandardMCP::Resources.for(request, only_uri: mcp_params['uri'].to_s)
      when MCP::Methods::RESOURCES_TEMPLATES_LIST
        StandardMCP::Resources.for(request)
      else
        []
      end
    end

    def mcp_called_tool_name
      message = mcp_message
      return unless message.is_a?(Hash) && message['method'] == 'tools/call'

      params = message['params']
      name = params['name'] if params.is_a?(Hash)
      name if name.is_a?(String)
    end

    def mcp_method_name
      message = mcp_message
      message['method'] if message.is_a?(Hash)
    end

    def mcp_params
      message = mcp_message
      params = message['params'] if message.is_a?(Hash)
      params.is_a?(Hash) ? params : {}
    end

    # The JSON-RPC message, or nil when the body isn't JSON (the transport
    # answers that with a parse error).
    def mcp_message
      return @mcp_message if defined?(@mcp_message)

      @mcp_message = begin
        JSON.parse(request.raw_post.to_s)
      rescue JSON::ParserError
        nil
      end
    end

    # Seam for the instructions: override this, or set `config.instructions`
    # (StandardMCP::Instructions). Only worked out for the methods that send
    # them, so the generated text's queries aren't paid on every call.
    def mcp_instructions
      return unless INSTRUCTION_METHODS.include?(mcp_method_name)

      StandardMCP::Instructions.for(request)
    end

    def verify_mcp_origin
      origin = request.headers['Origin']
      return if origin.nil? || mcp_origin_allowed?(origin)

      render_mcp_error(403, -32600, 'Forbidden: Invalid Origin header')
    end

    def mcp_origin_allowed?(origin)
      return true if origin.casecmp?(request.base_url)

      Array(StandardMCP.config.allowed_origins).any? do |allowed|
        allowed.is_a?(Regexp) ? mcp_anchored(allowed).match?(origin) : allowed.to_s.casecmp?(origin)
      end
    end

    # A pattern must match the whole origin: unanchored, /jll\.com/ would also
    # accept https://jll.com.evil.example.
    def mcp_anchored(pattern)
      Regexp.new("\\A(?:#{pattern.source})\\z", pattern.options)
    end

    def render_mcp_parse_error
      render_mcp_error(400, -32700, 'Parse error: Invalid JSON')
    end

    def render_mcp_error(status, code, message)
      render json: { jsonrpc: '2.0', id: nil, error: { code: code, message: message } }, status: status
    end
  end
end
