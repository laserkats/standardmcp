module StandardMCP
  class Railtie < ::Rails::Railtie

    # Runs for ActionController::Base and ::API; the autoload resolves lazily
    # so gem load order doesn't matter.
    initializer 'standardmcp' do
      ActiveSupport.on_load(:action_controller) { include StandardMCP::Controller }
    end

  end
end
