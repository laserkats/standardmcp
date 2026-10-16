module StandardMCP
  module RouteHelpers
    # Routes the MCP endpoint.
    #
    #   standard_mcp '/mcp'
    #
    # is equivalent to:
    #
    #   match '/mcp', to: 'standard_mcp/server#handle', via: [:post, :get, :delete], as: :standard_mcp
    #
    # GET and DELETE are routed so the transport can answer them as the protocol
    # asks (405 and a no-op 200 when stateless) instead of the app's 404.
    #
    # +to+ is an app controller that includes StandardMCP::Endpoint
    # (`to: 'mcp#handle'`). Other options go to `match`; a second endpoint needs
    # its own `as:`.
    def standard_mcp(path = '/mcp', to: nil, **options)
      options = { via: %i[post get delete], as: :standard_mcp }.merge(options)
      match path, to: to || 'standard_mcp/server#handle', **options
    end
  end
end
