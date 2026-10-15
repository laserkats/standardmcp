require 'standard_mcp/test_helper'

class TestAppTest < ActionDispatch::IntegrationTest

  test "app boots and gem is loaded" do
    assert_equal '0.1.0', StandardMCP::VERSION
    assert Rails.application.initialized?
  end

  test "StandardMCP.configure" do
    assert_equal "ApplicationController", StandardMCP.config.parent_controller

    StandardMCP.configure do |c|
      c.server_name = "custom"
      c.parent_controller = "Api::BaseController"
    end

    assert_equal "custom", StandardMCP.config.server_name
    assert_equal "Api::BaseController", StandardMCP.config.parent_controller
    assert_equal StandardMCP::VERSION, StandardMCP.config.server_version
    assert_equal({}, StandardMCP.config.dispatch_env.call(nil))

    StandardMCP.reset_config!
    assert_equal "ApplicationController", StandardMCP.config.parent_controller
  end

  test "GET /accounts.json returns JSON through StandardAPI" do
    account = create(:account)
    create(:property, account: account)

    get "/accounts.json?limit=10"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [account.id], body.map { |a| a['id'] }
    assert_equal account.name, body.first['name']
  end

  test "ACL excludes are not rendered" do
    photo = create(:photo)

    get "/photos/#{photo.id}.json"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal photo.caption, body['caption']
    refute body.key?('internal_path')
  end

  test "table and column comments are present" do
    assert_equal "A customer organization that owns properties.", Account.connection.table_comment("accounts")
    column = Account.columns_hash["name"]
    assert_equal "Display name of the organization.", column.comment
    assert_nil Account.columns_hash["notes"].comment
  end

end
