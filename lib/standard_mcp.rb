require 'rails'
require 'standard_api'
require 'mcp'

require 'standard_mcp/version'
require 'standard_mcp/configuration'
require 'standard_mcp/railtie'

module StandardMCP
  # Autoloaded so nothing references them at gem load time.
  autoload :Controller, 'standard_mcp/controller'
  autoload :Registry, 'standard_mcp/registry'

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
  end
end
