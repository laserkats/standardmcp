require 'standard_mcp/test_helper'

# A conditional controller, as in tools_test but under its own name.
module Staff
  class Account < ::Account
    self.table_name = 'accounts'
  end

  class AccountsController < ::ApplicationController
    allow_mcp only: [:index, :show], if: :staff?

    private

    def staff?
      request.headers['X-MCP-Staff'] == 'true'
    end
  end
end

class EndpointTest < ActionDispatch::IntegrationTest

  setup do
    StandardMCP::Registry.stubs(:controllers).returns(
      [Staff::AccountsController, AccountsController, ContactsController, PropertiesController]
    )
    StandardMCP.config.server_name = 'endpoint-test'
    StandardMCP.config.server_version = '9.9.9'
  end

  # Some tests swap the default controller's parent.
  teardown do
    StandardMCP.reset_config!
    StandardMCP.define_server_controller!
  end

  JSON_HEADERS = {
    'Content-Type' => 'application/json',
    'Accept' => 'application/json, text/event-stream',
    'MCP-Protocol-Version' => '2025-06-18'
  }.freeze

  def rpc(method, params = nil, headers: {}, path: '/mcp')
    message = { jsonrpc: '2.0', id: 1, method: method }
    message[:params] = params if params
    post_raw(JSON.generate(message), headers: headers, path: path)
  end

  def post_raw(body, headers: {}, path: '/mcp')
    post path, params: body, headers: JSON_HEADERS.merge(headers)
  end

  def result
    JSON.parse(response.body)['result']
  end

  def error
    JSON.parse(response.body)['error']
  end

  def call_tool(name, arguments = {}, headers: {}, path: '/mcp')
    rpc('tools/call', { name: name, arguments: arguments }, headers: headers, path: path)
    assert_response :success
    result
  end

  def tool_names(headers: {}, path: '/mcp')
    rpc('tools/list', headers: headers, path: path)
    result['tools'].map { |t| t['name'] }
  end

  def bearer(account_id)
    { 'Authorization' => "Bearer #{account_id}" }
  end

  def request_for_mcp
    ActionDispatch::Request.new(Rack::MockRequest.env_for('/mcp'))
  end

  # --- initialize

  test "initialize reports the server and the protocol" do
    rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '1' } })

    assert_response :success
    assert_equal 'application/json', response.media_type
    assert_equal 'endpoint-test', result['serverInfo']['name']
    assert_equal '9.9.9', result['serverInfo']['version']
    assert_equal '2025-06-18', result['protocolVersion']
    assert result['capabilities'].key?('tools')
  end

  test "initialize sends the configured instructions" do
    StandardMCP.config.instructions = 'Use these tools carefully.'
    rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '1' } })

    assert_equal 'Use these tools carefully.', result['instructions']
  end

  test "callable instructions get the request" do
    StandardMCP.config.instructions = ->(request) { "Hello #{request.headers['X-Who']}" }
    rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '1' } },
      headers: { 'X-Who' => 'Ben' })

    assert_equal 'Hello Ben', result['instructions']
  end

  test "instructions default to the generated ones" do
    ActiveRecord::Base.connection.stubs(:database_comment).returns('Property management data.')
    rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '1' } })

    instructions = result['instructions']
    assert instructions.start_with?("Property management data.\n\nResources:\n")
    assert_includes instructions, 'accounts: A customer organization that owns properties. Tools: list_accounts, get_account, calculate_accounts.'
    refute_includes instructions, 'staff'
  end

  test "the generated instructions follow the request" do
    rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '1' } },
      headers: { 'X-MCP-Staff' => 'true', 'X-MCP-Writes' => 'true' })

    assert_includes result['instructions'], 'staff/accounts: '
    assert_includes result['instructions'], 'create_contact'
  end

  test "there are no instructions when they are switched off" do
    StandardMCP.config.instructions = false
    rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '1' } })

    assert_nil result['instructions']
  end

  test "server/discover sends the instructions too" do
    StandardMCP.config.instructions = 'Discover me.'
    rpc('server/discover')

    assert_equal 'Discover me.', result['instructions']
  end

  test "the generated instructions are only worked out for the methods that send them" do
    StandardMCP::Instructions.expects(:generate).never
    StandardMCP::Instructions.expects(:for).never

    tool_names
    call_tool('list_accounts')
  end

  # --- tools/list

  test "tools/list lists the allowed tools" do
    assert_equal %w[calculate_accounts describe_attributes describe_query get_account get_property list_accounts list_properties],
      tool_names.sort
  end

  test "tools/list hides tools per request" do
    refute(tool_names.any? { |n| n.include?('staff') })
    assert_equal %w[get_staff_account list_staff_accounts],
      tool_names(headers: { 'X-MCP-Staff' => 'true' }).grep(/staff/).sort
  end

  # --- resources

  INITIALIZE_PARAMS = { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '1' } }.freeze
  WRITES = { 'X-MCP-Writes' => 'true' }.freeze

  def template_uris(headers: {}, path: '/mcp')
    rpc('resources/templates/list', headers: headers, path: path)
    assert_response :success
    result['resourceTemplates'].map { |t| t['uriTemplate'] }
  end

  # The one content of resources/read, its text parsed.
  def read_resource(uri, headers: {}, path: '/mcp')
    rpc('resources/read', { uri: uri }, headers: headers, path: path)
    assert_response :success
    assert_nil error, "JSON-RPC error: #{error}"
    contents = result['contents']
    assert_equal 1, contents.size
    assert_equal uri, contents.first['uri']
    assert_equal 'application/json', contents.first['mimeType']
    JSON.parse(contents.first['text'])
  end

  def assert_resource_not_found(uri, headers: {})
    rpc('resources/read', { uri: uri }, headers: headers)

    assert_equal(-32602, error['code'])
    assert_equal "Resource not found: #{uri}", error['message']
    assert_equal({ 'uri' => uri }, error['data'])
  end

  test "initialize advertises resources" do
    rpc('initialize', INITIALIZE_PARAMS)

    assert result['capabilities'].key?('resources')
  end

  test "initialize doesn't advertise resources when none are configured" do
    StandardMCP.config.resources = []
    rpc('initialize', INITIALIZE_PARAMS)

    assert result['capabilities'].key?('tools')
    refute result['capabilities'].key?('resources')
  end

  test "resources/templates/list lists the templates of the caller" do
    uris = template_uris

    assert_equal %w[standardmcp://accounts/{id} standardmcp://properties/{id} standardmcp://schema/{resource}], uris.sort
    assert_includes template_uris(headers: { 'X-MCP-Staff' => 'true' }), 'standardmcp://staff_accounts/{id}'
    refute_includes uris, 'standardmcp://staff_accounts/{id}'
  end

  test "resources/templates/list says what each template is" do
    rpc('resources/templates/list')
    record = result['resourceTemplates'].find { |t| t['uriTemplate'] == 'standardmcp://accounts/{id}' }

    assert_equal 'account', record['name']
    assert_equal 'Account', record['title']
    assert_equal 'application/json', record['mimeType']
    assert_includes record['description'], 'A customer organization that owns properties.'
  end

  test "resources/templates/list is empty when the templates are switched off" do
    StandardMCP.config.resources = []
    rpc('resources/templates/list')

    # The capability isn't advertised, so the gem refuses the method.
    assert_nil result
    assert error
  end

  test "resources/list has no concrete resources" do
    rpc('resources/list')

    assert_equal [], result['resources']
  end

  test "resources/read returns the schema document of a controller" do
    doc = read_resource('standardmcp://schema/properties')

    assert_equal 'properties', doc['query']['resource']
    assert_equal 'Property', doc['attributes']['title']
    assert_equal 'Rentable area in square feet.', doc['attributes']['properties']['size']['description']
    assert_equal true, doc['attributes']['properties']['id']['readOnly']
  end

  test "the schema resource is the two documents the describe tools return" do
    query = call_tool('describe_query', { resource: 'accounts' })['structuredContent']
    attributes = call_tool('describe_attributes', { resource: 'accounts' })['structuredContent']

    assert_equal({ 'query' => query, 'attributes' => attributes }, read_resource('standardmcp://schema/accounts'))
  end

  test "describe_query takes a where over the endpoint" do
    result = call_tool('describe_query', { resource: 'properties', where: { size: { gte: 1 } } })

    assert_equal 'properties', result['structuredContent']['resource']

    error = call_tool('describe_query', { resource: 'properties', where: { nope: { eq: 1 } } })
    assert error['isError']
    assert_match(/Unknown filter key 'nope'/, error['content'].first['text'])
  end

  test "resources/read returns a record with mask_for applied through the bearer" do
    mine = create(:account, name: 'Mine')
    other = create(:account)

    assert_equal 'Mine', read_resource("standardmcp://accounts/#{mine.id}", headers: bearer(mine.id))['name']
    assert_resource_not_found "standardmcp://accounts/#{other.id}", headers: bearer(mine.id)
    assert_equal other.id, read_resource("standardmcp://accounts/#{other.id}")['id']
  end

  test "resources/read is not found for anything the caller can't see, with one error" do
    account = create(:account)

    assert_resource_not_found 'standardmcp://schema/contacts'
    assert_resource_not_found 'standardmcp://schema/staff_accounts'
    assert_resource_not_found "standardmcp://staff_accounts/#{account.id}"
    assert_resource_not_found 'standardmcp://accounts/0'
    assert_resource_not_found 'standardmcp://nothing/1'
    assert_resource_not_found 'file:///etc/passwd'

    # Visible once the caller is allowed.
    assert read_resource('standardmcp://schema/contacts', headers: WRITES)
    assert_equal account.id, read_resource("standardmcp://staff_accounts/#{account.id}", headers: { 'X-MCP-Staff' => 'true' })['id']
  end

  test "resources/read without a uri is not found" do
    rpc('resources/read', {})

    assert_equal(-32602, error['code'])
  end

  test "resources/read builds only the template its URI matches" do
    ready = StandardMCP::Resources.for(request_for_mcp, only_uri: 'standardmcp://accounts/1').first
    StandardMCP::Resources.expects(:schema_template).never
    StandardMCP::Resources.expects(:record_template).once.returns(ready)

    rpc('resources/read', { uri: 'standardmcp://accounts/1' })

    assert_response :success
  end

  test "resources/read of a schema builds no record templates" do
    StandardMCP::Resources.expects(:record_template).never

    assert_equal 'accounts', read_resource('standardmcp://schema/accounts')['query']['resource']
  end

  test "resources/templates/list builds every template and renders no schema" do
    StandardMCP::Schema::QueryDocument.expects(:for).never
    StandardMCP::Dispatcher.any_instance.expects(:call).never

    assert_equal 3, template_uris.size
  end

  test "other requests build no templates" do
    StandardMCP::Resources.expects(:for).never

    rpc('initialize', INITIALIZE_PARAMS)
    rpc('tools/list')
    rpc('tools/call', { name: 'list_accounts', arguments: {} })
    rpc('server/discover')
    assert_response :success
  end

  test "an app's own controller serves the resources too" do
    account = create(:account)

    assert_includes template_uris(path: '/custom_mcp'), 'standardmcp://schema/{resource}'
    rpc('resources/read', { uri: "standardmcp://accounts/#{account.id}" }, path: '/custom_mcp')
    assert_equal account.id, JSON.parse(result['contents'].first['text'])['id']
  end

  test "resources/read stays in the configured scheme" do
    StandardMCP.config.resource_scheme = 'app'
    account = create(:account)

    assert_includes template_uris, 'app://schema/{resource}'
    assert_equal account.id, read_resource("app://accounts/#{account.id}")['id']
    assert_resource_not_found "standardmcp://accounts/#{account.id}"
  end

  # --- tools/call

  test "list returns records, with mask_for applied through the bearer" do
    mine = create(:account)
    create_list(:account, 2)

    all = call_tool('list_accounts')
    assert_equal 3, all['structuredContent']['records'].size

    masked = call_tool('list_accounts', headers: bearer(mine.id))
    refute masked['isError']
    assert_equal [mine.id], masked['structuredContent']['records'].map { |r| r['id'] }
    assert_equal 1, masked['structuredContent']['total']
  end

  test "get returns a record and a masked one is not found" do
    mine = create(:account)
    other = create(:account)

    assert_equal mine.id, call_tool('get_account', { id: mine.id }, headers: bearer(mine.id))['structuredContent']['record']['id']

    missing = call_tool('get_account', { id: other.id }, headers: bearer(mine.id))
    assert missing['isError']
    assert_equal 'Account not found', missing['structuredContent']['error']
  end

  test "calculate honors mask_for" do
    mine = create(:account)
    create_list(:account, 2)

    assert_equal [3], call_tool('calculate_accounts', { select: [{ count: '*' }] })['structuredContent']['result']
    assert_equal [1], call_tool('calculate_accounts', { select: [{ count: '*' }] }, headers: bearer(mine.id))['structuredContent']['result']
  end

  test "tools/list shows the write tools only with the writes header" do
    assert_equal %w[create_contact create_property delete_contact update_contact update_property],
      tool_names(headers: { 'X-MCP-Writes' => 'true' }).grep(/create|update|delete/).sort
    assert_empty tool_names.grep(/create|update|delete/)
  end

  test "create saves a record, through a bearer that passes CSRF" do
    account = create(:account)

    created = call_tool('create_contact', { contact: { name: 'Pat', account_id: account.id } },
      headers: bearer(account.id).merge('X-MCP-Writes' => 'true'))

    refute created['isError']
    assert_equal 'Pat', created['structuredContent']['record']['name']
    assert_equal 'member', created['structuredContent']['record']['role']
    assert_equal account.id, Contact.find(created['structuredContent']['record']['id']).account_id
  end

  test "create with a validation problem is a tool error over HTTP" do
    account = create(:account)

    result = call_tool('create_property', { property: { name: '' } }, headers: bearer(account.id).merge('X-MCP-Writes' => 'true'))

    assert result['isError']
    assert_equal "name can't be blank", result['structuredContent']['error']
    assert_equal 0, Property.count
  end

  test "delete removes a record and reports the rows, and a masked one is not found" do
    mine = create(:account)
    contact = create(:contact, account: mine)
    other = create(:contact)
    headers = bearer(mine.id).merge('X-MCP-Writes' => 'true')

    missing = call_tool('delete_contact', { id: other.id }, headers: headers)
    assert missing['isError']
    assert_equal 'Contact not found', missing['structuredContent']['error']
    assert Contact.exists?(other.id)

    deleted = call_tool('delete_contact', { id: contact.id }, headers: headers)
    refute deleted['isError']
    assert_equal({ 'success' => true, 'affected_rows' => 1 }, deleted['structuredContent'])
    refute Contact.exists?(contact.id)
  end

  test "a write without a bearer is refused by CSRF protection and reported as a tool error" do
    result = call_tool('create_contact', { contact: { name: 'Pat' } }, headers: { 'X-MCP-Writes' => 'true' })

    assert result['isError']
    assert_equal 0, Contact.count
  end

  test "a hidden write tool cannot be called" do
    rpc('tools/call', { name: 'delete_contact', arguments: { id: 1 } }, headers: bearer(1))

    assert_equal(-32602, error['code'])
  end

  test "invalid arguments are a tool error" do
    tool_result = call_tool('list_accounts', { limit: 0 })

    assert tool_result['isError']
    assert_match(/Invalid arguments/, tool_result['content'].first['text'])
  end

  test "a bad filter is a tool error" do
    tool_result = call_tool('list_properties', { where: { foo: { eq: 1 } } })

    assert tool_result['isError']
    assert_match(/Unknown filter key 'foo'/, tool_result['content'].first['text'])
  end

  test "a hidden tool cannot be called" do
    call = { name: 'list_staff_accounts', arguments: {} }

    rpc('tools/call', call)
    assert_equal(-32602, error['code'])
    assert_match(/Tool not found/, error.to_s)

    rpc('tools/call', call, headers: { 'X-MCP-Staff' => 'true' })
    assert_nil error
  end

  test "an unknown tool is an error" do
    rpc('tools/call', { name: 'drop_everything', arguments: {} })

    assert_equal(-32602, error['code'])
    assert_match(/Tool not found/, error.to_s)
  end

  test "tools/call builds only the requested tool" do
    controller = StandardMCP::Registry.controller_for(AccountsController, request_for_mcp)
    schema = StandardMCP::Schema::Input.for(controller, :index)
    StandardMCP::Schema::Input.expects(:for).once.with { |_, action| action == :index }.returns(schema)

    assert_equal [], call_tool('list_accounts')['structuredContent']['records']
  end

  test "tools/call with a malformed name builds every tool and is refused by the server" do
    rpc('tools/call', { name: 5, arguments: {} })

    assert error
    assert_response :success
  end

  test "tools/list and other methods build every tool" do
    StandardMCP::Tools.expects(:for).with { |_, options| options[:only].nil? }.once.returns([])

    rpc('tools/list')
  end

  test "results are checked against the output schema when it is declared" do
    StandardMCP.config.output_schema = true
    StandardMCP::Response.stubs(:from).returns(
      MCP::Tool::Response.new([{ type: 'text', text: '{}' }], structured_content: { records: 'nope' })
    )

    rpc('tools/call', { name: 'list_accounts', arguments: {} })
    assert_equal(-32603, error['code'])

    StandardMCP.config.validate_results = false
    rpc('tools/call', { name: 'list_accounts', arguments: {} })
    assert_nil error
  end

  test "results are not checked without an output schema" do
    StandardMCP::Response.stubs(:from).returns(
      MCP::Tool::Response.new([{ type: 'text', text: '{}' }], structured_content: { records: 'nope' })
    )

    rpc('tools/call', { name: 'list_accounts', arguments: {} })
    assert_nil error
  end

  test "the exception reporter hears about server errors, which stay opaque to the client" do
    reported = []
    StandardMCP.config.exception_reporter = ->(exception, _context) { reported << exception }
    AccountsController.any_instance.stubs(:index).raises(RuntimeError, 'secret SELECT * FROM accounts')

    rpc('tools/call', { name: 'list_accounts', arguments: {} })

    assert_equal(-32603, error['code'])
    refute_match(/secret|SELECT/, response.body)
    assert_equal ['secret SELECT * FROM accounts'], reported.map(&:message)
  end

  # --- protocol

  test "a notification is accepted with no body" do
    post '/mcp', params: JSON.generate({ jsonrpc: '2.0', method: 'notifications/initialized' }), headers: JSON_HEADERS

    assert_response :accepted
    assert_empty response.body
  end

  test "a body that isn't JSON is a parse error" do
    post_raw '{nope'

    assert_response :bad_request
    assert_equal(-32700, error['code'])
  end

  test "an unsupported protocol version is refused" do
    rpc('tools/list', headers: { 'MCP-Protocol-Version' => '1999-01-01' })

    assert_response :bad_request
  end

  test "an Accept that excludes JSON is refused" do
    rpc('tools/list', headers: { 'Accept' => 'text/html' })

    assert_response :not_acceptable
  end

  test "GET is a method not allowed" do
    get '/mcp', headers: { 'Accept' => 'text/event-stream' }

    assert_response :method_not_allowed
    assert_equal(-32600, error['code'])
  end

  test "DELETE has nothing to end and succeeds" do
    delete '/mcp', headers: JSON_HEADERS

    assert_response :success
    assert_equal({ 'success' => true }, JSON.parse(response.body))
  end

  test "GET and DELETE build no tools" do
    StandardMCP::Tools.expects(:for).never

    get '/mcp', headers: { 'Accept' => 'text/event-stream' }
    delete '/mcp', headers: JSON_HEADERS
  end

  test "other verbs are not routed" do
    assert_raises(ActionController::RoutingError) { put '/mcp', headers: JSON_HEADERS }
  end

  # --- CSRF

  test "a cross-site form or text/plain POST is refused even with cookie auth and no CSRF token" do
    # What a <form> or a no-preflight fetch can send, with the victim's cookies.
    ActionController::Base.stubs(:allow_forgery_protection).returns(true)
    StandardMCP::Tools.expects(:for).never
    StandardMCP::Dispatcher.any_instance.expects(:call).never
    body = JSON.generate({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'list_accounts', arguments: {} } })

    ['text/plain', 'text/plain;charset=UTF-8', 'application/x-www-form-urlencoded'].each do |type|
      post_raw body, headers: { 'Content-Type' => type, 'Cookie' => 'session=whatever' }

      assert_response 415, type
      assert_equal(-32600, error['code'], type)
    end
  end

  test "forgery protection does not get in the way of a JSON POST" do
    ActionController::Base.stubs(:allow_forgery_protection).returns(true)

    rpc('tools/list')

    assert_response :success
  end

  # --- Origin

  test "requests without an Origin are accepted" do
    rpc('tools/list')

    assert_response :success
  end

  test "the endpoint's own origin is accepted" do
    rpc('tools/list', headers: { 'Origin' => 'http://www.example.com' })

    assert_response :success
  end

  test "another origin is refused, and nothing is built or dispatched" do
    StandardMCP::Tools.expects(:for).never

    ['https://evil.example', 'http://www.example.com:3000', 'https://www.example.com', 'null'].each do |origin|
      rpc('tools/list', headers: { 'Origin' => origin })

      assert_response :forbidden, origin
      assert_equal(-32600, error['code'], origin)
      assert_match(/Origin/, error['message'], origin)
    end
  end

  test "allowed_origins accepts exact strings and patterns" do
    StandardMCP.config.allowed_origins = ['https://claude.ai', %r{\Ahttps://[a-z]+\.example\.org\z}]

    rpc('tools/list', headers: { 'Origin' => 'https://Claude.ai' })
    assert_response :success

    rpc('tools/list', headers: { 'Origin' => 'https://app.example.org' })
    assert_response :success

    rpc('tools/list', headers: { 'Origin' => 'https://claude.ai.evil.example' })
    assert_response :forbidden

    rpc('tools/list', headers: { 'Origin' => 'https://evil.example.org.evil.example' })
    assert_response :forbidden
  end

  test "allowed_origins patterns must match the whole origin" do
    StandardMCP.config.allowed_origins = [/https:\/\/[a-z]+\.example\.org/i]

    rpc('tools/list', headers: { 'Origin' => 'https://App.example.org' })
    assert_response :success

    rpc('tools/list', headers: { 'Origin' => 'https://app.example.org.evil.example' })
    assert_response :forbidden

    rpc('tools/list', headers: { 'Origin' => 'http://evil.example/https://app.example.org' })
    assert_response :forbidden
  end

  test "a refused origin is answered before the parent authenticates" do
    StandardMCP.config.parent_controller = 'BearerRequiredController'
    StandardMCP.define_server_controller!

    rpc('tools/list', headers: { 'Origin' => 'https://evil.example' })

    assert_response :forbidden
  end

  # --- controllers and routes

  test "an app's own controller that includes Endpoint serves the same protocol" do
    mine = create(:account)
    create(:account)

    assert_equal %w[calculate_accounts describe_attributes describe_query get_account get_property list_accounts list_properties],
      tool_names(path: '/custom_mcp').sort
    assert_equal [mine.id],
      call_tool('list_accounts', headers: bearer(mine.id), path: '/custom_mcp')['structuredContent']['records'].map { |r| r['id'] }
  end

  test "the parent controller's callbacks run, and what they render passes through" do
    StandardMCP.config.parent_controller = 'BearerRequiredController'
    StandardMCP.define_server_controller!
    mine = create(:account)

    rpc('tools/list')
    assert_response :unauthorized
    assert_equal 'Bearer', response.headers['WWW-Authenticate']

    rpc('tools/list', headers: bearer(mine.id))
    assert_response :success

    assert_equal [mine.id],
      call_tool('list_accounts', headers: bearer(mine.id))['structuredContent']['records'].map { |r| r['id'] }
  end

  test "the default controller follows the configured parent and is defined again on demand" do
    original = StandardMCP::ServerController
    assert_equal ApplicationController, original.superclass
    assert_equal 'standard_mcp/server', original.controller_path
    assert_includes original.ancestors, StandardMCP::Endpoint
    assert_equal ['handle'], original.action_methods.to_a & %w[handle mcp_server mcp_tools verify_mcp_origin]

    StandardMCP.config.parent_controller = 'BearerRequiredController'
    StandardMCP.define_server_controller!

    refute_same original, StandardMCP::ServerController
    assert_equal BearerRequiredController, StandardMCP::ServerController.superclass
    assert_same StandardMCP::ServerController, StandardMcp::ServerController
  end

  test "a parent controller that doesn't exist leaves no default controller and says so" do
    StandardMCP.config.parent_controller = 'NoSuchController'
    Rails.logger.expects(:warn).with(regexp_matches(/NoSuchController/))

    StandardMCP.define_server_controller!

    refute StandardMCP.const_defined?(:ServerController, false)
  end

  test "the route helper routes the endpoint" do
    routes = Rails.application.routes

    %w[POST GET DELETE].each do |verb|
      assert_equal({ controller: 'standard_mcp/server', action: 'handle' },
        routes.recognize_path('/mcp', method: verb), verb)
      assert_equal({ controller: 'mcp', action: 'handle' },
        routes.recognize_path('/custom_mcp', method: verb), verb)
    end

    assert_raises(ActionController::RoutingError) { routes.recognize_path('/mcp', method: 'PUT') }
    assert_equal '/mcp', routes.url_helpers.standard_mcp_path
    assert_equal '/custom_mcp', routes.url_helpers.custom_mcp_path
  end

  test "the route helper takes a path, a controller and options" do
    set = ActionDispatch::Routing::RouteSet.new
    set.draw do
      standard_mcp
      standard_mcp '/other', to: 'mcp#handle', as: :other, via: :post
    end

    assert_equal({ controller: 'standard_mcp/server', action: 'handle' }, set.recognize_path('/mcp', method: 'POST'))
    assert_equal({ controller: 'mcp', action: 'handle' }, set.recognize_path('/other', method: 'POST'))
    assert_raises(ActionController::RoutingError) { set.recognize_path('/other', method: 'GET') }
  end

end
