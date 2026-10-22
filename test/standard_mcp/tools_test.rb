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
      calculate_accounts describe_attributes describe_query get_account list_accounts
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

  test "a limit above max_limit is rejected by schema validation, whatever the controller allows" do
    StandardMCP::Dispatcher.any_instance.expects(:call).never

    assert_equal 100, tool('list_accounts')[:inputSchema][:properties][:limit][:maximum]
    assert_match(/Invalid arguments.*limit/, tool_error('list_accounts', { limit: 101 }))
  end

  test "max_limit is the largest page, and nil leaves the controller's resource_limit" do
    create_list(:account, 3)
    StandardMCP.config.max_limit = 2

    assert_equal 2, tool('list_accounts')[:inputSchema][:properties][:limit][:maximum]
    assert_equal 2, structured('list_accounts', { limit: 2 })[:records].size
    assert_match(/Invalid arguments.*limit/, tool_error('list_accounts', { limit: 3 }))
    # The default page is held to it too.
    assert_equal 2, structured('list_accounts')[:records].size

    StandardMCP.config.max_limit = nil
    assert_equal 1000, tool('list_accounts')[:inputSchema][:properties][:limit][:maximum]
    assert_equal 3, structured('list_accounts', { limit: 500 })[:records].size
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

  test "group_by with an unknown column is a tool error that points at describe_attributes" do
    assert_equal 'Unknown attribute "nope" in group_by for accounts. Call describe_attributes {"resource": "accounts"} ' \
      'to see the attributes.', tool_error('calculate_accounts', { select: [{ count: '*' }], group_by: 'nope' })
  end

  test "calculate of an unknown column is a tool error" do
    assert_match(/\AUnknown attribute "nope" in select for accounts\. Call describe_attributes/,
      tool_error('calculate_accounts', { select: [{ sum: 'nope' }] }))
  end

  test "calculate checks the aggregates against the columns they take" do
    assert_equal "sum can't be used on 'name'; it takes: id.", tool_error('calculate_accounts', { select: [{ sum: 'name' }] })
    assert_equal "minimum doesn't take distinct.", tool_error('calculate_accounts', { select: [{ minimum: { distinct: 'name' } }] })
    assert_equal "Unknown aggregate 'median' in select; use minimum, maximum, average, sum, count.",
      tool_error('calculate_accounts', { select: [{ median: 'id' }] })
    # StandardAPI would turn a dotted name into a model.
    assert_match(/Unknown attribute "kernel.exit"/, tool_error('calculate_accounts', { select: [{ count: 'kernel.exit' }] }))
    assert_match(/Unknown attribute "\*"/, tool_error('calculate_accounts', { select: [{ sum: '*' }] }))

    create(:account)
    assert_equal [1], structured('calculate_accounts', { select: [{ count: { distinct: 'name' } }] })[:result]
  end

  test "an unknown order key and an unknown include key are tool errors that point at describe_query" do
    assert_match(/\AUnknown order key 'rent' for properties\. Call describe_query {"resource": "properties"} to see the keys you can order by\./,
      tool_error('list_properties', { order: { rent: 'asc' } }))
    assert_match(/\AUnknown include key 'nope' for properties\. Call describe_query {"resource": "properties"} to see the associations you can include\./,
      tool_error('list_properties', { include: { nope: {} } }))
    assert_match(/Unknown include key 'photos' for accounts/, tool_error('get_account', { id: create(:account).id, include: { photos: {} } }))
  end

  test "valid order and include are dispatched, with nesting left to StandardAPI" do
    account = create(:account)
    create(:property, account: account, name: 'B')
    create(:property, account: account, name: 'A')

    records = structured('list_properties', { order: { name: 'asc' }, include: { account: true } })[:records]

    assert_equal %w[A B], records.map { |r| r[:name] }
    assert_equal account.id, records.first.dig(:account, :id)
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

    # The describe tools return a document of their own, not a record.
    assert(list_tools.reject { |t| t[:name].start_with?('describe_') }.all? { |t| t[:outputSchema] })
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
    assert_includes where[:description], 'describe_query {"resource": "accounts"}'
    refute_includes where[:description], 'Display name of the organization'
  end

  # Real columns of the test models that none of the examples in the shallow
  # schemas use, so none may appear anywhere in tools/list.
  COLUMN_NAMES = %w[
    account_id property_id built_on listed_at metadata internal_path caption
    created_at updated_at available
  ].freeze

  test "the shallow tools/list names no column of a model" do
    # Output schemas, which are opt-in, describe the records.
    StandardMCP.config.output_schema = false
    StandardMCP::Registry.stubs(:controllers).returns(
      [Admin::AccountsController, AccountsController, ContactsController, PhotosController, PropertiesController]
    )
    json = JSON.generate(list_tools(WRITES.merge('X-MCP-Admin' => 'true')))

    COLUMN_NAMES.each { |name| refute_includes json, name, "tools/list names the column #{name}" }
    # Nor an association or enum value: the keys are for describe_query.
    %w[photos industrial retail].each { |name| refute_includes json, name, "tools/list names #{name}" }
  end

  test "deep mode does name the columns" do
    StandardMCP.config.input_schema_depth = 'deep'

    assert_includes JSON.generate(list_tools), 'built_on'
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
      { foo: { eq: 1 } } => /\AUnknown filter key 'foo' for properties\. Call describe_query {"resource": "properties"} with this where/,
      { size: { ilike: 'a%' } } => /\AUnsupported operator 'ilike' for size \(integer\)/,
      { size: { bogus: 1 } } => /\AUnsupported operator 'bogus' for size \(integer\)/,
      { size: { gte: 'abc' } } => /\AInvalid value for size: "abc" \(gte expects an integer\)/,
      { size: 5 } => /\Asize takes an operator object/,
      { kind: { eq: 'bogus' } } => /\AInvalid value for kind: "bogus"/,
      { account: { nope: { eq: 1 } } } => /\AUnknown filter key 'nope' for accounts \(under account\)/,
      { account: 5 } => /\AThe filter on account must be an object/,
      [{ size: { eq: 1 } }, { size: { eq: 2 } }] => /must alternate filter objects/
    }.each do |where, expected|
      message = tool_error('list_properties', { where: where })

      assert_match expected, message, where.inspect
      refute_match(/SELECT|WHERE|FROM/, message, where.inspect)
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
    assert_match(/Unknown filter key 'bogus' for accounts/, text)
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

  # --- describe

  WRITES = { 'X-MCP-Writes' => 'true' }.freeze

  DESCRIBES = %w[describe_query describe_attributes].freeze

  def describe_enum(headers = {}, name = 'describe_query')
    tool(name, headers).dig(:inputSchema, :properties, :resource, :enum).sort
  end

  test "the describe tools take a resource and an optional where, and are read-only" do
    DESCRIBES.each do |name|
      describe = tool(name)

      assert_equal ['resource'], describe[:inputSchema][:required], name
      assert_equal false, describe[:inputSchema][:additionalProperties], name
      assert_equal %i[resource where], describe[:inputSchema][:properties].keys, name
      assert_equal 'string', describe[:inputSchema].dig(:properties, :resource, :type), name
      assert_equal %w[object array], describe[:inputSchema].dig(:properties, :where, :type), name
      assert_equal({ readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
        describe[:annotations], name)
      refute describe.key?(:outputSchema), name
    end
  end

  test "the describe tools say what they return" do
    query = tool('describe_query')
    attributes = tool('describe_attributes')

    assert_equal 'Describe what a resource can be queried by', query[:title]
    %w[keys operators associations].each { |word| assert_includes query[:description], word }
    assert_equal 'Describe what a resource contains', attributes[:title]
    ['JSON Schema', '"read"', '"write"', 'create and update', 'type', 'enum', 'default', 'readOnly', 'required']
      .each { |word| assert_includes attributes[:description], word }
    %w[writable withheld only_in].each { |word| refute_includes attributes[:description], word }
  end

  test "the where parameter is generic: it names no group" do
    where = tool('describe_query')[:inputSchema].dig(:properties, :where, :description)

    assert_includes where, 'The where you will use to list records'
    assert_includes where, 'only_in'
    assert_includes where, 'types'
    refute_match(/librar/i, JSON.generate(list_tools))
    assert_equal where, tool('describe_attributes')[:inputSchema].dig(:properties, :where, :description)
  end

  test "the describe enum is the resources of the caller" do
    DESCRIBES.each do |name|
      assert_equal %w[accounts properties], describe_enum({}, name)
      assert_equal %w[accounts contacts properties], describe_enum(WRITES, name)
      assert_equal %w[accounts admin_accounts properties], describe_enum({ 'X-MCP-Admin' => 'true' }, name)
    end
  end

  test "a resource of the caller is described as the schema resource describes it" do
    request = request_for(WRITES)
    entries = StandardMCP::Resources.entries(StandardMCP::Registry.allowed(request))
    documents = {
      'describe_query' => StandardMCP::Resources.document(request, entries, 'properties'),
      'describe_attributes' => StandardMCP::Resources.attributes(request, entries, 'properties').structured_content
    }

    documents.each do |name, resource|
      result = call_tool(name, { resource: 'properties' }, WRITES)
      document = JSON.parse(JSON.generate(result[:structuredContent]))

      refute result[:isError]
      assert_equal document, JSON.parse(result[:content].first[:text])
      assert_equal JSON.parse(JSON.generate(resource)), document
    end
    assert_equal 'properties', structured('describe_query', { resource: 'properties' }, WRITES)[:resource]
    assert_equal 'Property', structured('describe_attributes', { resource: 'properties' }, WRITES).dig(:read, :title)
  end

  test "describe_attributes is the schemas the read_schema and write_schema actions render" do
    dispatcher = StandardMCP::Dispatcher.new(request_for(WRITES))
    read = dispatcher.call(PropertiesController, :read_schema).json
    write = dispatcher.call(PropertiesController, :write_schema).json

    assert_equal({ 'read' => read, 'write' => write },
      JSON.parse(JSON.generate(structured('describe_attributes', { resource: 'properties' }, WRITES))))
  end

  test "a namespaced resource is written with underscores" do
    document = structured('describe_query', { resource: 'admin_accounts' }, 'X-MCP-Admin' => 'true')

    assert_equal 'admin_accounts', document[:resource]
    assert document.key?(:where)
    assert_equal 'Account', structured('describe_attributes', { resource: 'admin_accounts' }, 'X-MCP-Admin' => 'true').dig(:read, :title)
  end

  test "a hidden resource is not in the enum and can't be described" do
    DESCRIBES.each do |name|
      refute_includes describe_enum({}, name), 'contacts'
      refute_includes describe_enum({}, name), 'admin_accounts'

      assert_includes tool_error(name, { resource: 'contacts' }), 'resource'
      assert_includes tool_error(name, { resource: 'admin_accounts' }), 'resource'
      assert_includes tool_error(name, { resource: 'photos' }), 'resource'
    end
  end

  test "a where is dispatched to read_schema and write_schema as params[:where]" do
    where = { size: { gte: 1 } }
    result = StandardMCP::Dispatcher::Result.new(status: 200, headers: {}, body: '{"title":"Property"}')
    %i[read_schema write_schema].each do |action|
      StandardMCP::Dispatcher.any_instance.expects(:call)
        .with(PropertiesController, action, { 'where' => { 'size' => { 'gte' => 1 } } }).returns(result)
    end

    assert_equal({ read: { title: 'Property' }, write: { title: 'Property' } },
      structured('describe_attributes', { resource: 'properties', where: where }, WRITES))
  end

  test "describe_attributes dispatches with no where when none is given, and never an include" do
    result = StandardMCP::Dispatcher::Result.new(status: 200, headers: {}, body: '{"title":"Property"}')
    %i[read_schema write_schema].each do |action|
      StandardMCP::Dispatcher.any_instance.expects(:call).with(PropertiesController, action, {}).returns(result)
    end

    structured('describe_attributes', { resource: 'properties' }, WRITES)
  end

  test "a caller who can't write gets only the read schema, and no write_schema is dispatched" do
    result = StandardMCP::Dispatcher::Result.new(status: 200, headers: {}, body: '{"title":"Property"}')
    StandardMCP::Dispatcher.any_instance.expects(:call).with(PropertiesController, :read_schema, {}).returns(result)

    assert_equal({ read: { title: 'Property' } }, structured('describe_attributes', { resource: 'properties' }))
  end

  test "a where that couldn't list is an error from either describe tool" do
    error = tool_error('describe_query', { resource: 'properties', where: { nope: { eq: 1 } } })
    assert_match(/\AUnknown filter key 'nope' for properties\. Call describe_query/, error)
    assert tool_error('describe_attributes', { resource: 'properties', where: [{ size: { eq: 1 } }, { size: { eq: 2 } }] })
      .include?('must alternate')
  end

  test "the describe tools aren't listed without a resource or with the tools switched off" do
    StandardMCP::Registry.stubs(:controllers).returns([PhotosController])
    assert_empty list_tools

    StandardMCP::Registry.stubs(:controllers).returns([AccountsController])
    assert_equal DESCRIBES.sort, list_tools.map { |t| t[:name] }.grep(/\Adescribe/).sort

    StandardMCP.config.describe_tools = false
    assert_empty list_tools.map { |t| t[:name] }.grep(/\Adescribe/)
  end

  test "only builds a describe tool when asked for it" do
    request = request_for

    assert_equal %w[describe_query], StandardMCP::Tools.for(request, only: 'describe_query').map(&:name_value)
    assert_equal %w[describe_attributes], StandardMCP::Tools.for(request, only: 'describe_attributes').map(&:name_value)
    assert_empty StandardMCP::Tools.for(request, only: 'describe')
    assert_equal %w[list_accounts], StandardMCP::Tools.for(request, only: 'list_accounts').map(&:name_value)
    assert_empty StandardMCP::Tools.for(request, only: 'nothing')
  end

  test "the shallow descriptions point at the describe tools, with the resource name" do
    assert_includes tool('list_accounts')[:inputSchema].dig(:properties, :where, :description),
      'describe_query {"resource": "accounts"}'
    assert_includes tool('list_properties')[:inputSchema].dig(:properties, :order, :description),
      'Orderable keys: describe_query {"resource": "properties"}.'
    assert_includes tool('list_properties')[:inputSchema].dig(:properties, :include, :description),
      'Includable associations: describe_query {"resource": "properties"}.'
    assert_includes tool('calculate_properties', WRITES)[:inputSchema].dig(:properties, :where, :description),
      'describe_query {"resource": "properties"}'
    assert_includes tool('calculate_properties', WRITES)[:inputSchema].dig(:properties, :select, :description),
      'Attribute names: describe_attributes {"resource": "properties"}.'
    assert_includes tool('list_admin_accounts', 'X-MCP-Admin' => 'true')[:inputSchema].dig(:properties, :where, :description),
      'describe_query {"resource": "admin_accounts"}'
    assert_includes tool('create_property', WRITES)[:description],
      'Writable and required attributes: describe_attributes {"resource": "properties"}.'
    assert_includes tool('update_property', WRITES)[:inputSchema].dig(:properties, :property, :description),
      'Writable and required attributes: describe_attributes {"resource": "properties"}.'
  end

  test "without describe nothing points at it" do
    StandardMCP.config.describe_tools = false

    refute_includes JSON.generate(list_tools(WRITES)), 'describe'
  end

  test "a deep where schema spells the columns out and has no pointer" do
    StandardMCP.config.input_schema_depth = 'deep'

    refute_includes JSON.generate(tool('list_accounts')[:inputSchema]), 'describe'
  end

  # Measured with the two controllers below (7,747 characters in all); the
  # limits leave about 10% room.
  test "the shallow tools/list stays small" do
    StandardMCP.reset_config!
    StandardMCP::Registry.stubs(:controllers).returns([AccountsController, PropertiesController])
    tools = list_tools
    sizes = tools.to_h { |t| [t[:name], JSON.generate(t).size] }

    assert_equal 7, tools.size
    assert_operator JSON.generate(tool('list_accounts')[:inputSchema]).size, :<=, 1_400
    assert_operator sizes['list_accounts'], :<=, 1_750
    assert_operator sizes['list_properties'], :<=, 1_750
    assert_operator sizes['calculate_accounts'], :<=, 1_400
    assert_operator sizes['describe_query'], :<=, 950
    assert_operator sizes['describe_attributes'], :<=, 1_050
    assert_operator JSON.generate(tools).size, :<=, 8_500
    # The width of a model doesn't change the size of its tools.
    assert_in_delta sizes['list_accounts'], sizes['list_properties'], 50
  end

end
