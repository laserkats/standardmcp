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

    def initialize
      @server_name = nil
      @server_version = nil
      @parent_controller = "ApplicationController"
      @instructions = nil
      @dispatch_env = ->(request) { {} }
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
