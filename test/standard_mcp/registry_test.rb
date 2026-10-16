require 'standard_mcp/test_helper'

class RegistryHiddenAccountsController < ApplicationController
  allow_mcp if: -> { false }
end

class RegistryTest< ActiveSupport::TestCase

  def request_for(headers = {})
    env = Rack::MockRequest.env_for('/mcp', headers.transform_keys { |k| "HTTP_#{k.upcase.tr('-', '_')}" })
    ActionDispatch::Request.new(env)
  end

  test "controllers includes opted-in controllers" do
    controllers = StandardMCP::Registry.controllers
    assert_includes controllers, AccountsController
    assert_includes controllers, PropertiesController
  end

  test "controllers excludes the MCP endpoint controllers" do
    controllers = StandardMCP::Registry.controllers
    refute_includes controllers, McpController
    refute_includes controllers, StandardMCP::ServerController
  end

  test "controllers excludes controllers that did not opt in" do
    controllers = StandardMCP::Registry.controllers
    refute_includes controllers, PhotosController
    refute_includes controllers, ApplicationController
  end

  test "controllers are sorted by name" do
    names = StandardMCP::Registry.controllers.map(&:name)
    assert_equal names.sort, names
  end

  test "allowed hides conditional actions without the header" do
    allowed = StandardMCP::Registry.allowed(request_for)
    assert_equal [:index, :show, :calculate], allowed[AccountsController]
    assert_equal [:index, :show], allowed[PropertiesController]
    refute allowed.key?(PhotosController)
  end

  test "allowed exposes conditional actions when the condition passes" do
    allowed = StandardMCP::Registry.allowed(request_for('X-MCP-Writes' => 'true'))
    assert_equal [:index, :show, :create, :update, :calculate], allowed[PropertiesController]
    assert_equal [:index, :show, :calculate], allowed[AccountsController]
  end

  test "allowed omits controllers with nothing allowed" do
    StandardMCP::Registry.stubs(:controllers).returns([AccountsController, RegistryHiddenAccountsController])
    assert_equal [AccountsController], StandardMCP::Registry.allowed(request_for).keys
  end

  test "controller_for binds request, params and headers" do
    request = request_for('X-MCP-Writes' => 'true')
    controller = StandardMCP::Registry.controller_for(AccountsController, request)

    assert_same request, controller.request
    assert_equal 'true', controller.request.headers['X-MCP-Writes']
    assert_kind_of ActionController::Parameters, controller.params
    assert_kind_of ActionDispatch::Response, controller.response
    assert_kind_of Hash, controller.headers.to_h
  end

  test "controller_for leaves the request's controller_instance alone" do
    request = request_for
    request.controller_instance = :original
    StandardMCP::Registry.controller_for(AccountsController, request)
    assert_equal :original, request.controller_instance
  end

end
