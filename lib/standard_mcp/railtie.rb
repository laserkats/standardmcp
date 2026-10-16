module StandardMCP
  class Railtie < ::Rails::Railtie

    # Runs for ActionController::Base and ::API; the autoload resolves lazily
    # so gem load order doesn't matter.
    initializer 'standardmcp' do
      ActiveSupport.on_load(:action_controller) { include StandardMCP::Controller }

      ::ActionDispatch::Routing::Mapper.include StandardMCP::RouteHelpers
    end

    # Runs once before eager loading in production and after each reload in
    # development, so the default controller always inherits from the current
    # parent class (and picks up `config.parent_controller` as set in an
    # initializer). A const_missing hook would need its own reload handling,
    # and an eager-loaded app would never trigger it.
    config.to_prepare { StandardMCP.define_server_controller! }

  end
end
