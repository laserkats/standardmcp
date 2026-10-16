require 'standard_mcp/test_helper'

# A namespaced controller with a conditional, read-only rule: calculate is never
# exposed, so list_admin_accounts can't report a total.
module Admin
  class Account < ::Account
    self.table_name = 'accounts'
  end

  class AccountsController < ::ApplicationController
    allow_mcp only: [:index, :show], if: :admin?

    private

    def admin?
      request.headers['X-MCP-Admin'] == 'true'
    end
  end
end

# No ToolsModelless model exists for StandardAPI to infer.
class ToolsModellessController < ApplicationController
  allow_mcp
end

class ToolsTest < ActiveSupport::TestCase

  # Other test files opt in model-less controllers, which Tools.for rejects.
  setup do
    StandardMCP::Registry.stubs(:controllers).returns(
      [Admin::AccountsController, AccountsController, ContactsController, PhotosController, PropertiesController]
    )
    # Declared (and so validated against) unless a test says otherwise.
    StandardMCP.config.output_schema = true
  end

  def request_for(headers = {})
    headers = headers.transform_keys { |k| "HTTP_#{k.upcase.tr('-', '_')}" }
    ActionDispatch::Request.new(Rack::MockRequest.env_for('/mcp', headers))
  end

  # A real server with result validation on, so every tool result is checked
  # against its output schema.
  def server_for(headers = {})
    MCP::Server.new(
      name: 'standardmcp-test',
      tools: StandardMCP::Tools.for(request_for(headers)),
      configuration: MCP::Configuration.new(validate_tool_call_results: true)
    )
  end

  def rpc(server, method, params = nil)
    message = { jsonrpc: '2.0', id: 1, method: method }
    message[:params] = params if params
    # Round-tripped so keys are symbols throughout, as a client would see it.
    JSON.parse(JSON.generate(server.handle(message)), symbolize_names: true)
  end

  def list_tools(headers = {})
    rpc(server_for(headers), 'tools/list')[:result][:tools]
  end

  # The tools/call result, failing with the JSON-RPC error when there is one
  # (which is also how a result that breaks its output schema shows up).
  def call_tool(name, arguments = {}, headers = {}, server: server_for(headers))
    response = rpc(server, 'tools/call', { name: name, arguments: arguments })
    flunk "JSON-RPC error: #{response[:error]}" if response[:error]
    response[:result]
  end

  def structured(name, arguments = {}, headers = {})
    result = call_tool(name, arguments, headers)
    refute result[:isError], "unexpected tool error: #{result[:structuredContent]}"
    result[:structuredContent]
  end

  def tool_error(name, arguments = {}, headers = {})
    result = call_tool(name, arguments, headers)
    assert result[:isError], "expected a tool error, got #{result[:structuredContent]}"
    # Errors the mcp server raises itself (invalid arguments) carry text only.
    result.dig(:structuredContent, :error) || result[:content].first[:text]
  end

  def tool(name, headers = {})
    list_tools(headers).find { |t| t[:name] == name } or flunk "no tool #{name}"
  end

  def bearer(account_id)
    { 'Authorization' => "Bearer #{account_id}" }
  end

  # --- tools/list

  test "lists one read tool per allowed controller action" do
    names = list_tools.map { |t| t[:name] }

    assert_equal %w[
      calculate_accounts get_account list_accounts
      get_property list_properties
    ].sort, names.sort
  end

  test "write tools are hidden without the writes header, and non-opted-in controllers are absent" do
    names = list_tools.map { |t| t[:name] }

    refute(names.any? { |n| n.match?(/create|update|delete|destroy/) })
    refute(names.any? { |n| n.include?('photo') })
    assert_includes names, 'list_properties'

    # Photos never opted in, with or without writes.
    writes = list_tools('X-MCP-Writes' => 'true').map { |t| t[:name] }
    assert_includes writes, 'create_property'
    refute(writes.any? { |n| n.include?('photo') })
  end

  test "titles and annotations" do
    list = tool('list_properties')
    assert_equal 'List properties', list[:title]
    assert_equal 'Get property', tool('get_property')[:title]
    assert_equal 'Calculate accounts', tool('calculate_accounts')[:title]

    list_tools.each do |t|
      assert_equal({ readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
        t[:annotations], t[:name])
    end
  end

  test "descriptions carry the table comment" do
    assert_includes tool('list_properties')[:description], 'A real estate asset owned by an account.'
    assert_includes tool('get_account')[:description], 'A customer organization that owns properties.'
    assert_includes tool('calculate_accounts')[:description], 'Aggregate accounts'
  end

  test "schemas come from the schema builders" do
    request = request_for
    controller = StandardMCP::Registry.controller_for(PropertiesController, request)

    list = tool('list_properties')
    assert_equal StandardMCP::Schema::Input.for(controller, :index).keys - ['$defs'],
      list[:inputSchema].keys.map(&:to_s) - %w[$schema $defs]
    assert_equal %w[where order include limit offset distinct], list[:inputSchema][:properties].keys.map(&:to_s)
    assert_equal %w[records offset next_offset total], list[:outputSchema][:properties].keys.map(&:to_s)

    assert_equal %w[id include], tool('get_property')[:inputSchema][:properties].keys.map(&:to_s)
    assert_equal ['id'], tool('get_property')[:inputSchema][:required]
    assert_equal %w[record], tool('get_property')[:outputSchema][:properties].keys.map(&:to_s)

    assert_equal %w[where select group_by], tool('calculate_accounts')[:inputSchema][:properties].keys.map(&:to_s)
  end

  test "names are built from the controller path" do
    request = request_for('X-MCP-Admin' => 'true')
    names = StandardMCP::Tools.for(request).map(&:name_value)

    assert_includes names, 'list_admin_accounts'
    assert_includes names, 'get_admin_account'
    refute_includes names, 'calculate_admin_accounts'
  end

  # --- only

  test "only builds just the named tool" do
    StandardMCP::Schema::Input.expects(:for).once.returns({ 'type' => 'object', 'properties' => {} })

    tools = StandardMCP::Tools.for(request_for, only: 'get_property')

    assert_equal %w[get_property], tools.map(&:name_value)
  end

  test "only names that don't exist build nothing" do
    assert_empty StandardMCP::Tools.for(request_for, only: 'delete_everything')
  end

  test "only still applies the per-request conditions" do
    assert_empty StandardMCP::Tools.for(request_for, only: 'list_admin_accounts')
    assert_equal %w[list_admin_accounts],
      StandardMCP::Tools.for(request_for('X-MCP-Admin' => 'true'), only: 'list_admin_accounts').map(&:name_value)
  end

  test "tool names over the MCP limit are rejected" do
    PropertiesController.stubs(:controller_path).returns('p' * 60)

    error = assert_raises(StandardMCP::Error) { StandardMCP::Tools.for(request_for) }
    assert_match(/exceeds 64/, error.message)
  end

  test "an opted-in controller without a model raises" do
    StandardMCP::Registry.stubs(:controllers).returns([ToolsModellessController])

    error = assert_raises(StandardMCP::Error) { StandardMCP::Tools.for(request_for) }
    assert_match(/ToolsModellessController.*no model/, error.message)
  end

  test "duplicate tool names raise" do
    Admin::AccountsController.stubs(:controller_path).returns('accounts')

    error = assert_raises(StandardMCP::Error) { StandardMCP::Tools.for(request_for('X-MCP-Admin' => 'true')) }
    assert_includes error.message, 'list_accounts'
    assert_includes error.message, 'get_account'
  end

  # --- per-request hiding

  test "conditional controllers are listed only when the condition passes" do
    refute(list_tools.any? { |t| t[:name].include?('admin') })
    assert_equal %w[get_admin_account list_admin_accounts],
      list_tools('X-MCP-Admin' => 'true').map { |t| t[:name] }.grep(/admin/).sort
  end

  test "a hidden tool cannot be called" do
    result = rpc(server_for, 'tools/call', { name: 'list_admin_accounts', arguments: {} })

    assert_equal(-32602, result[:error][:code])
    assert_match(/Tool not found/, result[:error].to_s)
  end

  # --- list

  test "list returns records with paging fields" do
    accounts = create_list(:account, 2)

    content = structured('list_accounts')

    assert_equal accounts.map(&:id).sort, content[:records].map { |r| r[:id] }.sort
    assert_equal 0, content[:offset]
    assert_nil content[:next_offset]
    assert_equal 2, content[:total]
    assert content.key?(:next_offset)
  end

  test "list pages to the end" do
    create_list(:account, 5)

    first = structured('list_accounts', { limit: 2, order: { id: 'asc' } })
    assert_equal 2, first[:records].size
    assert_equal 2, first[:next_offset]
    assert_equal 5, first[:total]

    second = structured('list_accounts', { limit: 2, offset: first[:next_offset], order: { id: 'asc' } })
    assert_equal 2, second[:offset]
    assert_equal 4, second[:next_offset]

    last = structured('list_accounts', { limit: 2, offset: second[:next_offset], order: { id: 'asc' } })
    assert_equal 1, last[:records].size
    assert_nil last[:next_offset]
    assert_equal 5, last[:total]

    ids = [first, second, last].flat_map { |page| page[:records].map { |r| r[:id] } }
    assert_equal Account.order(:id).pluck(:id), ids
  end

  test "an exact final page has no next_offset" do
    create_list(:account, 4)

    page = structured('list_accounts', { limit: 2, offset: 2 })

    assert_equal 2, page[:records].size
    assert_nil page[:next_offset]
  end

  test "an offset past the end is an empty last page" do
    create_list(:account, 2)

    page = structured('list_accounts', { offset: 10 })

    assert_empty page[:records]
    assert_nil page[:next_offset]
    assert_equal 2, page[:total]
  end

  test "limit defaults from the input schema" do
    default = tool('list_accounts')[:inputSchema][:properties][:limit][:default]
    create_list(:account, default + 1)

    page = structured('list_accounts')

    assert_equal default, page[:records].size
    assert_equal default, page[:next_offset]
    assert_equal default + 1, page[:total]
  end

  test "default limit follows the configuration" do
    StandardMCP.config.default_limit = 3
    create_list(:account, 4)

    page = structured('list_accounts')

    assert_equal 3, page[:records].size
    assert_equal 3, page[:next_offset]
  end

  test "an explicit limit above the maximum is a tool error" do
    AccountsController.any_instance.stubs(:resource_limit).returns(5)

    assert_match(/limit/, tool_error('list_accounts', { limit: 6 }))
  end

  test "list applies where, order and include" do
    account = create(:account, name: 'Acme')
    create(:account, name: 'Other')
    property = create(:property, account: account, size: 10)
    create(:property, account: account, size: 20)

    by_where = structured('list_accounts', { where: { name: { eq: 'Acme' } } })
    assert_equal [account.id], by_where[:records].map { |r| r[:id] }
    assert_equal 1, by_where[:total]

    ordered = structured('list_properties', { order: { size: 'desc' } })
    assert_equal [20, 10], ordered[:records].map { |r| r[:size] }

    included = structured('list_properties', { where: { id: { eq: property.id } }, include: { account: true } })
    assert_equal 'Acme', included[:records].first[:account][:name]
  end

  test "total counts the same where, and distinct counts unique records" do
    account = create(:account)
    create_list(:property, 2, account: account)
    create(:account)

    where = { properties: { id: { gt: 0 } } }
    filtered = structured('list_accounts', { where: where })
    assert_equal 2, filtered[:records].size
    assert_equal 2, filtered[:total]

    distinct = structured('list_accounts', { where: where, distinct: true })
    assert_equal 1, distinct[:records].size
    assert_equal 1, distinct[:total]
  end

  test "total is omitted when calculate is not allowed" do
    create_list(:account, 3)

    page = structured('list_admin_accounts', { limit: 2 }, 'X-MCP-Admin' => 'true')

    assert_equal 2, page[:records].size
    refute page.key?(:total)
    # Without a total a full page may have a successor.
    assert_equal 2, page[:next_offset]

    last = structured('list_admin_accounts', { limit: 2, offset: 2 }, 'X-MCP-Admin' => 'true')
    assert_equal 1, last[:records].size
    assert_nil last[:next_offset]
  end

  test "mask_for restricts records and total" do
    mine = create(:account)
    create_list(:account, 2)
    create(:property, account: mine)
    create_list(:property, 2)

    accounts = structured('list_accounts', {}, bearer(mine.id))
    assert_equal [mine.id], accounts[:records].map { |r| r[:id] }
    assert_equal 1, accounts[:total]

    properties = structured('list_properties', {}, bearer(mine.id))
    assert_equal 1, properties[:records].size
    assert_equal 3, structured('list_properties')[:records].size
  end

  test "total is omitted for controllers that don't allow calculate" do
    create_list(:property, 2)

    refute structured('list_properties').key?(:total)
  end

  test "list with an invalid argument is a tool error" do
    assert_match(/Invalid arguments/, tool_error('list_accounts', { limit: 0 }))
    assert_match(/Invalid arguments/, tool_error('list_accounts', { nope: 1 }))
  end

  test "an index failure is reported without paging fields" do
    AccountsController.any_instance.stubs(:index).raises(ActionController::BadRequest)

    assert_equal 'Bad Request', tool_error('list_accounts')
  end

  # --- get

  test "get returns the record" do
    account = create(:account)

    content = structured('get_account', { id: account.id })

    assert_equal account.id, content[:record][:id]
    assert_equal account.name, content[:record][:name]
  end

  test "get with include loads associations" do
    property = create(:property)
    photo = create(:photo, property: property)

    content = structured('get_property', { id: property.id, include: { photos: true } })

    assert_equal [photo.id], content[:record][:photos].map { |p| p[:id] }
    refute content[:record][:photos].first.key?(:internal_path)
  end

  test "get of a missing id is a not-found tool error" do
    assert_equal 'Account not found', tool_error('get_account', { id: 0 })
  end

  test "get of a masked record is not found" do
    mine = create(:account)
    other = create(:account)

    assert_equal 'Account not found', tool_error('get_account', { id: other.id }, bearer(mine.id))
  end

  test "get without an id is a tool error" do
    assert_match(/id/, tool_error('get_account'))
  end

  # --- calculate

  test "calculate counts" do
    create_list(:account, 3)

    assert_equal [3], structured('calculate_accounts', { select: [{ count: '*' }] })[:result]
  end

  test "calculate honors where and mask_for" do
    mine = create(:account, status: 'active')
    create(:account, status: 'suspended')

    assert_equal [1], structured('calculate_accounts', { select: [{ count: '*' }], where: { status: { eq: 'suspended' } } })[:result]
    assert_equal [1], structured('calculate_accounts', { select: [{ count: '*' }] }, bearer(mine.id))[:result]
  end

  test "calculate group_by returns an object keyed by group" do
    create(:account, status: 'active')
    create(:account, status: 'active')
    create(:account, status: 'suspended')

    result = structured('calculate_accounts', { select: [{ count: '*' }], group_by: 'status' })[:result]

    assert_equal({ active: 2, suspended: 1 }, result.symbolize_keys)
  end

  test "calculate with several aggregates and no group_by works" do
    create_list(:account, 2)

    result = structured('calculate_accounts', { select: [{ count: '*' }, { maximum: 'id' }] })[:result]

    # One row holding a value per aggregate.
    assert_equal [[2, Account.maximum(:id)]], result
  end

  test "group_by with two aggregates is a tool error, not an exception" do
    server = server_for
    AccountsController.any_instance.expects(:calculate).never

    result = call_tool('calculate_accounts', { select: [{ count: '*' }, { maximum: 'id' }], group_by: 'status' }, server: server)

    assert result[:isError]
    assert_match(/Invalid arguments/, result[:content].first[:text])
  end

  test "group_by with an unknown column is a tool error" do
    assert_match(/Invalid arguments/, tool_error('calculate_accounts', { select: [{ count: '*' }], group_by: 'nope' }))
  end

  test "calculate of an unknown column is a tool error" do
    assert_match(/Invalid arguments/, tool_error('calculate_accounts', { select: [{ sum: 'nope' }] }))
  end

  test "calculate without select is a tool error" do
    assert_match(/select/, tool_error('calculate_accounts'))
  end

  # --- authorization and errors

  test "a call that is no longer allowed is a not-allowed tool error" do
    server = server_for('X-MCP-Writes' => 'true')
    create(:account)
    StandardMCP::Dispatcher.any_instance.stubs(:ensure_allowed!).raises(StandardMCP::ActionNotAllowed)

    result = call_tool('list_accounts', {}, server: server)

    assert result[:isError]
    assert_equal 'Action index is not allowed', result[:structuredContent][:error]
  end

  test "a server error propagates as a JSON-RPC error without internals" do
    AccountsController.any_instance.stubs(:index).raises(RuntimeError, 'secret SELECT * FROM accounts')

    response = rpc(server_for, 'tools/call', { name: 'list_accounts', arguments: {} })

    assert_nil response[:result]
    assert_equal(-32603, response[:error][:code])
    refute_match(/secret|SELECT/, response.to_s)
  end

  test "an unexpected status is a JSON-RPC error without internals" do
    StandardMCP::Dispatcher.any_instance.stubs(:perform).returns(
      StandardMCP::Dispatcher::Result.new(status: 500, headers: {}, body: 'boom')
    )

    response = rpc(server_for, 'tools/call', { name: 'list_accounts', arguments: {} })

    assert_equal(-32603, response[:error][:code])
    refute_match(/boom/, response.to_s)
  end

  test "tool calls are instrumented once per dispatch" do
    create(:account)
    events = []

    ActiveSupport::Notifications.subscribed(->(*args) { events << args.last[:action] }, 'dispatch.standard_mcp') do
      structured('list_accounts')
      structured('get_account', { id: Account.first.id })
    end

    # list_accounts also dispatches calculate for its total.
    assert_equal %i[index calculate show], events
  end

  # --- output_schema

  test "tools declare no output schema by default, and still return structured content" do
    StandardMCP.reset_config!
    create(:account, name: 'Acme')

    assert_equal false, StandardMCP.config.output_schema
    list_tools.each { |t| refute t.key?(:outputSchema), t[:name] }

    result = call_tool('list_accounts')
    assert_equal 1, result[:structuredContent][:records].size
    assert_equal result[:structuredContent], JSON.parse(result[:content].first[:text], symbolize_names: true)
  end

  test "Schema::Output is not built when output_schema is off" do
    StandardMCP.reset_config!
    StandardMCP::Schema::Output.expects(:for).never

    list_tools
  end

  test "output_schema declares outputSchema and results validate against it" do
    StandardMCP.config.output_schema = true
    create(:property, account: create(:account))

    assert(list_tools.all? { |t| t[:outputSchema] })
    assert_equal 1, structured('list_properties')[:records].size
  end

  test "a result that breaks its output schema is rejected only when it is declared" do
    StandardMCP::Response.stubs(:from).returns(
      MCP::Tool::Response.new([{ type: 'text', text: '{}' }], structured_content: { records: 'nope' })
    )

    assert_equal(-32603, rpc(server_for, 'tools/call', { name: 'list_accounts', arguments: {} })[:error][:code])

    StandardMCP.config.output_schema = false
    assert_nil rpc(server_for, 'tools/call', { name: 'list_accounts', arguments: {} })[:error]
  end

  # --- shallow where

  test "where is a loose object by default" do
    StandardMCP.reset_config!

    where = tool('list_accounts')[:inputSchema][:properties][:where]

    assert_equal %w[object array], where[:type]
    assert_equal %i[description type], where.keys.sort
    assert_equal where, tool('calculate_accounts')[:inputSchema][:properties][:where]
    assert_includes where[:description], 'name (string): Display name of the organization.'
  end

  test "deep mode lists the typed where" do
    StandardMCP.config.input_schema_depth = 'deep'

    schema = tool('list_accounts')[:inputSchema]

    assert schema[:'$defs'].key?(:where)
    assert schema[:'$defs'].key?(:string_filter)
  end

  test "valid filters work in shallow mode, including AND/OR arrays and nested associations" do
    acme = create(:account, name: 'Acme')
    other = create(:account, name: 'Other')
    create(:property, account: acme, name: 'HQ', size: 10, kind: 'office')
    create(:property, account: acme, name: 'Depot', size: 20, kind: 'industrial')
    create(:property, account: other, name: 'Shop', size: 30, kind: 'retail')

    names = ->(where) { structured('list_properties', { where: where, order: { id: 'asc' } })[:records].map { |r| r[:name] } }

    assert_equal %w[Depot Shop], names.call({ size: { gt: 10 } })
    assert_equal %w[HQ], names.call({ name: { ilike: 'h%' }, kind: { in: %w[office retail] } })
    assert_equal %w[HQ Shop], names.call([{ size: { lt: 20 } }, 'OR', { kind: { eq: 'retail' } }])
    assert_equal %w[HQ Depot], names.call({ account: { name: { eq: 'Acme' } } })
    assert_equal [other.id], structured('list_accounts', { where: { properties: { size: { gte: 30 } } } })[:records].map { |r| r[:id] }
    assert_equal [2], structured('calculate_accounts', { select: [{ count: '*' }], where: [{ name: { eq: 'Acme' } }, 'OR', { name: { eq: 'Other' } }] })[:result]
  end

  test "bad filters are readable tool errors" do
    {
      { foo: { eq: 1 } } => /\AUnknown column 'foo' for properties \(columns: id, account_id/,
      { size: { ilike: 'a%' } } => /\AUnsupported operator 'ilike' for size \(integer\)/,
      { size: { bogus: 1 } } => /\AUnsupported operator 'bogus' for size \(integer\)/,
      { size: { gte: 'abc' } } => /\AInvalid value for size: "abc" \(gte expects an integer\)/,
      { size: 5 } => /\Asize takes an operator object/,
      { kind: { eq: 'bogus' } } => /\AInvalid value for kind: "bogus"/,
      { account: { nope: { eq: 1 } } } => /\AUnknown column 'nope' for accounts/,
      { account: 5 } => /\AThe filter on account must be an object/,
      [{ size: { eq: 1 } }, { size: { eq: 2 } }] => /must alternate filter objects/
    }.each do |where, expected|
      message = tool_error('list_properties', { where: where })

      assert_match expected, message, where.inspect
      refute_match(/SELECT|WHERE|FROM|"properties"/, message, where.inspect)
    end

    assert_match(/Unsupported operator 'like' for id/, tool_error('calculate_accounts', { select: [{ count: '*' }], where: { id: { like: 'a' } } }))
  end

  test "a bad filter is not dispatched and does not leak the mask" do
    mine = create(:account)
    StandardMCP::Dispatcher.any_instance.expects(:call).never

    result = call_tool('list_accounts', { where: { id: { ilike: 'x' }, bogus: { eq: 1 } } }, bearer(mine.id))

    assert result[:isError]
    text = result[:content].first[:text]
    assert_match(/Unsupported operator 'ilike' for id/, text)
    assert_match(/Unknown column 'bogus' for accounts/, text)
    refute_match(/SELECT|WHERE|"accounts"|#{mine.id}/, text)
    assert_equal text, JSON.generate(result[:structuredContent])
  end

  test "a filter the model check lets through but the database rejects is a tool error without SQL" do
    # A malformed tsquery is only known to Postgres.
    result = call_tool('list_properties', { where: { name: { ts_match: 'foo bar &' } } }, bearer(create(:account).id))

    assert result[:isError]
    assert_equal "where has a value or operator that doesn't fit the column's type", result[:structuredContent][:error]
    refute_match(/SELECT|tsquery|"properties"/, result.to_s)
  end

  test "deep mode rejects a bad filter by schema before the model check" do
    StandardMCP.config.input_schema_depth = 'deep'
    StandardMCP::Schema::Where.expects(:errors).never

    assert_match(/Invalid arguments/, tool_error('list_properties', { where: { size: { ilike: 'a' } } }))
    assert_match(/Invalid arguments/, tool_error('list_properties', { where: { foo: { eq: 1 } } }))
    assert_match(/Invalid arguments/, tool_error('list_properties', { where: { size: { gte: 'abc' } } }))
  end

  test "deep mode still runs valid filters" do
    StandardMCP.config.input_schema_depth = :deep
    create(:account, name: 'Acme')

    assert_equal 1, structured('list_accounts', { where: [{ name: { eq: 'Acme' } }, 'OR', { name: { eq: 'x' } }] })[:records].size
  end

  # --- size

  # Measured with the two controllers below; the limits leave about 10% room.
  test "the shallow tools/list stays small" do
    StandardMCP.reset_config!
    StandardMCP::Registry.stubs(:controllers).returns([AccountsController, PropertiesController])
    tools = list_tools
    sizes = tools.to_h { |t| [t[:name], JSON.generate(t).size] }

    assert_equal 5, tools.size
    assert_operator JSON.generate(tool('list_accounts')[:inputSchema]).size, :<=, 2_950
    assert_operator sizes['list_accounts'], :<=, 3_400
    assert_operator sizes['list_properties'], :<=, 4_500
    assert_operator sizes['calculate_accounts'], :<=, 3_200
    assert_operator JSON.generate(tools).size, :<=, 13_200
  end

end
