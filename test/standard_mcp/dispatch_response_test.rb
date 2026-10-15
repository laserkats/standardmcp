require 'standard_mcp/test_helper'

# Real dispatcher results through Response.from, so the shapes each side
# assumes about StandardAPI stay in agreement.
class DispatchResponseTest < ActiveSupport::TestCase

  def respond(klass, action, params = {}, headers = {})
    headers = headers.transform_keys { |k| "HTTP_#{k.upcase.tr('-', '_')}" }
    request = ActionDispatch::Request.new(Rack::MockRequest.env_for('/mcp', headers))
    result = StandardMCP::Dispatcher.new(request).call(klass, action, params)
    StandardMCP::Response.from(result, action: action).to_h
  end

  def writes
    { 'X-MCP-Writes' => 'true', 'Authorization' => 'Bearer 0' }
  end

  test "index wraps records" do
    account = create(:account)

    response = respond(AccountsController, :index, { 'limit' => 10 })

    assert_equal false, response[:isError]
    assert_equal [account.id], response[:structuredContent][:records].map { |r| r['id'] }
  end

  test "show wraps the record" do
    account = create(:account)

    response = respond(AccountsController, :show, { 'id' => account.id })

    assert_equal account.id, response[:structuredContent][:record]['id']
  end

  test "calculate wraps the result" do
    create_list(:account, 2)

    response = respond(AccountsController, :calculate, { 'select' => [{ 'count' => '*' }] })

    assert_equal [2], response[:structuredContent][:result]
  end

  test "create returns the record" do
    account = create(:account)

    response = respond(PropertiesController, :create,
      { 'property' => { 'name' => 'HQ', 'account_id' => account.id } }, writes)

    assert_equal false, response[:isError]
    assert_equal 'HQ', response[:structuredContent][:record]['name']
  end

  test "invalid create is a tool error with validation errors" do
    response = respond(PropertiesController, :create, { 'property' => { 'name' => '' } }, writes)

    assert_equal true, response[:isError]
    assert_includes response[:structuredContent][:error], "can't be blank"
    assert response[:structuredContent][:errors].key?('name')
  end

  test "missing limit is a tool error" do
    response = respond(AccountsController, :index)

    assert_equal true, response[:isError]
    assert_includes response[:structuredContent][:error], 'limit'
  end

  test "missing record is a not-found tool error" do
    response = respond(AccountsController, :show, { 'id' => 0 })

    assert_equal true, response[:isError]
    assert_equal 'Account not found', response[:structuredContent][:error]
  end

end
