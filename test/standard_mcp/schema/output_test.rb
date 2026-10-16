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

  test "write actions are not implemented yet" do
    %i[create update destroy].each do |action|
      assert_raises(NotImplementedError) { schema_for(PropertiesController, action) }
    end
  end

  test "unknown actions raise" do
    assert_raises(ArgumentError) { schema_for(PropertiesController, :nope) }
  end

  test "the schema is accepted by mcp" do
    %i[index show calculate].each do |action|
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

  test "ACL attributes mark the rest readOnly" do
    properties = record_schema(PropertiesController)['properties']

    assert_equal true, properties['id']['readOnly']
    assert_equal true, properties['created_at']['readOnly']
    refute properties['name'].key?('readOnly')
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

  test "excluded attributes are not advertised, in nested records too" do
    photos = record_schema(PropertiesController).dig('properties', 'photos', 'items', 'properties')

    assert photos.key?('caption')
    refute photos.key?('internal_path')
  end

  test "records allow additional properties" do
    schema = record_schema(PropertiesController)

    assert_equal true, schema['additionalProperties']
    assert_equal true, schema.dig('properties', 'photos', 'items', 'additionalProperties')
    assert_equal true, schema.dig('properties', 'account', 'additionalProperties')
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

  test "only id is required" do
    schema = record_schema(PropertiesController)

    assert_equal %w[id], schema['required']
    assert_equal %w[id], schema.dig('properties', 'photos', 'items', 'required')
    assert_equal %w[id], schema.dig('properties', 'account', 'required')
  end

  test "input-only keywords are removed" do
    keywords = StandardMCP::Schema::Output::INPUT_ONLY_KEYWORDS
    # `properties` maps names to schemas, so check each property schema.
    # enum is re-added for Rails enums, which do bound output.
    enums = Property.defined_enums.keys
    check = ->(schema) do
      schema['properties'].each do |name, property|
        keywords.each do |k|
          next if k == 'enum' && enums.include?(name)
          refute property.key?(k), "#{k} left on #{name}"
        end
        check.call(property) if property.key?('properties')
        check.call(property['items']) if property['items'].is_a?(Hash) && property['items'].key?('properties')
      end
    end
    check.call(record_schema(PropertiesController))
  end

  test "rendering leaves the controller's includes alone" do
    controller = controller_for(PropertiesController)
    controller.instance_variable_set(:@includes, { 'marker' => {} })

    StandardMCP::Schema::Output.for(controller, :show)

    assert_equal({ 'marker' => {} }, controller.instance_variable_get(:@includes))

    fresh = controller_for(PropertiesController)
    StandardMCP::Schema::Output.for(fresh, :show)
    refute fresh.instance_variable_defined?(:@includes)
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
