require 'standard_mcp/test_helper'

# Operators and value schemas from attribute definitions (Schema::Definitions
# entries), which needn't be columns, and the one rule on uuids.
class SchemaInputDefinitionsTest < ActiveSupport::TestCase

  Input = StandardMCP::Schema::Input

  def operators(definition, model = Property)
    Input.definition_operators(model, definition.transform_keys(&:to_s))
  end

  def names(definition, model = Property)
    operators(definition, model).keys
  end

  ORDERED = %w[eq not in not_in gt gte lt lte].freeze

  # --- kind

  test "the kind of a type" do
    {
      'integer' => :ordered, 'bigint' => :ordered, 'float' => :ordered, 'decimal' => :ordered, 'date' => :ordered,
      'datetime' => :ordered, 'time' => :ordered, 'timestamp' => :ordered,
      'string' => :text, 'text' => :text, 'citext' => :text,
      'boolean' => :boolean, 'json' => :json, 'jsonb' => :json, 'hstore' => :json,
      'uuid' => :other, 'inet' => :other, nil => :other, 'whatever' => :other
    }.each do |type, kind|
      assert_equal kind, Input.type_kind(type), type.inspect
    end
    assert_equal :ordered, Input.type_kind(:integer)
    assert_equal :array, Input.type_kind('string', true)
    assert_equal :array, Input.type_kind('jsonb', true)
  end

  test "the kind of a definition is its type, and an array is an array" do
    assert_equal :ordered, Input.definition_kind(Property, { 'name' => 'custom', 'type' => 'integer' })
    assert_equal :array, Input.definition_kind(Property, { 'name' => 'custom', 'type' => 'integer', 'array' => true })
    assert_equal :other, Input.definition_kind(Property, { 'name' => 'custom' })
    assert_equal :other, Input.definition_kind(nil, { 'name' => 'custom', 'type' => 'uuid' })
  end

  test "a real column keeps its sql_type checks" do
    geometry = stub(sql_type: 'geometry(Point,4326)', array: false, type: nil)
    range = stub(sql_type: 'int4range', array: false, type: :int4range)
    model = stub(columns_hash: { 'where' => geometry, 'during' => range })

    assert_equal :geometry, Input.definition_kind(model, { 'name' => 'where', 'type' => 'integer' })
    assert_equal :range, Input.definition_kind(model, { 'name' => 'during', 'type' => 'string' })
    assert_equal :ordered, Input.definition_kind(Property, { 'name' => 'size', 'type' => 'whatever' })
    assert_equal :array, Input.definition_kind(Property, { 'name' => 'tags', 'type' => 'whatever' })
  end

  # --- operators

  test "operators by type" do
    assert_equal ORDERED, names({ name: 'x', type: 'integer' })
    assert_equal ORDERED, names({ name: 'x', type: 'decimal' })
    assert_equal ORDERED, names({ name: 'x', type: 'datetime' })
    assert_equal ORDERED + %w[like ilike ts_match], names({ name: 'x', type: 'string' })
    assert_equal %w[eq not], names({ name: 'x', type: 'boolean' })
    assert_equal %w[eq not in not_in], names({ name: 'x', type: 'uuid' })
    assert_equal %w[eq not contains contained_by has_key has_keys has_any_key], names({ name: 'x', type: 'jsonb' })
    assert_equal %w[eq not contains contained_by overlaps excludes], names({ name: 'x', type: 'string', array: true })
  end

  test "an enum takes equality and membership of its values" do
    list = operators({ name: 'x', type: 'string', enum: %w[a b] })

    assert_equal %w[eq not in not_in], list.keys
    assert_equal({ 'enum' => ['a', 'b', nil] }, list['eq'])
    assert_equal({ 'type' => 'array', 'items' => { 'enum' => %w[a b] } }, list['in'])
  end

  test "an enum of a real column comes from its model" do
    assert_equal %w[eq not in not_in], names({ name: 'kind', type: 'string' })
    assert_equal %w[office retail industrial], Input.definition_enum(Property, { 'name' => 'kind' })
    assert_equal %w[jpg png tiff], Input.definition_enum(Photo, { 'name' => 'format' })
    assert_nil Input.definition_enum(Property, { 'name' => 'name' })
  end

  test "the value of an operator is typed by the definition" do
    schemas = ->(definition) { operators(definition).transform_values { |schema| schema } }

    assert_equal({ 'type' => %w[integer null] }, schemas.({ name: 'x', type: 'integer' })['eq'])
    assert_equal({ 'type' => 'array', 'items' => { 'type' => 'integer' } }, schemas.({ name: 'x', type: 'integer' })['in'])
    assert_equal({ 'type' => 'number' }, schemas.({ name: 'x', type: 'float' })['gt'])
    # StandardAPI's json_schema_for_type: a BigDecimal renders as a String, and either is accepted.
    assert_equal({ 'type' => %w[number string] }, schemas.({ name: 'x', type: 'decimal' })['gt'])
    assert_equal({ 'type' => 'string', 'format' => 'date' }, schemas.({ name: 'x', type: 'date' })['gt'])
    assert_equal({ 'type' => 'string', 'format' => 'date-time' }, schemas.({ name: 'x', type: 'datetime' })['lt'])
    assert_equal({ 'type' => 'string' }, schemas.({ name: 'x', type: 'string' })['gte'])
  end

  test "a type nothing is known about takes any value" do
    list = operators({ name: 'x' })

    assert_equal %w[eq not in not_in], list.keys
    assert_equal({ 'type' => 'array', 'items' => {} }, list['in'])
  end

  test "a real column is typed from the column, whatever the definition says" do
    assert_equal ORDERED, names({ name: 'size', type: 'string' })
    assert_equal({ 'type' => 'array', 'items' => { 'type' => 'integer' } }, operators({ name: 'size' })['in'])
  end

  # --- no format: uuid

  def uuid_model
    connection.create_table :uuid_things, id: :uuid, force: true do |t|
      t.uuid :owner_id
    end
    Class.new(ActiveRecord::Base) do
      self.table_name = 'uuid_things'
      def self.name = 'UuidThing'
    end
  end

  test "a uuid column has no format" do
    model = uuid_model
    column = model.columns_hash['owner_id']

    assert_equal({ 'type' => 'string' }, Input.value_schema(column))
    refute_includes JSON.generate(Input.column_operators(model, column)), 'uuid'
  end

  test "the id of a uuid model has no format" do
    model = uuid_model

    assert_equal({ 'type' => 'string', 'description' => 'ID of the uuid thing' }, Input.id_schema(model))
    assert_equal({ 'type' => 'string', 'pattern' => '^[^,]+$', 'description' => 'ID of the uuid thing' }, Input.id_schema(model, one: true))
  end

  test "a uuid definition has no format" do
    assert_equal({ 'type' => 'string' }, Input.definition_value_schema(Property, { 'name' => 'x', 'type' => 'uuid' }))
    refute_includes JSON.generate(operators({ name: 'x', type: 'uuid' })), 'format'
  end

  test "the tool schemas of a uuid model have no format" do
    model = uuid_model
    klass = Class.new(ApplicationController) do
      define_singleton_method(:model) { model }
      define_singleton_method(:controller_path) { 'uuid_things' }
      def uuid_thing_attributes(record = nil) = [:owner_id]
      def uuid_thing_wheres = [:id, :owner_id]
      def uuid_thing_includes = []
    end
    request = ActionDispatch::Request.new(Rack::MockRequest.env_for('/mcp'))
    controller = StandardMCP::Registry.controller_for(klass, request)

    %i[index show update destroy].each do |action|
      refute_includes JSON.generate(Input.for(controller, action)), '"uuid"', action.to_s
    end
    StandardMCP.config.input_schema_depth = 'deep'
    %i[index show create update destroy calculate].each do |action|
      refute_includes JSON.generate(Input.for(controller, action)), '"uuid"', "deep #{action}"
    end
  end

  test "the output schema has no format uuid" do
    model = uuid_model
    property = { 'type' => 'string', 'format' => 'uuid', 'description' => 'Owner' }

    StandardMCP::Schema::Output.adapt_column(property, model, model.columns_hash['owner_id'])

    assert_equal({ 'type' => ['string', 'null'], 'description' => 'Owner' }, property)
  end

  test "other formats are kept" do
    assert_equal({ 'type' => 'string', 'format' => 'date' }, Input.without_uuid({ 'type' => 'string', 'format' => 'date' }))
    assert_equal({ 'type' => 'string' }, Input.without_uuid({ 'type' => 'string', 'format' => 'uuid' }))
  end

end
