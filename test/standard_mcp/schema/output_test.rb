require 'standard_mcp/test_helper'

class OutputSchemaTest < ActiveSupport::TestCase

  def request_for(headers = {})
    headers = headers.transform_keys { |k| "HTTP_#{k.upcase.tr('-', '_')}" }
    ActionDispatch::Request.new(Rack::MockRequest.env_for('/mcp', headers))
  end

  def controller_for(klass, headers = {})
    StandardMCP::Registry.controller_for(klass, request_for(headers))
  end

  def schema_for(klass, action, headers = {})
    StandardMCP::Schema::Output.for(controller_for(klass, headers), action)
  end

  def record_schema(klass)
    schema_for(klass, :show).dig('properties', 'record')
  end

  # Structured content of a real dispatch, as the tool layer would return it.
  def structured(klass, action, params = {}, extra: nil, headers: {})
    result = StandardMCP::Dispatcher.new(request_for(headers)).call(klass, action, params)
    response = StandardMCP::Response.from(result, action: action, extra: extra)
    refute response.error?, "dispatch failed: #{response.structured_content}"
    response.structured_content
  end

  # The validator the mcp server runs on tool results.
  def assert_valid(schema, content)
    MCP::Tool::OutputSchema.new(schema).validate_result(JSON.parse(JSON.generate(content)))
    assert true
  end

  def refute_valid(schema, content)
    assert_raises(MCP::Tool::OutputSchema::ValidationError) { assert_valid(schema, content) }
  end

  # --- shapes

  test "index wraps records with pagination" do
    schema = schema_for(PropertiesController, :index)

    assert_equal 'object', schema['type']
    assert_equal %w[records], schema['required']
    assert_equal 'array', schema.dig('properties', 'records', 'type')
    assert_equal record_schema(PropertiesController), schema.dig('properties', 'records', 'items')
    assert_equal 'integer', schema.dig('properties', 'offset', 'type')
    assert_equal %w[integer null], schema.dig('properties', 'next_offset', 'type')
    assert_equal 'integer', schema.dig('properties', 'total', 'type')
  end

  test "show wraps a single record" do
    schema = schema_for(PropertiesController, :show)

    assert_equal %w[record], schema['required']
    assert_equal ['record'], schema['properties'].keys
    assert_equal 'object', schema.dig('properties', 'record', 'type')
  end

  test "calculate accepts any result" do
    schema = schema_for(AccountsController, :calculate)

    assert_equal %w[result], schema['required']
    assert_equal ['result'], schema['properties'].keys
    assert_nil schema.dig('properties', 'result', 'type')
    assert_valid schema, { result: [1] }
    assert_valid schema, { result: { 'a' => 1 } }
  end

  test "create and update wrap the saved record, like show, and may report ignored attributes" do
    %i[create update].each do |action|
      schema = schema_for(PropertiesController, action)

      assert_equal %w[record], schema['required']
      assert_equal %w[record ignored_attributes], schema['properties'].keys
      assert_equal record_schema(PropertiesController), schema.dig('properties', 'record')
      assert_equal({ 'type' => 'array', 'items' => { 'type' => 'string' } },
        schema.dig('properties', 'ignored_attributes').slice('type', 'items'))

      record = structured(PropertiesController, :show, { 'id' => create(:property).id })[:record]
      assert_valid schema, { record: record }
      assert_valid schema, { record: record, ignored_attributes: ['size'] }
      refute_valid schema, { record: record, ignored_attributes: [1] }
      refute_valid schema, { record: { id: 1 } }
      refute_valid schema, { ignored_attributes: [] }
    end
  end

  test "destroy reports success and, when sent, the affected rows" do
    schema = schema_for(ContactsController, :destroy)

    assert_equal %w[success], schema['required']
    assert_equal 'boolean', schema.dig('properties', 'success', 'type')
    assert_equal 'integer', schema.dig('properties', 'affected_rows', 'type')

    assert_valid schema, { success: true, affected_rows: 1 }
    assert_valid schema, { success: true }
    refute_valid schema, { success: 'yes' }
    refute_valid schema, { affected_rows: 1 }
  end

  test "real write results validate" do
    account = create(:account)
    headers = { 'X-MCP-Writes' => 'true', 'Authorization' => "Bearer #{account.id}" }

    created = structured(ContactsController, :create, { 'contact' => { 'name' => 'Pat', 'account_id' => account.id } }, headers: headers)
    assert_valid schema_for(ContactsController, :create), created

    updated = structured(ContactsController, :update, { 'id' => created[:record]['id'], 'contact' => { 'name' => 'Sam' } }, headers: headers)
    assert_valid schema_for(ContactsController, :update), updated

    destroyed = structured(ContactsController, :destroy, { 'id' => created[:record]['id'] }, headers: headers)
    assert_equal({ success: true, affected_rows: 1 }, destroyed)
    assert_valid schema_for(ContactsController, :destroy), destroyed
  end

  test "unknown actions raise" do
    assert_raises(ArgumentError) { schema_for(PropertiesController, :nope) }
  end

  test "the schema is accepted by mcp" do
    %i[index show create update destroy calculate].each do |action|
      output = MCP::Tool::OutputSchema.new(schema_for(PropertiesController, action))
      assert_equal 'object', output.to_h[:type]
    end
  end

  # --- record schema

  test "table and column comments become descriptions" do
    schema = record_schema(PropertiesController)

    assert_equal Property.connection.table_comment('properties'), schema['description']
    Property.columns.select(&:comment).each do |column|
      assert_equal column.comment, schema.dig('properties', column.name, 'description')
    end
  end

  test "every column is described" do
    schema = record_schema(PropertiesController)

    Property.columns.each do |column|
      assert schema['properties'].key?(column.name), "missing #{column.name}"
    end
  end

  test "permitted includes are described, nested" do
    properties = record_schema(PropertiesController)['properties']

    assert properties.dig('account', 'properties').key?('name')
    assert_equal 'array', properties.dig('photos', 'type')
    assert properties.dig('photos', 'items', 'properties').key?('caption')
  end

  test "has_many includes are arrays and belongs_to includes are nullable objects" do
    properties = record_schema(PropertiesController)['properties']

    assert_equal 'array', properties['photos']['type']
    assert_equal %w[object null], properties['account']['type']
    assert_equal 'array', record_schema(AccountsController).dig('properties', 'properties', 'type')
  end

  test "includes the caller may not use are not described" do
    properties = record_schema(AccountsController)['properties']

    assert properties.key?('properties')
    refute properties['properties']['items']['properties'].key?('account')
  end

  test "nullable columns allow null and others do not" do
    properties = record_schema(PropertiesController)['properties']

    Property.columns.each do |column|
      # Untyped (json) columns already accept null.
      next unless properties[column.name].key?('type')

      type = Array(properties[column.name]['type'])
      assert_equal column.null, type.include?('null'), "#{column.name} nullability"
    end
  end

  test "the columns are required and the includes are not, as a call picks its own" do
    schema = record_schema(PropertiesController)

    assert_equal Property.column_names, schema['required']
    assert_equal Account.column_names, schema.dig('properties', 'account', 'required')
    # PhotoACL has excludes, which can leave any column out.
    assert_empty schema.dig('properties', 'photos', 'items', 'required')
  end

  test "the record is what read_schema_for builds, with the includes optional and no $schema" do
    controller = controller_for(PropertiesController)
    includes = controller.send(:normalize_includes, controller.send(:includes_for, Property))
    expected = controller.send(:read_schema_for, Property, includes)

    schema = record_schema(PropertiesController)

    refute schema.key?('$schema')
    assert_equal expected['properties'], schema['properties']
    assert_equal expected['required'] - %w[account photos], schema['required']
  end

  test "a controller without a model raises" do
    controller = controller_for(PropertiesController)
    controller.class.stubs(:model).returns(nil)

    assert_raises(ArgumentError) { StandardMCP::Schema::Output.for(controller, :show) }
  end

  # --- round trip: real dispatches validate against the schema

  test "index validates, with and without includes" do
    property = create(:property)
    create(:photo, property: property)
    schema = schema_for(PropertiesController, :index)

    assert_valid schema, structured(PropertiesController, :index, { 'limit' => 10 }, extra: { offset: 0, next_offset: nil, total: 1 })
    content = structured(PropertiesController, :index,
      { 'limit' => 10, 'include' => ['account', 'photos'] }, extra: { offset: 0, next_offset: nil, total: 1 })
    assert_equal 1, content[:records].first['photos'].size
    assert_valid schema, content
  end

  test "an empty index validates" do
    assert_valid schema_for(AccountsController, :index), structured(AccountsController, :index, { 'limit' => 10 })
  end

  test "show validates with nested includes" do
    photo = create(:photo)
    content = structured(PropertiesController, :show,
      { 'id' => photo.property_id, 'include' => { 'photos' => [], 'account' => {} } })

    refute content[:record]['photos'].first.key?('internal_path')
    assert_valid schema_for(PropertiesController, :show), content
  end

  test "null values validate" do
    property = create(:property, size: nil, description: nil, account: nil)
    content = structured(PropertiesController, :show, { 'id' => property.id, 'include' => ['account'] })

    assert_nil content[:record]['account']
    assert_nil content[:record]['size']
    assert_valid schema_for(PropertiesController, :show), content
  end

  test "every record column of every MCP controller validates" do
    create(:photo)

    [AccountsController, PropertiesController].each do |klass|
      id = klass.model.first.id
      assert_valid schema_for(klass, :show), structured(klass, :show, { 'id' => id })
    end
  end

  test "calculate validates" do
    create_list(:account, 2)
    schema = schema_for(AccountsController, :calculate)

    assert_valid schema, structured(AccountsController, :calculate, { 'select' => [{ 'count' => '*' }] })
    assert_valid schema, structured(AccountsController, :calculate,
      { 'select' => [{ 'count' => '*' }], 'group' => 'status' })
  end

  test "the schema rejects a wrongly shaped result" do
    schema = schema_for(PropertiesController, :show)

    refute_valid schema, { records: [] }
    refute_valid schema, { record: { id: 'x' } }
  end

end
