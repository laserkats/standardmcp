require 'standard_mcp/test_helper'

# A namespaced controller: create_billing_account.
module Billing
  class Account < ::Account
    self.table_name = 'accounts'
  end

  class AccountsController < ::ApplicationController
    allow_mcp only: [:create, :update, :destroy]
  end
end

# A record's ACL that depends on the record: size can be set on a new
# property, or on an existing one that isn't an office.
class WritesLockedPropertiesController < ApplicationController
  allow_mcp only: [:create, :update]

  def self.model
    Property
  end

  def property_attributes(record = nil)
    record&.persisted? && record.kind == 'office' ? super() - [:size] : super()
  end
end

class WriteToolsTest < ActiveSupport::TestCase

  setup do
    StandardMCP::Registry.stubs(:controllers).returns(
      [AccountsController, ContactsController, PropertiesController, WritesLockedPropertiesController]
    )
    # Declared, and so validated against, in every test.
    StandardMCP.config.output_schema = true
  end

  def request_for(headers = {})
    headers = headers.transform_keys { |k| "HTTP_#{k.upcase.tr('-', '_')}" }
    ActionDispatch::Request.new(Rack::MockRequest.env_for('/mcp', headers))
  end

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
    JSON.parse(JSON.generate(server.handle(message)), symbolize_names: true)
  end

  def list_tools(headers = {})
    rpc(server_for(headers), 'tools/list')[:result][:tools]
  end

  def tool(name, headers = writes)
    list_tools(headers).find { |t| t[:name] == name } or flunk "no tool #{name}"
  end

  # Writes enabled, and a bearer so CSRF passes and mask_for resolves.
  def writes(account_id = 0)
    { 'X-MCP-Writes' => 'true', 'Authorization' => "Bearer #{account_id}" }
  end

  def call_tool(name, arguments = {}, headers = writes)
    response = rpc(server_for(headers), 'tools/call', { name: name, arguments: arguments })
    flunk "JSON-RPC error: #{response[:error]}" if response[:error]
    response[:result]
  end

  def structured(name, arguments = {}, headers = writes)
    result = call_tool(name, arguments, headers)
    refute result[:isError], "unexpected tool error: #{result[:structuredContent] || result[:content]}"
    result[:structuredContent]
  end

  def tool_error(name, arguments = {}, headers = writes)
    result = call_tool(name, arguments, headers)
    assert result[:isError], "expected a tool error, got #{result[:structuredContent]}"
    result.dig(:structuredContent, :error) || result[:content].first[:text]
  end

  # --- tools/list

  test "each write action is a tool named for the singular" do
    names = list_tools(writes).map { |t| t[:name] }

    %w[create_property update_property create_contact update_contact delete_contact].each do |name|
      assert_includes names, name
    end
    refute_includes names, 'delete_property'
    refute(names.any? { |n| n.match?(/destroy|photo/) })
    # Reads stay as they were.
    assert_includes names, 'list_properties'
    assert_includes names, 'get_property'
  end

  test "a namespaced controller names its tools from the whole path" do
    StandardMCP::Registry.stubs(:controllers).returns([Billing::AccountsController])
    tools = StandardMCP::Tools.for(request_for)

    assert_equal %w[create_billing_account delete_billing_account update_billing_account], tools.map(&:name_value).sort
    assert_equal ['Create billing account', 'Delete billing account', 'Update billing account'],
      tools.map { |t| t.title }.sort
  end

  test "titles" do
    assert_equal 'Create property', tool('create_property')[:title]
    assert_equal 'Update property', tool('update_property')[:title]
    assert_equal 'Delete contact', tool('delete_contact')[:title]
  end

  test "annotations say what a write does" do
    expected = {
      'create_property' => { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
      'create_contact' => { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
      'update_property' => { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
      'update_contact' => { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
      'delete_contact' => { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
      'list_properties' => { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
    }
    tools = list_tools(writes).to_h { |t| [t[:name], t[:annotations]] }

    expected.each { |name, annotations| assert_equal annotations, tools.fetch(name), name }
  end

  test "descriptions say what to send" do
    assert_includes tool('create_property')[:description], 'Required: name.'
    assert_includes tool('create_property')[:description], 'A real estate asset owned by an account.'
    assert_includes tool('update_property')[:description], 'Send only the attributes to change.'
    assert_includes tool('delete_contact')[:description], 'This is permanent.'
  end

  test "write tools are hidden without the writes header and cannot be called" do
    StandardMCP::Registry.stubs(:controllers).returns([ContactsController, PropertiesController])
    names = list_tools.map { |t| t[:name] }
    refute(names.any? { |n| n.match?(/create|update|delete/) })

    response = rpc(server_for, 'tools/call', { name: 'create_contact', arguments: { contact: { name: 'Pat' } } })
    assert_equal(-32602, response[:error][:code])
    assert_equal 0, Contact.count
  end

  test "a tool absent from a controller's rules is not built, whatever the header" do
    names = list_tools(writes).map { |t| t[:name] }

    refute_includes names, 'delete_property'
    refute_includes names, 'delete_writes_locked_property'
    assert_includes names, 'create_writes_locked_property'
  end

  test "schemas and output schemas come from the builders" do
    request = request_for('X-MCP-Writes' => 'true')
    controller = StandardMCP::Registry.controller_for(PropertiesController, request)
    create = tool('create_property')

    assert_equal %w[property include], create[:inputSchema][:properties].keys.map(&:to_s)
    assert_equal ['property'], create[:inputSchema][:required]
    assert_equal %w[id property include], tool('update_property')[:inputSchema][:properties].keys.map(&:to_s)
    assert_equal %w[id], tool('delete_contact')[:inputSchema][:properties].keys.map(&:to_s)
    assert_equal %w[record ignored_attributes], create[:outputSchema][:properties].keys.map(&:to_s)
    assert_equal %w[success affected_rows], tool('delete_contact')[:outputSchema][:properties].keys.map(&:to_s)
    assert_equal StandardMCP::Schema::Input.for(controller, :create).keys.map(&:to_sym) - [:'$defs'],
      create[:inputSchema].keys - %i[$schema $defs]
  end

  test "output schemas are only declared when configured" do
    StandardMCP.config.output_schema = false

    list_tools(writes).each { |t| refute t.key?(:outputSchema), t[:name] }
    assert structured('create_contact', { contact: { name: 'Pat' } })[:record]
  end

  # --- create

  test "create saves the record and returns it" do
    account = create(:account)

    content = structured('create_property', { property: { name: 'Tower', size: 1200, kind: 'office', account_id: account.id } })

    record = Property.find(content[:record][:id])
    assert_equal 'Tower', content[:record][:name]
    assert_equal 1200, record.size
    assert_equal 'office', content[:record][:kind]
    assert_equal account.id, record.account_id
    refute content.key?(:ignored_attributes)
  end

  test "create with include renders the associations" do
    account = create(:account, name: 'Acme')

    content = structured('create_property', { property: { name: 'Tower', account_id: account.id }, include: { account: true } })

    assert_equal 'Acme', content[:record][:account][:name]
  end

  test "create applies column defaults" do
    content = structured('create_contact', { contact: { name: 'Pat' } })

    assert_equal 'member', content[:record][:role]
    assert_equal 'member', Contact.find(content[:record][:id]).role
  end

  test "create without a required attribute is rejected before it runs" do
    StandardMCP::Dispatcher.any_instance.expects(:call).never

    assert_match(/Invalid arguments.*name/, tool_error('create_property', { property: { size: 1 } }))
    assert_match(/Missing required arguments: property/, tool_error('create_property', {}))
    assert_equal 0, Property.count
  end

  test "create with a bad value is rejected by the schema" do
    StandardMCP::Dispatcher.any_instance.expects(:call).never

    {
      { name: 'Tower', kind: 'castle' } => /kind/,
      { name: 'Tower', size: 'big' } => /size/,
      { name: nil } => /name/,
      { name: 'Tower', built_on: 5 } => /built_on/
    }.each do |attributes, expected|
      assert_match expected, tool_error('create_property', { property: attributes }), attributes.inspect
    end

    assert_match(/role/, tool_error('create_contact', { contact: { name: 'Pat', role: 'owner' } }))
    assert_match(/name/, tool_error('create_contact', { contact: { name: 'x' * 51 } }))
    assert_match(/email/, tool_error('create_contact', { contact: { name: 'Pat', email: 'nope' } }))
    assert_match(/age/, tool_error('create_contact', { contact: { name: 'Pat', age: -1 } }))
  end

  test "an attribute the ACL doesn't permit is rejected by the schema" do
    StandardMCP::Dispatcher.any_instance.expects(:call).never

    assert_match(/Invalid arguments/, tool_error('create_property', { property: { name: 'Tower', created_at: '2020-01-01T00:00:00Z' } }))
    assert_match(/Invalid arguments/, tool_error('create_property', { property: { name: 'Tower', id: 7 } }))
    assert_match(/Invalid arguments/, tool_error('create_contact', { contact: { name: 'Pat', secret: 1 } }))
  end

  test "a validation error StandardAPI finds is a tool error with the errors" do
    result = call_tool('create_property', { property: { name: '' } })

    assert result[:isError]
    assert_equal "name can't be blank", result[:structuredContent][:error]
    assert_equal({ name: ["can't be blank"] }, result[:structuredContent][:errors])
    assert_equal result[:structuredContent], JSON.parse(result[:content].first[:text], symbolize_names: true)
    assert_equal 0, Property.count
  end

  test "what only the database can refuse is a tool error without internals" do
    {
      { name: 'Tower', account_id: 0 } => "A foreign key points at a record that doesn't exist",
      { name: 'Tower', size: 10**12 } => "A value is out of range, too long or otherwise doesn't fit its column",
      { name: 'Tower', rent: 10**15 } => "A value is out of range, too long or otherwise doesn't fit its column"
    }.each do |attributes, expected|
      result = call_tool('create_property', { property: attributes })

      assert result[:isError], attributes.inspect
      assert_equal expected, result[:structuredContent][:error]
      refute_match(/SELECT|INSERT|constraint|"properties"|where/, result.to_s)
    end

    assert_equal 0, Property.count
  end

  test "a delete that other records block is a tool error and deletes nothing" do
    StandardMCP::Registry.stubs(:controllers).returns([Billing::AccountsController])
    property = create(:property)

    result = call_tool('delete_billing_account', { id: property.account_id })

    assert result[:isError]
    assert_equal "Other records still refer to this one, so it can't be deleted", result[:structuredContent][:error]
    assert Account.exists?(property.account_id)
  end

  test "create with a missing record key is a tool error" do
    assert_match(/Missing required arguments: contact/, tool_error('create_contact', { name: 'Pat' }))
  end

  # --- nested attributes

  test "create saves nested records in shallow mode" do
    content = structured('create_property', { property: { name: 'Tower', photos: [{ format: 'jpg', caption: 'Front' }, { format: 'png' }] } })

    property = Property.find(content[:record][:id])
    assert_equal %w[jpg png], property.photos.order(:id).map(&:format)
    # Nested records are rendered without being asked for.
    assert_equal ['Front', nil], content[:record][:photos].map { |p| p[:caption] }
    refute content[:record][:photos].first.key?(:internal_path)
  end

  test "create saves nested records in deep mode" do
    StandardMCP.config.input_schema_depth = 'deep'

    content = structured('create_property', { property: { name: 'Tower', photos: [{ format: 'tiff' }] } })

    assert_equal %w[tiff], Property.find(content[:record][:id]).photos.map(&:format)
  end

  test "deep mode rejects a bad nested record by schema, shallow mode lets StandardAPI answer" do
    bad = { property: { name: 'Tower', photos: [{ format: 'bmp' }] } }

    StandardMCP.config.input_schema_depth = 'deep'
    assert_match(/Invalid arguments/, tool_error('create_property', bad))
    assert_match(/Invalid arguments/, tool_error('create_property', { property: { name: 'Tower', photos: [{ nope: 1 }] } }))

    StandardMCP.config.input_schema_depth = 'shallow'
    result = call_tool('create_property', bad)
    assert result[:isError]
    assert_equal 'photos.format is not included in the list', result[:structuredContent][:error]
    assert_equal({ 'photos.format': ['is not included in the list'] }, result[:structuredContent][:errors])
    assert_equal 0, Property.count
    assert_equal 0, Photo.count
  end

  test "problems with nested records come back as tool errors, not server errors" do
    {
      { name: 'Tower', photos: [{ id: 0 }] } => 'Photo not found',
      { name: 'Tower', photo_ids: [0] } => 'Photo not found'
    }.each do |attributes, expected|
      assert_equal expected, tool_error('create_property', { property: attributes }), attributes.inspect
    end

    # A loose schema still has a type.
    assert_match(/Invalid arguments/, tool_error('create_property', { property: { name: 'Tower', photos: 'x' } }))
    assert_match(/Invalid arguments/, tool_error('create_property', { property: { name: 'Tower', photos: ['x'] } }))
    assert_equal 0, Property.count
  end

  test "photo_ids links existing records" do
    photos = create_list(:photo, 2)

    content = structured('create_property', { property: { name: 'Tower', photo_ids: photos.map(&:id) } })

    assert_equal photos.map(&:id).sort, Property.find(content[:record][:id]).photos.pluck(:id).sort
  end

  test "an update replaces the nested set" do
    property = create(:property)
    kept, dropped = create_list(:photo, 2, property: property)

    content = structured('update_property',
      { id: property.id, property: { photos: [{ id: kept.id, caption: 'Renamed' }, { format: 'png' }] } },
      writes(property.account_id))

    assert_equal 2, content[:record][:photos].size
    assert_equal 'Renamed', kept.reload.caption
    assert_nil dropped.reload.property_id
    assert_equal 2, property.photos.count
  end

  # --- update

  test "update changes only what is sent" do
    property = create(:property, name: 'Old', size: 10, description: 'Keep me')

    content = structured('update_property', { id: property.id, property: { name: 'New' } }, writes(property.account_id))

    assert_equal 'New', content[:record][:name]
    property.reload
    assert_equal 'New', property.name
    assert_equal 10, property.size
    assert_equal 'Keep me', property.description
  end

  test "update can clear a nullable column and honors include" do
    property = create(:property, size: 10)

    content = structured('update_property',
      { id: property.id, property: { size: nil }, include: { account: true } }, writes(property.account_id))

    assert_nil content[:record][:size]
    assert_equal property.account_id, content[:record][:account][:id]
  end

  test "update with no attributes is rejected" do
    property = create(:property)
    StandardMCP::Dispatcher.any_instance.expects(:call).never

    assert_match(/Invalid arguments/, tool_error('update_property', { id: property.id, property: {} }, writes(property.account_id)))
    assert_match(/Missing required arguments: id/, tool_error('update_property', { property: { name: 'x' } }))
    assert_match(/Missing required arguments: property/, tool_error('update_property', { id: property.id }))
  end

  test "update validation errors are tool errors and leave the record alone" do
    property = create(:property, name: 'Old')

    result = call_tool('update_property', { id: property.id, property: { name: '' } }, writes(property.account_id))

    assert result[:isError]
    assert_equal "name can't be blank", result[:structuredContent][:error]
    assert_equal 'Old', property.reload.name
  end

  test "update of a masked or missing id is not found" do
    mine = create(:account)
    other = create(:property, name: 'Other')

    assert_equal 'Property not found',
      tool_error('update_property', { id: other.id, property: { name: 'Hacked' } }, writes(mine.id))
    assert_equal 'Property not found',
      tool_error('update_property', { id: 0, property: { name: 'x' } }, writes(mine.id))
    assert_equal 'Other', other.reload.name
  end

  test "the not found message leaks nothing about the mask" do
    mine = create(:account)
    other = create(:property)

    text = call_tool('update_property', { id: other.id, property: { name: 'x' } }, writes(mine.id))[:content].first[:text]

    refute_match(/SELECT|WHERE|account_id|#{mine.id}/, text)
  end

  test "update works for another controller too" do
    contact = create(:contact, name: 'Pat')

    content = structured('update_contact', { id: contact.id, contact: { name: 'Sam', age: 40 } }, writes(contact.account_id))

    assert_equal %w[Sam 40], [content[:record][:name], content[:record][:age].to_s]
  end

  # --- delete

  test "delete removes the record and reports the rows" do
    contact = create(:contact)

    content = structured('delete_contact', { id: contact.id }, writes(contact.account_id))

    assert_equal({ success: true, affected_rows: 1 }, content)
    refute Contact.exists?(contact.id)
  end

  test "delete of a masked or missing id is not found and deletes nothing" do
    mine = create(:account)
    other = create(:contact)

    assert_equal 'Contact not found', tool_error('delete_contact', { id: other.id }, writes(mine.id))
    assert_equal 'Contact not found', tool_error('delete_contact', { id: 0 }, writes(mine.id))
    assert Contact.exists?(other.id)
  end

  test "a delete a callback aborts says why, in the model's words" do
    contact = create(:contact, name: 'Locked')

    assert_equal 'Contact could not be deleted: Locked contacts cannot be deleted',
      tool_error('delete_contact', { id: contact.id }, writes(contact.account_id))
    assert Contact.exists?(contact.id)
  end

  test "a delete a callback aborts without a reason says only that" do
    contact = create(:contact, name: 'Silent')

    assert_equal 'Contact could not be deleted', tool_error('delete_contact', { id: contact.id }, writes(contact.account_id))
    assert Contact.exists?(contact.id)
  end

  test "a save a callback aborts is reported the same way" do
    dispatcher = StandardMCP::Dispatcher.new(request_for(writes))
    contact = Contact.new(name: 'Pat')
    contact.errors.add(:base, 'Not today')
    error = ActiveRecord::RecordNotSaved.new('Failed to save the record', contact)

    assert_equal 'Contact could not be saved: Not today', dispatcher.send(:error_message, error, 422, :update)
    assert_equal 'Record could not be deleted',
      dispatcher.send(:error_message, ActiveRecord::RecordNotDestroyed.new('x'), 422, :destroy)
  end

  test "delete takes only an integer id" do
    contacts = create_list(:contact, 2)

    assert_match(/Invalid arguments/, tool_error('delete_contact', { id: contacts.map(&:id).join(',') }))
    assert_match(/Missing required arguments: id/, tool_error('delete_contact', {}))
    assert_equal 2, Contact.count
  end

  test "delete where the rules exclude it is not allowed" do
    property = create(:property)
    request = request_for(writes(property.account_id))

    result = StandardMCP::Tools.run(request, PropertiesController, :destroy, { id: property.id })

    assert result.error?
    assert_equal 'Action destroy is not allowed', result.structured_content[:error]
    assert Property.exists?(property.id)
  end

  test "a write that is no longer allowed is a not-allowed tool error" do
    server = server_for(writes)
    StandardMCP::Dispatcher.any_instance.stubs(:ensure_allowed!).raises(StandardMCP::ActionNotAllowed)

    result = rpc(server, 'tools/call', { name: 'create_contact', arguments: { contact: { name: 'Pat' } } })[:result]

    assert result[:isError]
    assert_equal 'Action create is not allowed', result[:structuredContent][:error]
    assert_equal 0, Contact.count
  end

  test "writes run through the dispatcher" do
    contact = create(:contact)
    events = []

    ActiveSupport::Notifications.subscribed(->(*args) { events << args.last[:action] }, 'dispatch.standard_mcp') do
      structured('create_contact', { contact: { name: 'Pat' } })
      structured('update_contact', { id: contact.id, contact: { name: 'Sam' } }, writes(contact.account_id))
      structured('delete_contact', { id: contact.id }, writes(contact.account_id))
    end

    assert_equal %i[create update destroy], events
  end

  test "a write without a bearer comes back as a tool error, not a crash" do
    result = call_tool('create_contact', { contact: { name: 'Pat' } }, 'X-MCP-Writes' => 'true')

    assert result[:isError]
    assert_equal 0, Contact.count
  end

  # --- ignored attributes

  test "a per-record ACL that drops a key is reported on update" do
    office = create(:property, kind: 'office', size: 10, name: 'HQ')
    retail = create(:property, kind: 'retail', size: 10, name: 'Shop')

    content = structured('update_writes_locked_property', { id: office.id, property: { name: 'HQ 2', size: 99 } })
    assert_equal ['size'], content[:ignored_attributes]
    assert_equal 'HQ 2', office.reload.name
    assert_equal 10, office.size

    content = structured('update_writes_locked_property', { id: retail.id, property: { name: 'Shop 2', size: 99 } })
    refute content.key?(:ignored_attributes)
    assert_equal 99, retail.reload.size
  end

  test "a create is judged as a new record" do
    content = structured('create_writes_locked_property', { property: { name: 'HQ', kind: 'office', size: 5 } })

    refute content.key?(:ignored_attributes)
    assert_equal 5, content[:record][:size]
  end

  test "nested keys the ACL drops are reported with their path" do
    content = structured('create_property',
      { property: { name: 'Tower', photos: [{ caption: 'A', internal_path: '/x' }, { format: 'png', secret: 1 }] } })

    assert_equal ['photos.internal_path', 'photos.secret'], content[:ignored_attributes]
    refute_includes Photo.pluck(:internal_path), '/x'
    assert_equal 2, Photo.count
  end

  test "ignored attributes are only reported when the write succeeds" do
    result = call_tool('create_property', { property: { name: '', photos: [{ secret: 1 }] } })

    assert result[:isError]
    refute result[:structuredContent].key?(:ignored_attributes)
  end

  test "an update of a masked record reports nothing and is not found" do
    mine = create(:account)
    other = create(:property)
    StandardMCP::IgnoredAttributes.expects(:for).never

    assert_equal 'Property not found', tool_error('update_property', { id: other.id, property: { name: 'x' } }, writes(mine.id))
  end

  test "when the record can't be looked up the nil-record list stands in" do
    request = request_for(writes)
    controller = StandardMCP::Registry.controller_for(PropertiesController, request)
    controller.stubs(:resources).raises(ArgumentError)
    StandardMCP::Registry.stubs(:controller_for).returns(controller)
    StandardMCP::IgnoredAttributes.expects(:for).with { |_controller, _model, record, _submitted| record.nil? }.returns(['x'])

    ignored = StandardMCP::Tools.send(:ignored_attributes, request, StandardMCP::Dispatcher.new(request),
      PropertiesController, :update, { 'id' => 1, 'property' => { 'name' => 'x' } })

    assert_equal ['x'], ignored
  end

  # --- size

  # Measured with PropertiesController and ContactsController; the limits leave
  # about 10% room.
  test "the write tools stay compact" do
    StandardMCP.reset_config!
    StandardMCP::Registry.stubs(:controllers).returns([PropertiesController, ContactsController])
    sizes = list_tools(writes).to_h { |t| [t[:name], JSON.generate(t).size] }

    assert_operator sizes['create_property'], :<=, 2_600
    assert_operator sizes['update_property'], :<=, 2_700
    assert_operator sizes['create_contact'], :<=, 1_500
    assert_operator sizes['update_contact'], :<=, 1_600
    assert_operator sizes['delete_contact'], :<=, 500
    # The write tools add little beyond what the read tools of a model cost.
    assert_operator sizes['create_property'], :<, sizes['list_properties']
  end

  test "deep mode only grows the nested association" do
    StandardMCP.reset_config!
    shallow = JSON.generate(tool('create_property')[:inputSchema]).size
    StandardMCP.config.input_schema_depth = 'deep'
    deep = JSON.generate(tool('create_property')[:inputSchema]).size

    assert_operator deep - shallow, :<, 400
  end

end
