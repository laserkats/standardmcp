module StandardMCP
  # Finds MCP-enabled controllers. Stateless so code reloading can't leave stale
  # classes behind.
  module Registry
    module_function

    def controllers
      Rails.application.eager_load! if !Rails.application.config.eager_load

      bases = [ActionController::Base]
      bases << ActionController::API if defined?(ActionController::API)
      bases.flat_map(&:descendants)
        .select { |c| c.name && !c.abstract? && c.respond_to?(:mcp_enabled?) && c.mcp_enabled? }
        .uniq
        .sort_by(&:name)
    end

    # A controller instance bound to +request+ so conditions can read
    # `request`, `params`, `headers`. No action is dispatched. It answers true to
    # `mcp_request?`, as the controllers of dispatched requests do. +params+
    # replaces the request's parameters (String-keyed, e.g. `{ 'where' => ... }`),
    # for code that reads `params[:where]` the way a dispatched call would see it.
    def controller_for(klass, request, params: nil)
      klass.new.tap do |controller|
        controller.instance_variable_set(:@standard_mcp_request, true)
        previous = request.controller_instance
        controller.set_request!(request)
        # set_request! points the request at this throwaway instance.
        request.controller_instance = previous
        controller.set_response!(klass.make_response!(request))
        controller.params = ActionController::Parameters.new(params) if params
      end
    end

    # { ControllerClass => [actions] } for +request+, omitting controllers with
    # nothing allowed.
    def allowed(request)
      controllers.each_with_object({}) do |klass, result|
        actions = controller_for(klass, request).mcp_actions_allowed
        result[klass] = actions if actions.any?
      end
    end
  end
end
