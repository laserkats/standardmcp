require 'standard_mcp/test_helper'

# Properties with a filterable account_name, which the test app's PropertyACL
# `schemas` hook defines when the where names account_id. Only listed for
# callers sending X-MCP-Scoped.
class ScopedPropertiesController < ApplicationController
  allow_mcp only: [:index, :show], if: :scoped?

  def self.model
    Property
  end

  def property_wheres
    super + [:account_name]
  end

  private

  def scoped?
    request.headers['X-MCP-Scoped'] == 'true'
  end
end

# A callback that refuses revoked bearers, on every action including json_schema.
class GatedPropertiesController < ApplicationController
  allow_mcp only: [:index, :show], if: :gated?
  before_action :refuse_revoked

  def self.model
    Property
  end

  private

  def gated?
    request.headers['X-MCP-Gated'] == 'true'
  end

  def refuse_revoked
    head :unauthorized if request.authorization == 'Bearer revoked'
  end
end

class DescribeAttributesTest < ActiveSupport::TestCase

  SCOPED = { 'X-MCP-Scoped' => 'true' }.freeze
  GATED = { 'X-MCP-Gated' => 'true' }.freeze

  setup do
    StandardMCP::Registry.stubs(:controllers).returns(
      [AccountsController, ContactsController, GatedPropertiesController, PropertiesController, ScopedPropertiesController]
    )
  end

  def request_for(headers = {})
    headers = headers.transform_keys { |k| k.start_with?('Authorization') ? 'HTTP_AUTHORIZATION' : "HTTP_#{k.upcase.tr('-', '_')}" }
    ActionDispatch::Request.new(Rack::MockRequest.env_for('/mcp', headers))
  end

  def rpc(headers, name, arguments)
    server = MCP::Server.new(name: 'standardmcp-test', tools: StandardMCP::Tools.for(request_for(headers)))
    message = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: name, arguments: arguments } }
    JSON.parse(JSON.generate(server.handle(message)), symbolize_names: true)
  end

  def result(headers, name, arguments)
    response = rpc(headers, name, arguments)
    flunk "JSON-RPC error: #{response[:error]}" if response[:error]
    response[:result]
  end

  def attributes(headers, resource, where = nil)
    arguments = { resource: resource, where: where }.compact
    found = result(headers, 'describe_attributes', arguments)
    refute found[:isError], "unexpected tool error: #{found[:structuredContent]}"
    found[:structuredContent]
  end

  def query(headers, resource, where = nil)
    arguments = { resource: resource, where: where }.compact
    found = result(headers, 'describe_query', arguments)
    refute found[:isError], "unexpected tool error: #{found[:structuredContent]}"
    found[:structuredContent]
  end

  def error(headers, name, arguments)
    found = result(headers, name, arguments)
    assert found[:isError]
    found.dig(:structuredContent, :error)
  end

  # What the json_schema action renders for the controller.
  def rendered(klass, headers = {}, params = {})
    StandardMCP::Dispatcher.new(request_for(headers)).call(klass, :json_schema, params).json
  end

  # --- the view

  test "describe_attributes is what the json_schema action renders" do
    assert_equal rendered(PropertiesController), JSON.parse(JSON.generate(attributes({}, 'properties')))
    assert_equal rendered(AccountsController), JSON.parse(JSON.generate(attributes({}, 'accounts')))
  end

  test "the text content is the same document" do
    found = result({}, 'describe_attributes', { resource: 'properties' })

    assert_equal JSON.parse(JSON.generate(found[:structuredContent])), JSON.parse(found[:content].first[:text])
  end

  test "the JSON Schema carries types, comments, enums, defaults, readOnly and required" do
    schema = attributes({}, 'properties')
    properties = schema[:properties]

    assert_equal 'object', schema[:type]
    assert_equal 'A real estate asset owned by an account.', schema[:description]
    assert_equal ['integer', 'null'], properties[:size][:type]
    assert_equal 'Rentable area in square feet.', properties[:size][:description]
    assert_equal %w[office retail industrial], properties[:kind][:enum].compact
    assert_equal true, properties[:available][:default]
    assert_equal true, properties[:id][:readOnly]
    assert_equal ['name'], schema[:required]
  end

  test "the schema is returned unchanged: no keyword is added, removed or renamed" do
    schema =attributes({ 'X-MCP-Writes' => 'true' }, 'contacts')
    action = rendered(ContactsController, 'X-MCP-Writes' => 'true')

    assert_equal action, JSON.parse(JSON.generate(schema))
    assert_equal 'string', action['properties']['name']['type']
    assert_equal 50, action['properties']['name']['maxLength']
    assert_equal 150, action['properties']['age']['exclusiveMaximum']
  end

  test "no include is forwarded to the action" do
    StandardMCP::Dispatcher.any_instance.expects(:call).with(PropertiesController, :json_schema, {})
      .returns(StandardMCP::Dispatcher::Result.new(status: 200, headers: {}, body: '{}'))

    attributes({}, 'properties')
  end

  # --- the where

  test "the ACL schemas hook sees params[:where]" do
    where = { account_id: { eq: 1 } }

    with = attributes(SCOPED, 'scoped_properties', where)
    without = attributes(SCOPED, 'scoped_properties')

    assert_equal 'Name of the account the list is for.', with[:properties][:account_name][:description]
    assert_equal true, with[:properties][:account_name][:readOnly]
    refute without[:properties].key?(:account_name)
    refute attributes(SCOPED, 'scoped_properties', { name: { eq: 'x' } })[:properties].key?(:account_name)
  end

  test "an array where reaches the hook too" do
    where = [{ account_id: { eq: 1 } }, 'OR', { account_id: { eq: 2 } }]

    assert attributes(SCOPED, 'scoped_properties', where)[:properties].key?(:account_name)
  end

  test "the definition for a where is in describe_query too, and a filter on it validates" do
    where = { account_id: { eq: 1 }, account_name: { eq: 'Acme' } }
    document = query(SCOPED, 'scoped_properties', where)
    key = document[:where][:keys].find { |k| k[:name] == 'account_name' }

    assert_equal 'string', key[:type]
    assert_equal 'Name of the account the list is for.', key[:description]

    # Without account_id in the where there is no definition, so only the name.
    plain = query(SCOPED, 'scoped_properties')[:where][:keys].find { |k| k[:name] == 'account_name' }
    assert_equal({ name: 'account_name' }, plain)
  end

  test "a filter on it is checked as a string" do
    errors = StandardMCP::Schema::Where.errors(
      StandardMCP::Registry.controller_for(ScopedPropertiesController, request_for(SCOPED)),
      { 'account_id' => { 'eq' => 1 }, 'account_name' => { 'gte' => 'x' } }
    )

    assert_empty errors
    errors = StandardMCP::Schema::Where.errors(
      StandardMCP::Registry.controller_for(ScopedPropertiesController, request_for(SCOPED)),
      { 'account_id' => { 'eq' => 1 }, 'account_name' => { 'contains' => 'x' } }
    )
    assert_match(/Unsupported operator 'contains' for account_name \(string\)/, errors.first)
  end

  test "a where definitions can't be used is an error before anything is dispatched" do
    StandardMCP::Dispatcher.any_instance.expects(:call).never

    assert_match(/\AUnknown filter key 'nope' for properties/, error({}, 'describe_attributes', { resource: 'properties', where: { nope: { eq: 1 } } }))
    assert_match(/must alternate/, error({}, 'describe_attributes', { resource: 'properties', where: [{ size: { eq: 1 } }, { size: { eq: 2 } }] }))
  end

  test "definitions of one where don't leak into another" do
    request = request_for(SCOPED)
    controller = StandardMCP::Registry.controller_for(ScopedPropertiesController, request)

    scoped = StandardMCP::Schema::Definitions.for(controller, Property, { 'account_id' => { 'eq' => 1 } })
    plain = StandardMCP::Schema::Definitions.for(controller, Property, nil)
    again = StandardMCP::Schema::Definitions.for(controller, Property, { 'account_id' => { 'eq' => 1 } })

    assert_includes scoped.names, 'account_name'
    refute_includes plain.names, 'account_name'
    assert_includes again.names, 'account_name'
  end

  # --- authorization

  test "a callback that refuses the caller makes describe_attributes an error" do
    assert_equal 'Unauthorized', error(GATED.merge('Authorization' => 'Bearer revoked'), 'describe_attributes', { resource: 'gated_properties' })
    assert_equal 'Property', attributes(GATED.merge('Authorization' => 'Bearer 1'), 'gated_properties')[:title]
  end

  test "a 5xx from the action raises" do
    StandardMCP::Dispatcher.any_instance.stubs(:call)
      .returns(StandardMCP::Dispatcher::Result.new(status: 500, headers: {}, body: 'boom'))
    request = request_for
    entries = StandardMCP::Resources.entries(StandardMCP::Registry.allowed(request))

    assert_raises(StandardMCP::DispatchError) { StandardMCP::Tools.describe(request, entries, 'describe_attributes', 'properties') }
  end

  test "a 403 or 404 from the action is an error result" do
    request = request_for
    entries = StandardMCP::Resources.entries(StandardMCP::Registry.allowed(request))

    { 403 => 'Forbidden', 404 => 'Not found' }.each do |status, message|
      StandardMCP::Dispatcher.any_instance.stubs(:call)
        .returns(StandardMCP::Dispatcher::Result.new(status: status, headers: {}, body: ''))
      response = StandardMCP::Tools.describe(request, entries, 'describe_attributes', 'properties')

      assert response.error?
      assert_equal message, response.structured_content[:error]
    end
  end

  test "a caller with no action on the resource gets the unknown-resource error" do
    assert_match(/Unknown resource "contacts"/, StandardMCP::Tools.describe(request_for, [], 'describe_attributes', 'contacts').structured_content[:error])

    request = request_for
    entries = StandardMCP::Resources.entries(StandardMCP::Registry.allowed(request))
    response = StandardMCP::Tools.describe(request, entries, 'describe_attributes', 'contacts')

    assert response.error?
    assert_equal 'Unknown resource "contacts"', response.structured_content[:error]
    assert_nil StandardMCP::Resources.attributes(request, entries, 'contacts')
  end

  test "the dispatcher still refuses json_schema for a controller the caller has no action on" do
    assert_raises(StandardMCP::ActionNotAllowed) do
      StandardMCP::Dispatcher.new(request_for).call(ContactsController, :json_schema)
    end
  end

end
