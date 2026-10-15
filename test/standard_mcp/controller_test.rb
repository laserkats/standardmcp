require 'standard_mcp/test_helper'

# Named classes: StandardAPI infers the model from the controller name.
class McpReadOnlyAccountsController < ApplicationController
  undef_method :create, :update, :destroy
  allow_mcp
end

class McpConditionalAccountsController < ApplicationController
  allow_mcp only: [:index], if: :flag?
  allow_mcp only: [:show], unless: :flag?
  allow_mcp only: [:create], if: [:flag?, -> { params[:ok] == '1' }]
  allow_mcp only: [:update], if: ->(c) { c.send(:flag?) }
  allow_mcp only: [:calculate], if: :flag?, unless: :blocked?

  attr_accessor :flag, :blocked

  private

  def flag?
    !!flag
  end

  def blocked?
    !!blocked
  end
end

# Not a StandardAPI controller.
class PlainController < ActionController::Base
end

class McpParentAccountsController <ApplicationController
  allow_mcp only: [:index]
end

class McpChildAccountsController < McpParentAccountsController
  allow_mcp only: [:show]
end

class ControllerTest < ActiveSupport::TestCase

  def instance_for(klass, params: {})
    request = ActionDispatch::Request.new(Rack::MockRequest.env_for('/', params: params))
    StandardMCP::Registry.controller_for(klass, request)
  end

  test "only and except together raise" do
    error = assert_raises(ArgumentError) { McpParentAccountsController.allow_mcp only: [:index], except: [:show] }
    assert_match(/not both/, error.message)
  end

  test "unknown actions raise naming them and listing valid ones" do
    error = assert_raises(ArgumentError) { McpParentAccountsController.allow_mcp only: [:index, :nope] }
    assert_match(/:nope/, error.message)
    assert_match(/:calculate/, error.message)

    error = assert_raises(ArgumentError) { McpParentAccountsController.allow_mcp except: [:new] }
    assert_match(/:new/, error.message)
  end

  test "invalid condition types raise" do
    assert_raises(ArgumentError) { McpParentAccountsController.allow_mcp if: 'admin?' }
    assert_raises(ArgumentError) { McpParentAccountsController.allow_mcp unless: [:ok, 1] }
  end

  test "failed declarations do not add rules" do
    assert_no_difference -> { McpParentAccountsController.mcp_rules.size } do
      assert_raises(ArgumentError) { McpParentAccountsController.allow_mcp only: [:nope] }
    end
  end

  test "controllers without StandardAPI::Controller raise" do
    error = assert_raises(ArgumentError) { PlainController.allow_mcp }
    assert_match(/StandardAPI::Controller/, error.message)
  end

  test "subclass rules are added without changing the parent" do
    assert_equal [:index], McpParentAccountsController.mcp_actions
    assert_equal [:index, :show], McpChildAccountsController.mcp_actions
    assert_equal 1, McpParentAccountsController.mcp_rules.size
    assert_equal 2, McpChildAccountsController.mcp_rules.size
    assert McpChildAccountsController.mcp_rules.frozen?
  end

  test "controllers without rules are not enabled" do
    refute PhotosController.mcp_enabled?
    assert_equal [], PhotosController.mcp_actions
    assert AccountsController.mcp_enabled?
  end

  test "coverage is limited to the controller's real actions" do
    assert_equal [:index, :show, :calculate], McpReadOnlyAccountsController.mcp_actions
    assert_equal [:index, :show, :calculate], AccountsController.mcp_actions
    assert_equal [:index, :show, :create, :update, :calculate], PropertiesController.mcp_actions
  end

  test "mcp_actions ignores conditions and is ordered like ACTIONS" do
    assert_equal %i[index show create update calculate], McpConditionalAccountsController.mcp_actions
  end

  test "symbol conditions" do
    controller = instance_for(McpConditionalAccountsController)
    assert_equal [:show], controller.mcp_actions_allowed

    controller.flag = true
    assert_equal [:index, :update, :calculate], controller.mcp_actions_allowed
  end

  test "array conditions require all to pass" do
    controller = instance_for(McpConditionalAccountsController, params: { ok: '1' })
    controller.flag = true
    assert_includes controller.mcp_actions_allowed, :create

    controller = instance_for(McpConditionalAccountsController, params: { ok: '0' })
    controller.flag = true
    refute_includes controller.mcp_actions_allowed, :create
  end

  test "proc conditions with arity 0 run on the controller, others receive it" do
    controller = instance_for(McpConditionalAccountsController, params: { ok: '1' })
    controller.flag = true
    assert_includes controller.mcp_actions_allowed, :create
    assert_includes controller.mcp_actions_allowed, :update
  end

  test "unless must be falsy" do
    controller = instance_for(McpConditionalAccountsController)
    controller.flag = true
    assert_includes controller.mcp_actions_allowed, :calculate

    controller.blocked = true
    refute_includes controller.mcp_actions_allowed, :calculate
  end

  test "multiple rules union" do
    request = ActionDispatch::Request.new(Rack::MockRequest.env_for('/'))
    assert_equal [:index, :show], StandardMCP::Registry.controller_for(PropertiesController, request).mcp_actions_allowed
  end

end
