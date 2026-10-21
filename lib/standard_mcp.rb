require 'rails'
require 'standard_api'
require 'mcp'

require 'standard_mcp/version'
require 'standard_mcp/configuration'
require 'standard_mcp/errors'
require 'standard_mcp/railtie'

module StandardMCP
  # Rack env key the Dispatcher sets on every in-process request it runs, after
  # `config.dispatch_env`, so a request MCP dispatched can't be mistaken for one
  # that wasn't (see Controller#mcp_request?).
  DISPATCHED_ENV = 'standardmcp.dispatched'.freeze

  # Autoloaded so nothing references them at gem load time.
  autoload :Controller, 'standard_mcp/controller'
  autoload :Registry, 'standard_mcp/registry'
  autoload :Dispatcher, 'standard_mcp/dispatcher'
  autoload :Response, 'standard_mcp/response'
  autoload :Description, 'standard_mcp/description'
  autoload :IgnoredAttributes, 'standard_mcp/ignored_attributes'
  autoload :Instructions, 'standard_mcp/instructions'
  autoload :Lint, 'standard_mcp/lint'
  autoload :Preview, 'standard_mcp/preview'
  autoload :Resources, 'standard_mcp/resources'
  autoload :Tools, 'standard_mcp/tools'
  autoload :Endpoint, 'standard_mcp/endpoint'
  autoload :RouteHelpers, 'standard_mcp/route_helpers'

  module Schema
    autoload :Attributes, 'standard_mcp/schema/attributes'
    autoload :Definitions, 'standard_mcp/schema/definitions'
    autoload :Document, 'standard_mcp/schema/document'
    autoload :Input, 'standard_mcp/schema/input'
    autoload :Output, 'standard_mcp/schema/output'
    autoload :Where, 'standard_mcp/schema/where'
  end

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
      config
    end

    def reset_config!
      @config = nil
    end

    # (Re)defines StandardMCP::ServerController, the default endpoint, as a
    # subclass of `config.parent_controller`. The parent is an app class that
    # can't be loaded when this gem is, and in development a reload discards it,
    # so the Railtie calls this from `to_prepare` (once at boot, again after
    # every reload) rather than defining the constant at require time.
    def define_server_controller!
      parent = config.parent_controller.to_s.safe_constantize
      remove_const(:ServerController) if const_defined?(:ServerController, false)

      unless parent
        Rails.logger&.warn "StandardMCP: parent_controller #{config.parent_controller.inspect} " \
          'is not defined, so StandardMCP::ServerController is not available'
        return
      end

      const_set(:ServerController, Class.new(parent) { include StandardMCP::Endpoint })
    end
  end
end

# Routes resolve 'standard_mcp/server' with `camelize`, which spells the module
# "StandardMcp" (the app's inflections know no MCP acronym, and adding one would
# turn an app's own McpController into MCPController).
StandardMcp = StandardMCP
