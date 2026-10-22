require 'standard_mcp/test_helper'

# A namespaced controller (resource name console_accounts) hidden unless the
# caller sends X-MCP-Console.
module Console
  class Account < ::Account
    self.table_name = 'accounts'
  end

  class AccountsController < ::ApplicationController
    allow_mcp only: [:index, :show], if: :console?

    private

    def console?
      request.headers['X-MCP-Console'] == 'true'
    end
  end
end

# The photo ACL hides internal_path. The resource name is gallery.
class GalleryController < ApplicationController
  allow_mcp only: [:index, :show]

  def self.model
    Photo
  end
end

# A controller whose resource name is `schema`, which is also the first segment
# of the schema template.
class SchemaController < ApplicationController
  allow_mcp only: [:show]

  def self.model
    Account
  end
end

class ResourcesTest < ActiveSupport::TestCase

  setup do
    StandardMCP::Registry.stubs(:controllers).returns(
      [AccountsController, ContactsController, Console::AccountsController, GalleryController, PropertiesController]
    )
  end

  WRITES = { 'X-MCP-Writes' => 'true' }.freeze

  def request_for(headers = {})
    headers = headers.transform_keys { |k| "HTTP_#{k.upcase.tr('-', '_')}" }
    ActionDispatch::Request.new(Rack::MockRequest.env_for('/mcp', headers))
  end

  def bearer(account_id)
    { 'Authorization' => "Bearer #{account_id}" }
  end

  def templates(headers = {})
    StandardMCP::Resources.for(request_for(headers))
  end

  def uri_templates(headers = {})
    templates(headers).map(&:uri_template)
  end

  # The JSON-RPC response of reading +uri+ from a server built the way the
  # endpoint builds it.
  def rpc_read(uri, headers = {})
    server = MCP::Server.new(
      name: 'standardmcp-test',
      resource_templates: StandardMCP::Resources.for(request_for(headers), only_uri: uri)
    )
    message = { jsonrpc: '2.0', id: 1, method: 'resources/read', params: { uri: uri } }
    JSON.parse(JSON.generate(server.handle(message)), symbolize_names: true)
  end

  # The one content a successful read returns, its text parsed.
  def read(uri, headers = {})
    response = rpc_read(uri, headers)
    flunk "JSON-RPC error: #{response[:error]}" if response[:error]

    contents = response[:result][:contents]
    assert_equal 1, contents.size
    assert_equal uri, contents.first[:uri]
    assert_equal 'application/json', contents.first[:mimeType]
    JSON.parse(contents.first[:text])
  end

  def document(resource, headers = {})
    read("standardmcp://schema/#{resource}", headers)
  end

  def attribute(doc, name)
    doc['properties'][name] or flunk "no attribute #{name}"
  end

  def key(doc, name)
    doc['where']['keys'].find { |k| k['name'] == name } or flunk "no where key #{name}"
  end

  def assert_not_found(uri, headers = {})
    error = rpc_read(uri, headers)[:error]

    assert_equal(-32602, error[:code], uri)
    assert_equal "Resource not found: #{uri}", error[:message]
    assert_equal({ uri: uri }, error[:data])
  end

  # No false, nil or empty value anywhere: those keys are left out.
  def assert_compact(value, path = 'document')
    case value
    when Hash then value.each { |key, v| assert_compact(v, "#{path}.#{key}") }
    when Array
      refute_empty value, "#{path} is empty"
      value.each_with_index { |v, index| assert_compact(v, "#{path}[#{index}]") }
    else
      refute_includes [false, nil, ''], value, "#{path} is #{value.inspect}"
    end
  end

  # --- templates

  test "the schema template and a records template per show-able controller are listed" do
    assert_equal %w[
      standardmcp://schema/{resource}
      standardmcp://accounts/{id}
      standardmcp://gallery/{id}
      standardmcp://properties/{id}
    ].sort, uri_templates.sort
  end

  test "a controller the caller can't use has no template" do
    refute_includes uri_templates, 'standardmcp://console_accounts/{id}'
    assert_includes uri_templates('X-MCP-Console' => 'true'), 'standardmcp://console_accounts/{id}'
  end

  test "records need show: a write-only controller has the schema but no records template" do
    assert_includes uri_templates(WRITES), 'standardmcp://schema/{resource}'
    refute_includes uri_templates(WRITES), 'standardmcp://contacts/{id}'
    refute_includes uri_templates, 'standardmcp://contacts/{id}'
  end

  test "templates describe themselves" do
    schema = templates.find { |t| t.uri_template.include?('schema') }.to_h
    record = templates.find { |t| t.uri_template == 'standardmcp://properties/{id}' }.to_h

    assert_equal 'schema', schema[:name]
    assert_equal 'application/json', schema[:mimeType]
    assert_includes schema[:description], 'Resources: accounts, gallery, properties.'

    assert_equal 'property', record[:name]
    assert_equal 'Property', record[:title]
    assert_equal 'application/json', record[:mimeType]
    assert_equal 'A real estate asset owned by an account. One property by id, as JSON.', record[:description]
  end

  test "a namespaced controller's template is named for its whole path" do
    template = templates('X-MCP-Console' => 'true').find { |t| t.uri_template == 'standardmcp://console_accounts/{id}' }

    assert_equal 'console_account', template.to_h[:name]
    assert_equal 'Console account', template.to_h[:title]
  end

  test "the schema template lists only the resources of the caller" do
    description = templates.find { |t| t.uri_template.include?('schema') }.to_h[:description]
    assert_includes description, 'Resources: accounts, gallery, properties.'

    description = templates(WRITES.merge('X-MCP-Console' => 'true')).find { |t| t.uri_template.include?('schema') }.to_h[:description]
    assert_includes description, 'Resources: accounts, contacts, console_accounts, gallery, properties.'
  end

  test "listing renders no schema" do
    StandardMCP::Schema::QueryDocument.expects(:for).never
    StandardMCP::Dispatcher.any_instance.expects(:call).never

    templates(WRITES)
  end

  test "reading builds only the template its URI matches, then the one that refuses the rest" do
    built = StandardMCP::Resources.for(request_for, only_uri: 'standardmcp://accounts/1')

    assert_equal ['standardmcp://accounts/{id}', nil], built.map(&:uri_template)
    assert_equal ['standardmcp://schema/{resource}', nil],
      StandardMCP::Resources.for(request_for, only_uri: 'standardmcp://schema/accounts').map(&:uri_template)
    assert_equal [nil], StandardMCP::Resources.for(request_for, only_uri: 'other://accounts/1').map(&:uri_template)
    assert_equal [nil], StandardMCP::Resources.for(request_for, only_uri: 'standardmcp://accounts').map(&:uri_template)
  end

  test "reading a URI of a hidden controller builds no template for it" do
    assert_equal [nil], StandardMCP::Resources.for(request_for, only_uri: 'standardmcp://console_accounts/1').map(&:uri_template)
  end

  # --- config

  test "config.resources picks the templates" do
    StandardMCP.config.resources = [:schema]
    assert_equal ['standardmcp://schema/{resource}'], uri_templates

    StandardMCP.config.resources = ['records']
    assert_equal %w[standardmcp://accounts/{id} standardmcp://gallery/{id} standardmcp://properties/{id}], uri_templates.sort

    StandardMCP.config.resources = []
    assert_empty templates
  end

  test "a disabled resource can't be read either" do
    StandardMCP.config.resources = [:records]
    assert_not_found 'standardmcp://schema/accounts'

    StandardMCP.config.resources = [:schema]
    account = create(:account)
    assert_not_found "standardmcp://accounts/#{account.id}"

    StandardMCP.config.resources = []
    assert_not_found 'standardmcp://schema/accounts'
  end

  test "config.resource_scheme is the scheme of every URI" do
    StandardMCP.config.resource_scheme = 'my-app'
    account = create(:account)

    assert_equal %w[my-app://accounts/{id} my-app://gallery/{id} my-app://properties/{id} my-app://schema/{resource}], uri_templates.sort
    assert_equal 'accounts', read('my-app://schema/accounts')['query']['resource']
    assert_equal account.name, read("my-app://accounts/#{account.id}")['name']
    assert_not_found "standardmcp://accounts/#{account.id}"
  end

  # --- schema document

  test "the schema resource is the query and attributes documents, for no where" do
    doc = document('properties')

    assert_equal %w[attributes query], doc.keys.sort
    assert_equal 'properties', doc['query']['resource']
    assert_equal 'Property', doc['attributes']['title']
    assert_equal 'A real estate asset owned by an account.', doc['query']['description']
    assert_equal 'size', key(doc['query'], 'size')['name']
    assert_equal %w[integer null], attribute(doc['attributes'], 'size')['type']
  end

  test "the documents are built for the caller" do
    assert_equal 'Property', document('properties', WRITES)['attributes']['title']
    assert_equal 'Contact', document('contacts', WRITES)['attributes']['title']
    # A write-only caller has no where or order to describe.
    refute document('contacts', WRITES)['query'].key?('where')
    refute document('contacts', WRITES)['query'].key?('order')
  end

  test "an association links to the resource that serves it, and only that" do
    assert_equal 'gallery', document('properties')['query']['include'].find { |a| a['name'] == 'photos' }['resource']
    assert_equal 'properties', document('gallery')['query']['include'].find { |a| a['name'] == 'property' }['resource']

    StandardMCP::Registry.stubs(:controllers).returns([GalleryController])
    refute document('gallery')['query']['include'].first.key?('resource')
  end

  test "hidden columns are absent from the query document" do
    refute_includes JSON.generate(document('gallery')['query']), 'internal_path'
  end


  test "an update-only caller can write the attributes an update takes" do
    controller = Class.new(ApplicationController) do
      allow_mcp only: [:update]
      def self.model = Property
      def self.name = 'PatchersController'
    end
    StandardMCP::Registry.stubs(:controllers).returns([controller])

    doc = document('patchers')
    refute attribute(doc['attributes'], 'size')['readOnly']
    refute doc['query'].key?('where')
  end

  test "keys without a value are left out of the query document" do
    %w[accounts properties gallery].each { |resource| assert_compact(document(resource, WRITES)['query']) }
  end

  test "the resource name is the same in the schema resource and the describe tools" do
    request = request_for(WRITES)
    entries = StandardMCP::Resources.entries(StandardMCP::Registry.allowed(request))

    assert_equal document('properties', WRITES)['query'], StandardMCP::Resources.document(request, entries, 'properties')
    assert_equal document('properties', WRITES)['attributes'], StandardMCP::Resources.attributes(request, entries, 'properties').structured_content
    assert_nil StandardMCP::Resources.document(request, entries, 'nothing')
    assert_nil StandardMCP::Resources.attributes(request, entries, 'nothing')
  end

  test "the query document asks the definitions once for a where" do
    request = request_for(WRITES)
    entries = StandardMCP::Resources.entries(StandardMCP::Registry.allowed(request))
    where = { 'size' => { 'gte' => 1 } }
    PropertiesController.any_instance.expects(:schemas_for).once.with(Property)
      .returns([{ name: 'size', type: 'integer' }])

    doc = StandardMCP::Resources.document(request, entries, 'properties', where: where)

    assert_equal 'size', key(doc, 'size')['name']
  end

  test "the attributes are what the json_schema action renders" do
    request = request_for(WRITES)
    entries = StandardMCP::Resources.entries(StandardMCP::Registry.allowed(request))
    rendered = StandardMCP::Dispatcher.new(request).call(PropertiesController, :json_schema)

    assert_equal 200, rendered.status
    assert_equal rendered.json, StandardMCP::Resources.attributes(request, entries, 'properties').structured_content
  end

  test "a where that doesn't hold up raises" do
    request = request_for(WRITES)
    entries = StandardMCP::Resources.entries(StandardMCP::Registry.allowed(request))

    assert_raises(StandardMCP::Schema::Where::Invalid) do
      StandardMCP::Resources.document(request, entries, 'properties', where: { 'nope' => { 'eq' => 1 } })
    end
  end

  # --- reading schemas

  test "a schema is not found for a controller the caller has no action on" do
    assert_not_found 'standardmcp://schema/contacts'
    assert_not_found 'standardmcp://schema/console_accounts'
    assert_not_found 'standardmcp://schema/nothing'
    assert_not_found 'standardmcp://schema/photos'

    assert document('contacts', WRITES)
    assert document('console_accounts', 'X-MCP-Console' => 'true')
  end

  # --- reading records

  test "a record is its show JSON" do
    account = create(:account)
    property = create(:property, account: account, name: 'Tower', size: 5000)

    json = read("standardmcp://properties/#{property.id}")

    assert_equal property.id, json['id']
    assert_equal 'Tower', json['name']
    assert_equal 5000, json['size']
    assert_equal account.id, json['account_id']
  end

  test "excludes are applied to a record" do
    photo = create(:photo, internal_path: '/srv/secret', caption: 'Lobby')

    json = read("standardmcp://gallery/#{photo.id}")

    assert_equal 'Lobby', json['caption']
    refute json.key?('internal_path')
    refute_includes rpc_read("standardmcp://gallery/#{photo.id}")[:result][:contents].first[:text], '/srv/secret'
  end

  test "mask_for decides which records a bearer can read" do
    mine = create(:account)
    other = create(:account)

    assert_equal mine.id, read("standardmcp://accounts/#{mine.id}", bearer(mine.id))['id']
    assert_not_found "standardmcp://accounts/#{other.id}", bearer(mine.id)
    assert_equal other.id, read("standardmcp://accounts/#{other.id}")['id']
  end

  test "a masked record, a missing one, a hidden controller and an unknown URI are the same error" do
    mine = create(:account)
    other = create(:account)
    masked = rpc_read("standardmcp://accounts/#{other.id}", bearer(mine.id))[:error]
    missing = rpc_read('standardmcp://accounts/0', bearer(mine.id))[:error]
    hidden = rpc_read('standardmcp://console_accounts/1', bearer(mine.id))[:error]
    unknown = rpc_read('standardmcp://nothing/1', bearer(mine.id))[:error]

    [masked, missing, hidden, unknown].each do |error|
      assert_equal(-32602, error[:code])
      assert_match(%r{\AResource not found: standardmcp://\w+/\w+\z}, error[:message])
    end
    assert_equal [masked.keys.sort], [missing, hidden, unknown].map { |error| error.keys.sort }.uniq
    # Nothing about the record, the mask or the SQL beyond the URI that was asked for.
    assert_equal({ uri: "standardmcp://accounts/#{other.id}" }, masked[:data])
    refute_match(/mask|WHERE|SELECT|id =/i, JSON.generate(masked))
  end

  test "other URIs are not found" do
    [
      'standardmcp://accounts', 'standardmcp://accounts/', 'standardmcp://accounts/1/2', 'standardmcp://',
      'standardmcp:/accounts/1', 'other://accounts/1', 'accounts/1', ''
    ].each { |uri| assert_not_found uri }
  end

  test "a write-only controller's records are not found" do
    contact = create(:contact)

    assert_not_found "standardmcp://contacts/#{contact.id}", WRITES
  end

  test "a record is dispatched through show, so allow_mcp is checked again" do
    account = create(:account)
    StandardMCP::Dispatcher.any_instance.stubs(:allowed?).returns(false)

    assert_not_found "standardmcp://accounts/#{account.id}"
  end

  test "a client error other than not found carries its message" do
    result = StandardMCP::Dispatcher::Result.new(status: 400, headers: {}, body: JSON.generate(error: 'Parameter missing: id'))
    StandardMCP::Dispatcher.any_instance.stubs(:call).returns(result)

    error = rpc_read('standardmcp://accounts/1')[:error]
    assert_equal(-32602, error[:code])
    assert_equal 'Parameter missing: id', error[:message]
  end

  test "a forbidden record is not found" do
    result = StandardMCP::Dispatcher::Result.new(status: 403, headers: {}, body: JSON.generate(error: 'nope'))
    StandardMCP::Dispatcher.any_instance.stubs(:call).returns(result)

    assert_not_found 'standardmcp://accounts/1'
  end

  test "a server error is an internal error without its details" do
    result = StandardMCP::Dispatcher::Result.new(status: 500, headers: {}, body: 'database exploded: password=hunter2')
    StandardMCP::Dispatcher.any_instance.stubs(:call).returns(result)

    error = rpc_read('standardmcp://accounts/1')[:error]
    assert_equal(-32603, error[:code])
    refute_includes JSON.generate(error), 'hunter2'
  end

  # --- collisions

  test "a controller named schema collides with the schema template" do
    StandardMCP::Registry.stubs(:controllers).returns([AccountsController, SchemaController])

    error = assert_raises(StandardMCP::Error) { templates }
    assert_includes error.message, 'SchemaController'
    assert_includes error.message, 'standardmcp://schema/{resource}'
    assert_raises(StandardMCP::Error) { StandardMCP::Resources.for(request_for, only_uri: 'standardmcp://accounts/1') }
  end

  test "the collision goes away when only one of the resources is served" do
    StandardMCP::Registry.stubs(:controllers).returns([SchemaController])

    StandardMCP.config.resources = [:schema]
    assert_equal ['standardmcp://schema/{resource}'], uri_templates

    StandardMCP.config.resources = [:records]
    assert_equal ['standardmcp://schema/{id}'], uri_templates
  end

  test "a schema controller without show doesn't collide" do
    controller = Class.new(ApplicationController) do
      allow_mcp only: [:index]
      def self.model = Account
      def self.name = 'SchemaController'
    end
    StandardMCP::Registry.stubs(:controllers).returns([controller])

    assert_equal ['standardmcp://schema/{resource}'], uri_templates
  end

  test "two controllers can't share a resource name" do
    admin = Class.new(ApplicationController) do
      allow_mcp only: [:show]
      def self.model = Account
      def self.name = 'Admin::AccountsController'
      def self.controller_path = 'admin/accounts'
    end
    flat = Class.new(ApplicationController) do
      allow_mcp only: [:show]
      def self.model = Account
      def self.name = 'AdminAccountsController'
      def self.controller_path = 'admin_accounts'
    end
    StandardMCP::Registry.stubs(:controllers).returns([admin, flat])

    error = assert_raises(StandardMCP::Error) { templates }
    assert_includes error.message, 'Duplicate MCP resource names: admin_accounts'
  end

end
