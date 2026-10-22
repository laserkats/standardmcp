require 'standard_mcp/test_helper'

# Named classes: StandardAPI infers the model from the controller name, so the
# model is set explicitly. They vary their ACL by request to show that schemas
# follow the caller.
class SchemaInputVaryingController < ApplicationController
  def self.model
    Property
  end

  def property_orders
    request.headers['X-Admin'] == 'true' ? super + [:rent] : super
  end

  def property_includes
    request.headers['X-Admin'] == 'true' ? super : [:account]
  end

  def resource_limit
    request.headers['X-Limit'] ? request.headers['X-Limit'].to_i : super
  end
end

class SchemaInputPhotosController < ApplicationController
  def self.model
    Photo
  end

  def photo_orders
    [:id, :caption, :internal_path]
  end

  # photo_excludes hides internal_path, so ordering by it would leak it.
  def default_limit
    10
  end

  def resource_limit
    nil
  end
end

class SchemaInputNoIncludesController < ApplicationController
  def self.model
    Account
  end

  def account_includes
    []
  end
end

# Write schemas: attributes the ACL lists without a column, Hash entries,
# per-request attributes, excludes and nested associations.
class SchemaInputWritesController < ApplicationController
  def self.model
    Property
  end

  def property_attributes(record = nil)
    list = [:name, :id, :created_at, :updated_at, :listed_at, :rent, { tags: [] }, { metadata: {} }]
    list << :size if request.headers['X-Admin'] == 'true'
    list
  end

  def property_excludes(record = nil)
    request.headers['X-Nested'] == 'true' ? {} : { rent: true, photos: true }
  end

  # account_id isn't permitted above, yet StandardAPI takes it for a nested account.
  def nested_property_attributes
    request.headers['X-Nested'] == 'true' ? [:photos, :account] : [:photos]
  end
end

# Validators that depend on the record or the context, and attributes that
# aren't columns.
class SchemaInputQuirk < ActiveRecord::Base
  self.table_name = 'contacts'

  attribute :floors, :integer

  validates :email, presence: true, if: -> { false }
  validates :email, format: { with: /\A(?<user>\w+)@x\z/ }, allow_nil: true
  validates :role, inclusion: { in: %w[a b] }, on: :create
  validates :age, numericality: { greater_than: ->(_record) { 1 } }, allow_nil: true
  validates :account_id, presence: true, on: :update
end

class SchemaInputQuirkController < ApplicationController
  def self.model
    SchemaInputQuirk
  end

  def schema_input_quirk_attributes(record = nil)
    [:email, :role, :age, :account_id, :nickname, :floors]
  end
end

# Accounts nest properties and properties nest their account.
class SchemaInputCycleController < ApplicationController
  def self.model
    Account
  end

  def nested_account_attributes
    [:properties]
  end

  def nested_property_attributes
    [:account]
  end
end

class SchemaInputTest < ActiveSupport::TestCase

  # The typed filters; the shallow default is covered by schema/where_test.rb.
  setup do
    StandardMCP.config.input_schema_depth = 'deep'
  end

  def request_for(headers = {})
    env = Rack::MockRequest.env_for('/mcp', headers.transform_keys { |k| "HTTP_#{k.upcase.tr('-', '_')}" })
    ActionDispatch::Request.new(env)
  end

  def controller(klass, headers = {})
    StandardMCP::Registry.controller_for(klass, request_for(headers))
  end

  def schema(klass, action, headers = {})
    StandardMCP::Schema::Input.for(controller(klass, headers), action)
  end

  # Follows a '#/$defs/name' reference.
  def resolve(schema, node)
    return node unless node['$ref']

    name = node['$ref'].delete_prefix('#/$defs/')
    node.except('$ref').merge(schema['$defs'].fetch(name))
  end

  def where_properties(schema)
    schema['$defs']['where']['properties']
  end

  def column_filter(schema, column)
    resolve(schema, where_properties(schema).fetch(column))
  end

  # The operator object of a column's filter.
  def operators(schema, column)
    column_filter(schema, column)['properties']
  end

  def valid?(schema, arguments)
    MCP::Tool::InputSchema.new(schema).validate_arguments(arguments)
    true
  rescue MCP::Tool::InputSchema::ValidationError
    false
  end

  # --- shape

  test "index has the expected shape" do
    s = schema(AccountsController, :index)

    assert_equal 'object', s['type']
    assert_equal [], s['required']
    assert_equal false, s['additionalProperties']
    assert_equal %w[where order include limit offset distinct], s['properties'].keys
  end

  test "show has the expected shape" do
    s = schema(AccountsController, :show)

    assert_equal 'object', s['type']
    assert_equal ['id'], s['required']
    assert_equal false, s['additionalProperties']
    assert_equal %w[id include], s['properties'].keys
  end

  test "calculate has the expected shape" do
    s = schema(AccountsController, :calculate)

    assert_equal 'object', s['type']
    assert_equal ['select'], s['required']
    assert_equal false, s['additionalProperties']
    assert_equal %w[where select group_by], s['properties'].keys
  end

  test "action may be a string" do
    assert_equal schema(AccountsController, :show), schema(AccountsController, 'show')
  end

  test "create has the expected shape" do
    s = schema(PropertiesController, :create)

    assert_equal 'object', s['type']
    assert_equal ['property'], s['required']
    assert_equal false, s['additionalProperties']
    assert_equal %w[property include], s['properties'].keys
  end

  test "update has the expected shape" do
    s = schema(PropertiesController, :update)

    assert_equal %w[id property], s['required']
    assert_equal false, s['additionalProperties']
    assert_equal %w[id property include], s['properties'].keys
    assert_equal 'integer', s.dig('properties', 'id', 'type')
  end

  test "destroy takes only an id" do
    s = schema(ContactsController, :destroy)

    assert_equal ['id'], s['required']
    assert_equal false, s['additionalProperties']
    assert_equal ['id'], s['properties'].keys
    assert_equal 'integer', s.dig('properties', 'id', 'type')
    refute s.dig('properties', 'id').key?('pattern')
  end

  test "destroy keeps a string id from naming several records" do
    # StandardAPI deletes every id in a comma-separated list.
    Account.stubs(:primary_key).returns('name')
    id = schema(SchemaInputNoIncludesController, :destroy).dig('properties', 'id')

    assert_equal 'string', id['type']
    assert_equal '^[^,]+$', id['pattern']
    assert JSONSchemer.schema(id).valid?('abc')
    refute JSONSchemer.schema(id).valid?('1,2')
  end

  test "the record goes under its singular name, as StandardAPI requires" do
    assert_equal %w[contact include], schema(ContactsController, :create)['properties'].keys
    assert_equal %w[id contact include], schema(ContactsController, :update)['properties'].keys
  end

  # --- writes: attributes

  def record(action, klass = PropertiesController, headers = {})
    s = schema(klass, action, headers)
    s['properties'].fetch(klass.model.model_name.singular)
  end

  test "attributes are the ACL's permit list, typed like the json schema and described by their comments" do
    attributes = record(:create)['properties']

    assert_equal %w[account_id name kind size description available built_on rent photos photo_ids], attributes.keys
    assert_equal({ 'description' => 'The account that owns this property.', 'type' => ['integer', 'null'] }, attributes['account_id'])
    assert_equal({ 'description' => 'Marketing name of the property.', 'type' => 'string' }, attributes['name'])
    assert_equal ['boolean', 'null'], attributes['available']['type']
    assert_equal ['string', 'null'], attributes['built_on']['type']
    assert_equal 'date', attributes['built_on']['format']
    assert_equal ['number', 'null'], attributes['rent']['type']
    assert_equal 'Whether the property can be leased now.', attributes['available']['description']
    assert_equal false, record(:create)['additionalProperties']
  end

  test "an AR enum is an enum, with null only because the column is nullable" do
    kind = record(:create)['properties']['kind']

    assert_equal ['string', 'null'], kind['type']
    assert_equal ['office', 'retail', 'industrial', nil], kind['enum']
  end

  test "an inclusion validator is an enum, and a NOT NULL column doesn't offer null" do
    role = record(:create, ContactsController)['properties']['role']

    assert_equal 'string', role['type']
    assert_equal %w[member admin], role['enum']
  end

  test "null is offered only for nullable columns" do
    attributes = record(:create, ContactsController)['properties']

    assert_equal 'string', attributes['name']['type']
    assert_equal ['string', 'null'], attributes['email']['type']
    assert_equal ['integer', 'null'], attributes['age']['type']
  end

  test "length, numericality and format validators become keywords" do
    attributes = record(:create, ContactsController)['properties']

    assert_equal 50, attributes['name']['maxLength']
    assert_equal '^[^@\s]+@[^@\s]+$', attributes['email']['pattern']
    assert_equal 0, attributes['age']['minimum']
    assert_equal 150, attributes['age']['exclusiveMaximum']
  end

  test "required is a permitted NOT NULL column or presence validator without a default" do
    assert_equal ['name'], record(:create)['required']
    # role is NOT NULL but defaults to member.
    assert_equal ['name'], record(:create, ContactsController)['required']
    assert_equal %w[name], StandardMCP::Schema::Attributes.required(controller(ContactsController), Contact)
    refute record(:create, AccountsController).key?('required')
  end

  test "an update has no required attributes but needs at least one" do
    update = record(:update)

    refute update.key?('required')
    assert_equal 1, update['minProperties']
    refute record(:create).key?('minProperties')
    # Presence still rules out null.
    assert_equal 'string', update['properties']['name']['type']
  end

  test "ids, timestamps and database-filled columns are not writable even when the ACL lists them" do
    attributes = record(:create, SchemaInputWritesController)['properties']

    refute attributes.key?('id')
    refute attributes.key?('created_at')
    refute attributes.key?('updated_at')
    assert attributes.key?('listed_at')
  end

  test "attr_readonly columns are writable on create only" do
    Property.stubs(:readonly_attributes).returns(['size'])

    assert record(:create)['properties'].key?('size')
    refute record(:update)['properties'].key?('size')
  end

  test "ACL excludes remove columns and nested associations" do
    attributes = record(:create, SchemaInputWritesController)['properties']

    refute attributes.key?('rent')
    refute attributes.key?('photos')
    refute attributes.key?('photo_ids')
  end

  test "Hash entries in the permit list count by name" do
    attributes = record(:create, SchemaInputWritesController)['properties']

    assert_equal ['array', 'null'], attributes['tags']['type']
    assert_equal({ 'type' => 'string' }, attributes['tags']['items'])
    # json holds any JSON value.
    assert_equal({ 'description' => 'Unstructured attributes from the source system.' }, attributes['metadata'])
  end

  test "a permitted name that is not a column is accepted untyped, or typed by its attribute" do
    attributes = record(:create, SchemaInputQuirkController)['properties']

    assert_equal({}, attributes['nickname'])
    assert_equal({ 'type' => 'integer' }, attributes['floors'])
  end

  test "the schema follows the caller's ACL" do
    assert_includes record(:create, SchemaInputWritesController, 'X-Admin' => 'true')['properties'].keys, 'size'
    refute_includes record(:create, SchemaInputWritesController)['properties'].keys, 'size'
  end

  test "validators that depend on the record or the context are left to Rails" do
    attributes = record(:create, SchemaInputQuirkController)['properties']

    # Conditional presence: not required, still nullable.
    assert_equal ['string', 'null'], attributes['email']['type']
    refute record(:create, SchemaInputQuirkController).key?('required')
    # on: :create inclusion, a lambda bound, and a regexp ECMA can't match the same way.
    refute attributes['role'].key?('enum')
    refute attributes['age'].key?('exclusiveMinimum')
    refute attributes['email'].key?('pattern')
    assert_includes attributes['email']['description'], 'Must match /\A(?<user>\w+)@x\z/.'
  end

  test "a presence validator on: :update needs no value on create" do
    create = record(:create, SchemaInputQuirkController)['properties']['account_id']
    update = record(:update, SchemaInputQuirkController)['properties']['account_id']

    assert_equal ['integer', 'null'], create['type']
    assert_equal 'integer', update['type']
    refute record(:create, SchemaInputQuirkController).key?('required')
  end

  test "a regexp is translated to ECMA only when it matches the same strings" do
    ecma = ->(regexp) { StandardMCP::Schema::Attributes.send(:ecma, regexp) }

    assert_equal '^ab$', ecma.(/\Aab\z/)
    assert_equal '^(?:a|b)+\d{2,3}$', ecma.(/\A(?:a|b)+\d{2,3}\z/)
    assert_equal '^(?=a)a$', ecma.(/\A(?=a)a\z/)
    assert_nil ecma.(/a/i)
    assert_nil ecma.(/a b/x)
    assert_nil ecma.(/(?<n>a)/)
    assert_nil ecma.(/(?<=a)b/)
    assert_nil ecma.(/(?i)a/)
    assert_nil ecma.(/[[:alpha:]]/)
    assert_nil ecma.(/\h/)
    assert_nil ecma.(/\Aa\Z/)
    assert_nil ecma.(/a{,3}/)
    assert_nil ecma.(/\\A/)
  end

  test "the schema validates calls the way the validators would" do
    s = schema(ContactsController, :create)
    contact = { name: 'Pat', email: 'pat@example.com', role: 'admin', age: 30 }

    assert valid?(s, { contact: contact })
    assert valid?(s, { contact: { name: 'Pat', email: nil, age: nil } })
    refute valid?(s, { contact: {} })
    refute valid?(s, { contact: contact.merge(name: nil) })
    refute valid?(s, { contact: contact.merge(name: 'x' * 51) })
    refute valid?(s, { contact: contact.merge(email: 'nope') })
    refute valid?(s, { contact: contact.merge(role: 'owner') })
    refute valid?(s, { contact: contact.merge(age: -1) })
    refute valid?(s, { contact: contact.merge(age: 150) })
    refute valid?(s, { contact: contact.merge(age: '30') })
    refute valid?(s, { contact: contact.merge(created_at: '2020-01-01T00:00:00Z') })
    refute valid?(s, { contact: contact.merge(id: 1) })
    refute valid?(s, { contact: contact.merge(secret: 1) })
    refute valid?(s, { name: 'Pat' })
  end

  test "an update schema accepts a partial record and rejects an empty one" do
    s = schema(ContactsController, :update)

    assert valid?(s, { id: 1, contact: { name: 'Sam' } })
    assert valid?(s, { id: 1, contact: { email: nil } })
    refute valid?(s, { id: 1, contact: {} })
    refute valid?(s, { contact: { name: 'Sam' } })
    refute valid?(s, { id: 'one', contact: { name: 'Sam' } })
    refute valid?(s, { id: 1 })
  end

  test "include is the same as show's" do
    show = schema(PropertiesController, :show)['properties']['include']

    assert_equal show, schema(PropertiesController, :create)['properties']['include']
    assert_equal show, schema(PropertiesController, :update)['properties']['include']
    assert valid?(schema(PropertiesController, :create), { property: { name: 'A' }, include: { photos: true } })
    refute valid?(schema(PropertiesController, :create), { property: { name: 'A' }, include: { nope: true } })
  end

  test "a controller without an include list has no include argument" do
    assert_equal ['account'], schema(SchemaInputNoIncludesController, :create)['properties'].keys
  end

  # --- writes: nested attributes

  test "deep mode types a nested collection, its attributes, and ids" do
    s = schema(PropertiesController, :create)
    photos = s.dig('properties', 'property', 'properties', 'photos')

    assert_equal 'array', photos['type']
    assert_includes photos['description'], 'Replaces the whole set'
    assert_includes photos['description'], 'An image attached to a property.'
    item = photos['items']
    assert_equal 'object', item['type']
    assert_equal false, item['additionalProperties']
    assert_equal %w[id property_id format caption], item['properties'].keys
    assert_equal %w[jpg png tiff], item['properties']['format']['enum'] - [nil]
    refute item.key?('required')
    assert_equal({ 'type' => 'array', 'items' => { 'type' => 'integer' } },
      s.dig('properties', 'property', 'properties', 'photo_ids').slice('type', 'items'))

    assert valid?(s, { property: { name: 'A', photos: [{ caption: 'x' }, { id: 3, format: 'png' }, { id: 4 }] } })
    refute valid?(s, { property: { name: 'A', photos: [{ format: 'bmp' }] } })
    refute valid?(s, { property: { name: 'A', photos: [{ internal_path: 'x' }] } })
    refute valid?(s, { property: { name: 'A', photos: 'x' } })
    refute valid?(s, { property: { name: 'A', photos: nil } })
  end

  test "shallow mode is a loose record and a pointer, with no attribute named" do
    StandardMCP.config.input_schema_depth = 'shallow'
    create = schema(PropertiesController, :create)
    update = schema(PropertiesController, :update)

    assert_equal({ 'type' => 'object', 'description' => "The property's attributes. Writable and required attributes: " \
      'describe_attributes {"resource": "properties"}.' }, create.dig('properties', 'property'))
    assert_equal 1, update.dig('properties', 'property', 'minProperties')
    assert_equal ['property'], create['required']
    assert_equal %w[id property], update['required']
    refute_includes JSON.generate(create), 'built_on'
    assert valid?(create, { property: { anything: 1 } })
  end

  test "shallow mode keeps no key or attribute list in any tool schema" do
    StandardMCP.config.input_schema_depth = 'shallow'
    # (size and name are in the generic examples.)
    names = %w[built_on listed_at metadata rent tags kind photos account_id internal_path]

    %i[index show calculate create update destroy].each do |action|
      json = JSON.generate(schema(PropertiesController, action))

      names.each { |name| refute_includes json, name, "#{action} names #{name}" }
    end
  end

  test "shallow order and include are loose objects with a pointer" do
    StandardMCP.config.input_schema_depth = 'shallow'
    properties = schema(PropertiesController, :index)['properties']

    assert_equal 'object', properties['order']['type']
    refute properties['order'].key?('properties')
    assert_includes properties['order']['description'], '"asc" or "desc", or {"asc": "nulls_first"}'
    assert_includes properties['order']['description'], 'Orderable keys: describe_query {"resource": "properties"}.'

    assert_equal 'object', properties['include']['type']
    refute properties['include'].key?('properties')
    assert_includes properties['include']['description'], 'e.g. {"account": {}}'
    assert_includes properties['include']['description'], 'checked against the associated resource'
    assert_includes properties['include']['description'], 'Includable associations: describe_query {"resource": "properties"}.'
    assert_equal properties['include'], schema(PropertiesController, :show)['properties']['include']
    assert_equal properties['include'], schema(PropertiesController, :create)['properties']['include']
  end

  test "shallow calculate has loose select items and a string group_by, and keeps the one aggregate rule" do
    StandardMCP.config.input_schema_depth = 'shallow'
    s = schema(PropertiesController, :calculate)

    assert_equal 'array', s.dig('properties', 'select', 'type')
    assert_equal({ 'type' => 'object', 'minProperties' => 1 }, s.dig('properties', 'select', 'items'))
    assert_includes s.dig('properties', 'select', 'description'), '[{"count": "*"}, {"maximum": "size"}, {"count": {"distinct": "name"}}]'
    assert_includes s.dig('properties', 'select', 'description'), 'Attribute names: describe_attributes {"resource": "properties"}.'
    assert_equal 'string', s.dig('properties', 'group_by', 'type')
    refute s.dig('properties', 'group_by').key?('enum')

    assert valid?(s, { 'select' => [{ 'count' => '*' }] })
    assert valid?(s, { 'select' => [{ 'count' => '*' }], 'group_by' => 'kind' })
    refute valid?(s, { 'select' => [{ 'count' => '*' }, { 'maximum' => 'size' }], 'group_by' => 'kind' })
    refute valid?(s, { 'select' => [{ 'count' => '*', 'maximum' => 'size' }], 'group_by' => 'kind' })
  end

  test "without the describe tools the shallow schemas point nowhere" do
    StandardMCP.config.input_schema_depth = 'shallow'
    StandardMCP.config.describe_tools = false

    %i[index show calculate create update].each do |action|
      refute_includes JSON.generate(schema(PropertiesController, action)), 'describe', action.to_s
    end
  end

  test "shallow and deep agree on everything but the record's attributes" do
    deep = schema(PropertiesController, :create)['properties']
    StandardMCP.config.input_schema_depth = 'shallow'
    shallow = schema(PropertiesController, :create)['properties']

    assert_equal deep.keys, shallow.keys
    assert_operator JSON.generate(deep).size, :>, JSON.generate(shallow).size * 2
  end

  test "a nested belongs_to is an object or null, and its foreign key is taken even when the ACL doesn't list it" do
    attributes = record(:create, SchemaInputWritesController, 'X-Nested' => 'true')['properties']

    assert_equal ['integer', 'null'], attributes['account_id']['type']
    assert_equal 'The account that owns this property.', attributes['account_id']['description']
    assert_equal ['object', 'null'], attributes['account']['type']
    assert_equal %w[id name status notes], attributes['account']['properties'].keys
    refute attributes.key?('account_ids')
  end

  test "a cycle of nested associations ends in a loose object" do
    items = schema(SchemaInputCycleController, :create).dig('properties', 'account', 'properties', 'properties', 'items')

    assert_equal 'object', items['type']
    # properties -> account again: the model is already on the path.
    inner = items.dig('properties', 'account')
    assert_equal ['object', 'null'], inner['type']
    refute inner.key?('properties')
  end

  test "unknown actions are rejected" do
    assert_raises(ArgumentError) { schema(AccountsController, :tables) }
  end

  test "schemas have String keys only" do
    walk = ->(node) do
      case node
      when Hash then node.each { |k, v| assert_kind_of String, k; walk.(v) }
      when Array then node.each(&walk)
      end
    end

    %i[index show create update destroy calculate].each { |action| walk.(schema(PropertiesController, action)) }
  end

  # --- where: descriptions

  test "where documents AND/OR composition once" do
    s = schema(AccountsController, :index)
    description = s['properties']['where']['description']

    assert_match(/"AND" or "OR"/, description)
    assert_match(/not.*null/, description)
    assert_equal 1, s.to_json.scan('with no precedence').size
  end

  test "column comments become descriptions and missing comments stay absent" do
    s = schema(AccountsController, :index)

    assert_equal 'Display name of the organization.', where_properties(s)['name']['description']
    assert_equal 'Lifecycle status, e.g. active or suspended.', where_properties(s)['status']['description']
    refute where_properties(s)['notes'].key?('description')
    refute where_properties(s)['id'].key?('description')
  end

  # --- where: types

  test "column types follow StandardAPI's json_schema mapping" do
    s = schema(PropertiesController, :index)
    value = ->(column) { operators(s, column)['eq'] }

    assert_equal({ 'type' => ['integer', 'null'] }, value.('size'))
    assert_equal({ 'type' => ['boolean', 'null'] }, value.('available'))
    assert_equal({ 'type' => ['string', 'null'], 'format' => 'date' }, value.('built_on'))
    assert_equal({ 'type' => ['string', 'null'], 'format' => 'date-time' }, value.('listed_at'))
    assert_equal({ 'type' => ['number', 'null'] }, value.('rent'))
    assert_equal({ 'type' => ['string', 'null'] }, value.('description'))
  end

  test "there is one compact definition per column type" do
    s = schema(PropertiesController, :index)
    ref = ->(column) { where_properties(s)[column]['$ref'].delete_prefix('#/$defs/') }

    assert_equal 'integer_filter', ref.('size')
    assert_equal ref.('size'), ref.('account_id')
    assert_equal 'number_filter', ref.('rent')
    assert_equal 'string_filter', ref.('name')
    assert_equal ref.('name'), ref.('description')
    assert_equal 'date_filter', ref.('built_on')
    assert_equal 'datetime_filter', ref.('listed_at')
    assert_equal 'boolean_filter', ref.('available')
    assert_equal 'string_array_filter', ref.('tags')
    assert_equal 'json_filter', ref.('metadata')
    assert_equal %w[boolean_filter date_filter datetime_filter integer_filter json_filter number_filter string_array_filter string_filter],
      s['$defs'].keys.grep(/_filter\z/).sort
  end

  test "filter definitions carry no per-operator descriptions" do
    s = schema(PropertiesController, :index)

    s['$defs'].select { |k, _| k.end_with?('_filter') }.each_value { |d| refute_includes d.to_json, '"description"' }
    assert_match(/ilike/, s['properties']['where']['description'])
    assert_match(/ts_match/, s['properties']['where']['description'])
  end

  test "only referenced definitions are emitted" do
    StandardMCP.config.where_depth = 0
    s = schema(PhotosController, :index)
    refs = s.to_json.scan(%r{#/\$defs/(\w+)}).flatten.uniq

    assert_equal refs.sort, s['$defs'].keys.sort
    refute_includes s['$defs'].keys, 'boolean_filter'
    refute_includes s['$defs'].keys, 'json_filter'
    assert_empty s['$defs'].keys.grep(/_options\z/)
  end

  test "every column takes an operator object and nothing else" do
    s = schema(PropertiesController, :index)

    %w[size name available built_on listed_at rent tags metadata kind].each do |column|
      filter = column_filter(s, column)
      assert_equal 'object', filter['type'], column
      assert_equal false, filter['additionalProperties'], column
      assert_equal 1, filter['minProperties'], column
      refute filter.key?('anyOf'), column
    end
  end

  test "ordinary columns take null only through eq and not" do
    ops = operators(schema(PropertiesController, :index), 'size')

    assert_equal({ 'type' => ['integer', 'null'] }, ops['eq'])
    assert_equal({ 'type' => ['integer', 'null'] }, ops['not'])
    assert_equal({ 'type' => 'integer' }, ops['gt'])
  end

  test "array columns take whole arrays for eq and not, lists for the rest" do
    ops = operators(schema(PropertiesController, :index), 'tags')
    list = { 'type' => 'array', 'items' => { 'type' => 'string' } }

    assert_equal({ 'type' => %w[array null], 'items' => { 'type' => 'string' } }, ops['eq'])
    assert_equal ops['eq'], ops['not']
    %w[contains contained_by overlaps excludes].each { |op| assert_equal list, ops[op] }
  end

  test "json columns take null through eq and not" do
    ops = operators(schema(PropertiesController, :index), 'metadata')

    assert_equal({ 'type' => 'null' }, ops['eq'])
    assert_equal({ 'type' => 'null' }, ops['not'])
  end

  # --- where: enums

  test "an AR enum column carries its values inline" do
    s = schema(PropertiesController, :index)
    kind = where_properties(s)['kind']
    values = %w[office retail industrial]

    assert_equal 'Asset class of the property.', kind['description']
    refute kind.key?('$ref')
    assert_equal 'object', kind['type']
    assert_equal false, kind['additionalProperties']
    assert_equal 1, kind['minProperties']
    assert_equal %w[eq not in not_in], kind['properties'].keys
    assert_equal({ 'enum' => values + [nil] }, kind['properties']['eq'])
    assert_equal({ 'enum' => values + [nil] }, kind['properties']['not'])
    assert_equal({ 'type' => 'array', 'items' => { 'enum' => values } }, kind['properties']['in'])
    assert_equal kind['properties']['in'], kind['properties']['not_in']
  end

  test "enums add no defs" do
    s = schema(PropertiesController, :index)

    assert_empty s['$defs'].keys.grep(/_options\z/)
    assert_empty schema(PropertiesController, :calculate)['$defs'].keys.grep(/_options\z/)
  end

  test "an unconditional inclusion validator makes an inline enum" do
    s = schema(PhotosController, :index)
    format = where_properties(s)['format']

    assert_equal %w[jpg png tiff], format['properties']['in']['items']['enum']
    assert_equal %w[jpg png tiff] + [nil], format['properties']['eq']['enum']
  end

  test "an enum used through an association is inline too" do
    s = schema(AccountsController, :index)
    nested = where_properties(s)['properties']['properties']['kind']

    assert_equal %w[office retail industrial], nested['properties']['in']['items']['enum']
  end

  test "enum values are validated through operators" do
    s = schema(PropertiesController, :index)

    assert valid?(s, { 'where' => { 'kind' => { 'eq' => 'retail' } } })
    assert valid?(s, { 'where' => { 'kind' => { 'eq' => nil } } })
    assert valid?(s, { 'where' => { 'kind' => { 'not' => nil } } })
    assert valid?(s, { 'where' => { 'kind' => { 'in' => %w[office retail] } } })
    assert valid?(s, { 'where' => { 'kind' => { 'not_in' => ['retail'] } } })

    refute valid?(s, { 'where' => { 'kind' => { 'eq' => 'castle' } } })
    refute valid?(s, { 'where' => { 'kind' => { 'in' => ['castle'] } } })
    refute valid?(s, { 'where' => { 'kind' => { 'in' => %w[office castle] } } })
    refute valid?(s, { 'where' => { 'kind' => { 'like' => 'off%' } } })
    refute valid?(s, { 'where' => { 'kind' => { 'gt' => 'office' } } })
    refute valid?(s, { 'where' => { 'kind' => {} } })
    refute valid?(schema(AccountsController, :index), { 'where' => { 'properties' => { 'kind' => { 'eq' => 'castle' } } } })
    assert valid?(schema(AccountsController, :index), { 'where' => { 'properties' => { 'kind' => { 'eq' => 'office' } } } })
  end

  # --- where: shorthands are not offered

  test "activerecord-filter shorthands are rejected for every column family" do
    s = schema(PropertiesController, :index)
    shorthands = {
      'size' => [3, [1, 2], nil, true, false],
      'name' => ['a', %w[a b], nil, true, false],
      'built_on' => ['2024-01-01', ['2024-01-01'], nil, true],
      'listed_at' => ['2024-01-01T00:00:00Z', nil, true],
      'rent' => [1.5, [1.5], nil, false],
      'available' => [true, false, nil],
      'kind' => ['office', %w[office retail], nil, true],
      'tags' => ['a', %w[a b], nil, true],
      'metadata' => [nil, true, { 'a' => 1 }]
    }

    shorthands.each do |column, values|
      values.each do |value|
        refute valid?(s, { 'where' => { column => value } }), "#{column} => #{value.inspect} should be rejected"
      end
    end
    refute valid?(s, { 'where' => { 'account' => nil } })
    refute valid?(s, { 'where' => [{ 'size' => 1 }, 'OR', { 'size' => { 'eq' => 2 } }] })
  end

  test "the where description teaches operator objects, not shorthands" do
    description = schema(AccountsController, :index)['properties']['where']['description']

    assert_match(/Every column takes an operator object/, description)
    assert_match(/\{"name": \{"eq": null\}\}/, description)
    refute_match(/a scalar \(equals\)/, description)
  end

  # --- where: per-column validation through the mcp gem

  test "types are enforced per column" do
    s = schema(PropertiesController, :index)

    refute valid?(s, { 'where' => { 'size' => { 'eq' => 'big' } } })
    refute valid?(s, { 'where' => { 'size' => { 'eq' => 1.5 } } })
    refute valid?(s, { 'where' => { 'size' => { 'in' => ['a'] } } })
    refute valid?(s, { 'where' => { 'size' => { 'gt' => 'a' } } })
    refute valid?(s, { 'where' => { 'size' => { 'in' => 3 } } })
    refute valid?(s, { 'where' => { 'name' => { 'eq' => 5 } } })
    refute valid?(s, { 'where' => { 'available' => { 'eq' => 'yes' } } })
    refute valid?(s, { 'where' => { 'rent' => { 'eq' => 'cheap' } } })
    refute valid?(s, { 'where' => { 'built_on' => { 'eq' => 20240101 } } })
    assert valid?(s, { 'where' => { 'rent' => { 'eq' => 1.5 }, 'size' => { 'eq' => 3 }, 'built_on' => { 'eq' => '2024-01-01' },
                                    'listed_at' => { 'eq' => '2024-01-01T00:00:00Z' } } })
    assert valid?(s, { 'where' => { 'rent' => { 'gte' => 1 }, 'listed_at' => { 'lt' => '2024-01-01T00:00:00Z' } } })
  end

  test "operators are limited to the column's type" do
    s = schema(PropertiesController, :index)

    refute valid?(s, { 'where' => { 'size' => { 'ilike' => '%1%' } } })
    refute valid?(s, { 'where' => { 'size' => { 'ts_match' => 'x' } } })
    refute valid?(s, { 'where' => { 'available' => { 'gt' => true } } })
    refute valid?(s, { 'where' => { 'available' => { 'in' => [true] } } })
    refute valid?(s, { 'where' => { 'built_on' => { 'like' => '2024%' } } })
    refute valid?(s, { 'where' => { 'tags' => { 'gt' => 'a' } } })
    refute valid?(s, { 'where' => { 'tags' => { 'eq' => 'a' } } })
    refute valid?(s, { 'where' => { 'tags' => { 'contains' => 'a' } } })
    refute valid?(s, { 'where' => { 'metadata' => { 'eq' => {} } } })
    assert valid?(s, { 'where' => { 'name' => { 'ilike' => '%a%', 'ts_match' => ['foo & bar', 'english'] } } })
    assert valid?(s, { 'where' => { 'available' => { 'not' => nil } } })
    assert valid?(s, { 'where' => { 'size' => { 'eq' => nil }, 'built_on' => { 'eq' => nil }, 'metadata' => { 'eq' => nil } } })
    assert valid?(s, { 'where' => { 'tags' => { 'eq' => ['a'], 'not' => nil }, 'metadata' => { 'not' => nil } } })
  end

  # --- where: depth

  test "where_depth defaults to 1" do
    assert_equal 1, StandardMCP.config.where_depth
  end

  test "where_depth 0 offers only the model's own columns" do
    StandardMCP.config.where_depth = 0
    props = where_properties(schema(PropertiesController, :index))

    assert_equal Property.column_names, props.keys
    refute valid?(schema(PropertiesController, :index), { 'where' => { 'account' => { 'name' => { 'eq' => 'x' } } } })
    # include is not limited.
    assert_equal %w[account photos], schema(PropertiesController, :index)['properties']['include']['properties'].keys
  end

  test "where_depth 0 emits no defs for associated columns" do
    StandardMCP.config.where_depth = 0
    s = schema(AccountsController, :index)

    assert_equal %w[string_filter integer_filter datetime_filter].sort, s['$defs'].keys.grep(/_filter\z/).sort
    assert_equal %w[direction where], (s['$defs'].keys - s['$defs'].keys.grep(/_filter\z/)).sort
  end

  test "where_depth 1 nests one association level" do
    props = where_properties(schema(AccountsController, :index))

    assert_includes props.keys, 'properties'
    assert_includes props['properties']['properties'].keys, 'name'
    refute_includes props['properties']['properties'].keys, 'photos'
  end

  # StandardAPI checks an include against the associated model's own ACL and
  # no longer lets an ACL nest one, so the include tree is one level and a
  # deeper where_depth has nothing more to follow.
  test "where_depth is bounded by the permitted includes, which are one level" do
    one = schema(AccountsController, :index)
    StandardMCP.config.where_depth = 2
    two = schema(AccountsController, :index)

    assert_equal one, two
    StandardMCP.config.where_depth = 5
    assert_equal one, schema(AccountsController, :index)
  end

  test "where_depth 1 rejects a second level" do
    s = schema(AccountsController, :index)

    refute valid?(s, { 'where' => { 'properties' => { 'photos' => { 'caption' => { 'eq' => 'x' } } } } })
  end

  # --- size

  test "the account index input schema stays small" do
    # Measured at 7919 characters with operator objects only (8848 with shorthands).
    assert_operator schema(AccountsController, :index).to_json.size, :<, 8700
  end

  # --- where: operators (activerecord-filter's expand_filter_for_arel_attribute)

  test "operators per column kind" do
    s = schema(PropertiesController, :index)

    assert_equal %w[eq not in not_in gt gte lt lte], operators(s, 'size').keys
    assert_equal %w[eq not in not_in gt gte lt lte], operators(s, 'built_on').keys
    assert_equal %w[eq not in not_in gt gte lt lte], operators(s, 'listed_at').keys
    assert_equal %w[eq not in not_in gt gte lt lte like ilike ts_match], operators(s, 'name').keys
    assert_equal %w[eq not], operators(s, 'available').keys
    assert_equal %w[eq not contains contained_by overlaps excludes], operators(s, 'tags').keys
    assert_equal %w[eq not contains contained_by has_key has_keys has_any_key], operators(s, 'metadata').keys
  end

  test "every operator is one activerecord-filter implements" do
    source = File.read(Gem.loaded_specs['activerecord-filter'].full_gem_path + '/lib/active_record/filter/predicate_builder_extension.rb')
    implemented = source.scan(/^\s+when (:[^\n]+)$/).flatten.flat_map { |l| l.scan(/:(\w+)/).flatten }.to_set

    s = schema(PropertiesController, :index)
    advertised = Property.column_names.flat_map { |c| operators(s, c).keys }.uniq

    assert_empty advertised.reject { |op| implemented.include?(op) }
  end

  test "operator values are typed" do
    s = schema(PropertiesController, :index)

    assert_equal({ 'type' => 'array', 'items' => { 'type' => 'integer' } }, operators(s, 'size')['in'])
    assert_equal({ 'type' => 'string', 'format' => 'date' }, operators(s, 'built_on')['gt'])
    assert_equal 'string', operators(s, 'name')['like']['type']
    assert_equal 'array', operators(s, 'metadata')['has_keys']['type']
  end

  test "hidden columns are not filterable" do
    s = schema(PhotosController, :index)

    assert_includes where_properties(s).keys, 'caption'
    refute_includes where_properties(s).keys, 'internal_path'
  end

  # --- where: associations

  test "associations in model_includes are filterable" do
    s = schema(PropertiesController, :index)
    props = where_properties(s)

    assert_equal %w[account photos], props.keys & %w[account photos]
    assert_equal 'object', props['account']['type']
    assert_includes props['account']['properties'].keys, 'name'
    assert_includes props['photos']['properties'].keys, 'caption'
  end

  test "association descriptions prefer the FK comment, then the table comment" do
    props = where_properties(schema(PropertiesController, :index))

    assert_equal 'The account that owns this property.', props['account']['description']
    assert_equal 'An image attached to a property.', props['photos']['description']
  end

  test "association filters carry the associated column descriptions" do
    props = where_properties(schema(PropertiesController, :index))
    name = resolve(schema(PropertiesController, :index), props['account']['properties']['name'])

    assert_equal 'Display name of the organization.', name['description']
  end

  test "association filters stop at the depth includes allow" do
    props = where_properties(schema(AccountsController, :index))

    assert_includes props.keys, 'properties'
    refute_includes props['properties']['properties'].keys, 'photos'
    refute_includes props['properties']['properties'].keys, 'account'
  end

  test "hidden columns of associated models are not filterable" do
    props = where_properties(schema(PropertiesController, :index))

    assert_includes props['photos']['properties'].keys, 'caption'
    refute_includes props['photos']['properties'].keys, 'internal_path'
  end

  test "valid where arguments are accepted" do
    s = schema(PropertiesController, :index)

    assert valid?(s, { 'where' => { 'size' => { 'gte' => 1000, 'lt' => 5000 } } })
    assert valid?(s, { 'where' => { 'size' => { 'in' => [1, 2] }, 'name' => { 'eq' => nil }, 'available' => { 'eq' => true } } })
    assert valid?(s, { 'where' => { 'account' => { 'name' => { 'eq' => 'x' } } } })
    assert valid?(s, { 'where' => { 'metadata' => { 'has_key' => 'a' }, 'tags' => { 'overlaps' => ['a'] } } })
    assert valid?(s, { 'where' => { 'name' => { 'not' => nil } } })
    assert valid?(s, { 'where' => [{ 'size' => { 'eq' => 1 } }, 'OR', { 'account' => { 'name' => { 'eq' => 'x' } } }] })
  end

  test "invalid where arguments are rejected" do
    s = schema(PropertiesController, :index)

    refute valid?(s, { 'where' => { 'nope' => 1 } })
    refute valid?(s, { 'where' => { 'size' => { 'like' => 'x' } } })
    refute valid?(s, { 'where' => { 'size' => { 'eq' => 'big' } } })
    refute valid?(s, { 'where' => { 'available' => { 'gt' => true } } })
    refute valid?(s, { 'where' => { 'kind' => { 'eq' => 'castle' } } })
    refute valid?(s, { 'where' => { 'size' => {} } })
    refute valid?(s, { 'where' => [{ 'size' => { 'eq' => 1 } }, 'XOR', { 'size' => { 'eq' => 2 } }] })
    refute valid?(s, { 'where' => { 'account' => { 'nope' => 1 } } })
  end

  # --- order

  test "order is restricted to the ACL's orders" do
    assert_equal %w[id name created_at], schema(AccountsController, :index)['properties']['order']['properties'].keys
    assert_equal %w[id name size created_at], schema(PropertiesController, :index)['properties']['order']['properties'].keys
  end

  test "order keys carry column comments" do
    props = schema(PropertiesController, :index)['properties']['order']['properties']

    assert_equal 'Marketing name of the property.', props['name']['description']
    refute props['id'].key?('description')
  end

  test "order directions allow nulls placement" do
    s = schema(AccountsController, :index)
    direction = s['$defs']['direction']

    assert_equal 'direction', s['properties']['order']['properties']['name']['$ref'].split('/').last
    assert_equal %w[asc desc], direction['anyOf'][0]['enum']
    assert_equal %w[nulls_first nulls_last], direction['anyOf'][1]['properties']['desc']['enum']
  end

  test "order accepts the shapes StandardAPI sorts by" do
    s = schema(AccountsController, :index)

    assert valid?(s, { 'order' => { 'name' => 'desc' } })
    assert valid?(s, { 'order' => { 'name' => { 'desc' => 'nulls_last' }, 'id' => 'asc' } })
    refute valid?(s, { 'order' => { 'notes' => 'asc' } })
    refute valid?(s, { 'order' => { 'name' => 'sideways' } })
    refute valid?(s, { 'order' => { 'name' => { 'asc' => 'nulls_never' } } })
  end

  test "hidden columns are dropped from orders even when the ACL lists them" do
    s = schema(SchemaInputPhotosController, :index)

    assert_equal %w[id caption], s['properties']['order']['properties'].keys
  end

  # --- include

  test "include is restricted to the ACL's includes" do
    assert_equal %w[properties], schema(AccountsController, :index)['properties']['include']['properties'].keys
    assert_equal %w[account photos], schema(PropertiesController, :show)['properties']['include']['properties'].keys
  end

  test "includes carry the associated table comment" do
    props = schema(PropertiesController, :show)['properties']['include']['properties']

    assert_equal 'An image attached to a property.', props['photos']['description']
    assert_equal 'The account that owns this property.', props['account']['description']

    accounts = schema(AccountsController, :show)['properties']['include']['properties']
    assert_equal 'A real estate asset owned by an account.', accounts['properties']['description']
  end

  test "collection includes accept a limit, singular ones do not" do
    props = schema(PropertiesController, :show)['properties']['include']['properties']
    nested = ->(name) { props[name]['anyOf'].last['properties'].keys }

    assert_equal ['limit'], nested.('photos')
    assert_equal [], nested.('account')
  end

  test "include accepts true or an object" do
    s = schema(PropertiesController, :show)

    assert valid?(s, { 'id' => 1, 'include' => { 'photos' => true, 'account' => {} } })
    assert valid?(s, { 'id' => 1, 'include' => { 'photos' => { 'limit' => 3 } } })
    refute valid?(s, { 'id' => 1, 'include' => { 'nope' => true } })
    refute valid?(s, { 'id' => 1, 'include' => { 'photos' => { 'account' => {} } } })
    refute valid?(s, { 'id' => 1, 'include' => ['photos'] })
  end

  test "include is omitted when the ACL allows none" do
    refute schema(SchemaInputNoIncludesController, :index)['properties'].key?('include')
    refute schema(SchemaInputNoIncludesController, :show)['properties'].key?('include')
  end

  # --- limit, offset, distinct

  test "limit defaults to the configured default and caps at max_limit and resource_limit" do
    limit = schema(AccountsController, :index)['properties']['limit']

    assert_equal 'integer', limit['type']
    assert_equal 1, limit['minimum']
    # resource_limit is 1000; the MCP page-size cap is smaller.
    assert_equal 100, limit['maximum']
    assert_equal 25, limit['default']
  end

  test "max_limit is separate from resource_limit: the smaller of the two is the maximum" do
    StandardMCP.config.max_limit = 500
    assert_equal 500, schema(AccountsController, :index)['properties']['limit']['maximum']

    StandardMCP.config.max_limit = 2000
    assert_equal 1000, schema(AccountsController, :index)['properties']['limit']['maximum']

    StandardMCP.config.max_limit = 5
    assert_equal 5, schema(SchemaInputVaryingController, :index, 'X-Limit' => '8')['properties']['limit']['maximum']
    assert_equal 3, schema(SchemaInputVaryingController, :index, 'X-Limit' => '3')['properties']['limit']['maximum']
  end

  test "max_limit holds the default page size too" do
    StandardMCP.config.max_limit = 10
    StandardMCP.config.default_limit = 50

    limit = schema(AccountsController, :index)['properties']['limit']

    assert_equal 10, limit['maximum']
    assert_equal 10, limit['default']
  end

  test "a nil max_limit leaves the controller's resource_limit alone" do
    StandardMCP.config.max_limit = nil

    assert_equal 1000, schema(AccountsController, :index)['properties']['limit']['maximum']
    # And with no resource_limit either, there is no maximum at all.
    refute schema(SchemaInputPhotosController, :index)['properties']['limit'].key?('maximum')
  end

  test "max_limit caps a controller that has no resource_limit" do
    limit = schema(SchemaInputPhotosController, :index)['properties']['limit']

    assert_equal 100, limit['maximum']
    assert_equal 10, limit['default']
  end

  test "limit default follows the configuration" do
    StandardMCP.config.default_limit = 50

    assert_equal 50, schema(AccountsController, :index)['properties']['limit']['default']
  end

  test "a controller's default_limit wins and a nil resource_limit leaves only max_limit" do
    StandardMCP.config.max_limit = nil
    limit = schema(SchemaInputPhotosController, :index)['properties']['limit']

    assert_equal 10, limit['default']
    refute limit.key?('maximum')
  end

  test "the default is clamped to the maximum" do
    limit = schema(SchemaInputVaryingController, :index, 'X-Limit' => '5')['properties']['limit']

    assert_equal 5, limit['maximum']
    assert_equal 5, limit['default']
  end

  test "limit is not required and is bounded" do
    s = schema(AccountsController, :index)

    refute_includes s['required'], 'limit'
    assert valid?(s, { 'limit' => 100 })
    refute valid?(s, { 'limit' => 101 })
    refute valid?(s, { 'limit' => 0 })
  end

  test "offset is a non-negative integer" do
    s = schema(AccountsController, :index)

    assert_equal({ 'type' => 'integer', 'minimum' => 0 }, s['properties']['offset'].slice('type', 'minimum'))
    assert valid?(s, { 'offset' => 0 })
    refute valid?(s, { 'offset' => -1 })
  end

  test "distinct is a boolean" do
    s = schema(AccountsController, :index)

    assert_equal 'boolean', s['properties']['distinct']['type']
    refute valid?(s, { 'distinct' => 'yes' })
  end

  test "index rejects unknown arguments" do
    refute valid?(schema(AccountsController, :index), { 'page' => 2 })
  end

  # --- show

  test "show requires an integer id described by the model" do
    id = schema(AccountsController, :show)['properties']['id']

    assert_equal 'integer', id['type']
    assert_equal 'ID of the account', id['description']
    assert_equal 'ID of the property', schema(PropertiesController, :show)['properties']['id']['description']
  end

  test "the id type follows the primary key column" do
    Account.stubs(:primary_key).returns('name')

    assert_equal 'string', schema(AccountsController, :show)['properties']['id']['type']
  end

  test "a composite primary key falls back to a string id" do
    Account.stubs(:primary_key).returns(%w[id name])

    assert_equal 'string', schema(AccountsController, :show)['properties']['id']['type']
  end

  test "show validates arguments" do
    s = schema(AccountsController, :show)

    assert valid?(s, { 'id' => 1 })
    refute valid?(s, {})
    refute valid?(s, { 'id' => 'one' })
    refute valid?(s, { 'id' => 1, 'where' => {} })
  end

  # --- calculate

  test "select takes functions over model columns" do
    items = schema(PropertiesController, :calculate)['properties']['select']['items']

    assert_equal %w[minimum maximum average sum count], items['properties'].keys
    assert_equal 1, items['minProperties']
  end

  test "min and max take orderable columns, sum and average numeric ones, count anything and *" do
    props = schema(PropertiesController, :calculate)['properties']['select']['items']['properties']
    plain = ->(f) { f['enum'] || f['anyOf'].first['enum'] }

    assert_includes plain.(props['minimum']), 'built_on'
    assert_includes plain.(props['maximum']), 'name'
    refute_includes plain.(props['maximum']), 'metadata'
    refute_includes plain.(props['maximum']), 'tags'
    refute_includes plain.(props['maximum']), 'available'

    assert_equal %w[id account_id size rent], plain.(props['sum'])
    assert_equal plain.(props['sum']), plain.(props['average'])

    assert_includes plain.(props['count']), '*'
    assert_includes plain.(props['count']), 'name'
    refute_includes plain.(props['sum']), '*'
  end

  test "count, sum and average accept the distinct form" do
    props = schema(PropertiesController, :calculate)['properties']['select']['items']['properties']
    distinct = ->(f) { f['anyOf'].last }

    assert_equal ['distinct'], distinct.(props['count'])['required']
    refute_includes distinct.(props['count'])['properties']['distinct']['enum'], '*'
    assert_equal %w[id account_id size rent], distinct.(props['sum'])['properties']['distinct']['enum']
    refute props['minimum'].key?('anyOf')
  end

  test "group_by is an enum of groupable columns" do
    group_by = schema(PropertiesController, :calculate)['properties']['group_by']

    assert_includes group_by['enum'], 'name'
    assert_includes group_by['enum'], 'kind'
    refute_includes group_by['enum'], 'metadata'
  end

  test "calculate accepts where and rejects bad columns" do
    s = schema(PropertiesController, :calculate)

    assert valid?(s, { 'select' => [{ 'count' => '*' }, { 'maximum' => 'size' }] })
    assert valid?(s, { 'select' => [{ 'maximum' => 'size' }], 'group_by' => 'kind' })
    # StandardAPI can't build a grouped result from more than one aggregate.
    refute valid?(s, { 'select' => [{ 'count' => '*' }, { 'maximum' => 'size' }], 'group_by' => 'kind' })
    refute valid?(s, { 'select' => [{ 'count' => '*', 'maximum' => 'size' }], 'group_by' => 'kind' })
    assert valid?(s, { 'select' => [{ 'count' => { 'distinct' => 'name' } }], 'where' => { 'size' => { 'gt' => 1 } } })
    assert valid?(s, { 'select' => [{ 'count' => '*', 'sum' => 'size' }] })
    refute valid?(s, { 'select' => [] })
    refute valid?(s, {})
    refute valid?(s, { 'select' => [{ 'count' => 'nope' }] })
    refute valid?(s, { 'select' => [{ 'sum' => 'name' }] })
    refute valid?(s, { 'select' => [{ 'median' => 'size' }] })
    refute valid?(s, { 'select' => [{ 'maximum' => '*' }] })
    refute valid?(s, { 'select' => [{ 'count' => '*' }], 'group_by' => 'metadata' })
    refute valid?(s, { 'select' => [{ 'count' => '*' }], 'limit' => 5 })
  end

  test "hidden columns are not aggregatable" do
    s = schema(PhotosController, :calculate)
    props = s['properties']['select']['items']['properties']

    refute_includes props['count']['anyOf'].first['enum'], 'internal_path'
    refute_includes s['properties']['group_by']['enum'], 'internal_path'
    refute_includes props['maximum']['enum'], 'internal_path'
  end

  # --- caller dependence

  test "schemas follow the ACL as resolved for the caller" do
    plain = schema(SchemaInputVaryingController, :index)
    admin = schema(SchemaInputVaryingController, :index, 'X-Admin' => 'true')

    assert_equal %w[id name size created_at], plain['properties']['order']['properties'].keys
    assert_equal %w[id name size created_at rent], admin['properties']['order']['properties'].keys
    assert_equal %w[account], plain['properties']['include']['properties'].keys
    assert_equal %w[account photos], admin['properties']['include']['properties'].keys
    assert_equal %w[account], plain['$defs']['where']['properties'].keys & %w[account photos]
    assert_equal %w[account photos], admin['$defs']['where']['properties'].keys & %w[account photos]
  end

  # --- the mcp gem

  test "every generated schema is accepted by the mcp gem" do
    [AccountsController, PropertiesController, PhotosController, SchemaInputVaryingController].each do |klass|
      %i[index show calculate].each do |action|
        input = MCP::Tool::InputSchema.new(schema(klass, action))
        assert_equal 'object', input.to_h[:type], "#{klass} #{action}"
      end
    end
  end

  test "the schema survives a JSON round trip" do
    s = schema(PropertiesController, :index)

    assert_equal s, JSON.parse(JSON.generate(s))
  end

  # --- round trips through the dispatcher

  def dispatch(klass, action, arguments, headers = {})
    s = schema(klass, action, headers)
    assert valid?(s, arguments), "arguments do not validate against the schema: #{arguments.inspect}"

    env = Rack::MockRequest.env_for('/mcp', headers.transform_keys { |k| "HTTP_#{k.upcase.tr('-', '_')}" })
    StandardMCP::Dispatcher.new(ActionDispatch::Request.new(env)).call(klass, action, arguments)
  end

  test "round trip: operator objects, order and include" do
    small = create(:property, size: 800, kind: 'office', name: 'Small')
    big = create(:property, size: 9000, kind: 'office', name: 'Big')
    create(:property, size: 12000, kind: 'retail', name: 'Retail')
    photo = create(:photo, property: big)

    result = dispatch(PropertiesController, :index, {
      'where' => { 'size' => { 'gte' => 500, 'lt' => 10000 }, 'kind' => { 'eq' => 'office' } },
      'order' => { 'size' => 'desc' },
      'include' => { 'photos' => {} },
      'limit' => 10
    })

    assert_equal 200, result.status
    assert_equal [big.id, small.id], result.json.map { |p| p['id'] }
    assert_equal [photo.id], result.json.first['photos'].map { |p| p['id'] }
  end

  test "round trip: not null, like, in and nulls placement" do
    create(:property, name: 'Alpha Tower', size: nil)
    create(:property, name: 'Beta Plaza', size: 10)
    create(:property, name: 'Gamma Tower', size: 20)

    result = dispatch(PropertiesController, :index, {
      'where' => { 'size' => { 'not' => nil }, 'name' => { 'ilike' => '%tower%' } },
      'order' => { 'size' => { 'asc' => 'nulls_last' } },
      'limit' => 10
    })
    assert_equal ['Gamma Tower'], result.json.map { |p| p['name'] }

    result = dispatch(PropertiesController, :index, {
      'where' => { 'name' => { 'in' => ['Alpha Tower', 'Beta Plaza'] } },
      'order' => { 'size' => { 'asc' => 'nulls_last' } },
      'limit' => 10
    })
    assert_equal ['Beta Plaza', 'Alpha Tower'], result.json.map { |p| p['name'] }
  end

  test "round trip: association filters, arrays and json operators" do
    acme = create(:account, name: 'Acme')
    mine = create(:property, account: acme, tags: %w[a b], metadata: { 'floors' => 3 })
    create(:property, tags: %w[c], metadata: { 'other' => 1 })

    by_account = dispatch(PropertiesController, :index, { 'where' => { 'account' => { 'name' => { 'eq' => 'Acme' } } }, 'limit' => 10 })
    by_tag = dispatch(PropertiesController, :index, { 'where' => { 'tags' => { 'overlaps' => ['b', 'z'] } }, 'limit' => 10 })
    by_key = dispatch(PropertiesController, :index, { 'where' => { 'metadata' => { 'has_key' => 'floors' } }, 'limit' => 10 })

    assert_equal [mine.id], by_account.json.map { |p| p['id'] }
    assert_equal [mine.id], by_tag.json.map { |p| p['id'] }
    assert_equal [mine.id], by_key.json.map { |p| p['id'] }
  end

  test "round trip: enum filters, directly and through an association" do
    acme = create(:account, name: 'Acme')
    other = create(:account, name: 'Other')
    create(:property, account: acme, kind: 'office')
    create(:property, account: other, kind: 'retail')

    direct = dispatch(PropertiesController, :index, { 'where' => { 'kind' => { 'in' => %w[office industrial] } }, 'limit' => 10 })
    nested = dispatch(AccountsController, :index, { 'where' => { 'properties' => { 'kind' => { 'eq' => 'retail' } } }, 'limit' => 10 })

    assert_equal ['office'], direct.json.map { |p| p['kind'] }
    assert_equal [other.id], nested.json.map { |a| a['id'] }
  end

  # Each dropped shorthand has an operator form that selects the same rows.
  test "round trip: operator objects cover what the shorthands did" do
    create(:property, name: 'A', size: nil, kind: 'office', available: true, tags: %w[a b], metadata: { 'x' => 1 })
    create(:property, name: 'B', size: 5, kind: nil, available: false, tags: %w[a], metadata: nil)
    create(:property, name: 'C', size: 7, kind: 'retail', available: nil, tags: nil, metadata: nil)

    names = ->(where) { dispatch(PropertiesController, :index, { 'where' => where, 'limit' => 50 }).json.map { |p| p['name'] }.sort }
    # [explicit form, what the shorthand returned (verified against activerecord-filter)]
    {
      { 'size' => { 'eq' => nil } } => %w[A],
      { 'size' => { 'not' => nil } } => %w[B C],
      { 'size' => { 'in' => [5, 7] } } => %w[B C],
      { 'size' => { 'eq' => 5 } } => %w[B],
      { 'kind' => { 'eq' => nil } } => %w[B],
      { 'kind' => { 'not' => nil } } => %w[A C],
      { 'kind' => { 'eq' => 'office' } } => %w[A],
      { 'kind' => { 'in' => %w[office retail] } } => %w[A C],
      { 'kind' => { 'not_in' => %w[office] } } => %w[C],
      { 'available' => { 'eq' => true } } => %w[A],
      { 'available' => { 'eq' => false } } => %w[B],
      { 'available' => { 'eq' => nil } } => %w[C],
      { 'available' => { 'not' => nil } } => %w[A B],
      { 'tags' => { 'eq' => %w[a] } } => %w[B],
      { 'tags' => { 'eq' => nil } } => %w[C],
      { 'tags' => { 'not' => nil } } => %w[A B],
      { 'tags' => { 'contains' => %w[a] } } => %w[A B],
      { 'tags' => { 'contains' => %w[a b] } } => %w[A],
      { 'metadata' => { 'eq' => nil } } => %w[B C],
      { 'metadata' => { 'not' => nil } } => %w[A],
      { 'name' => { 'eq' => nil } } => [],
      { 'name' => { 'not' => nil } } => %w[A B C]
    }.each do |where, expected|
      assert_equal expected, names.(where), where.inspect
    end
  end

  test "round trip: AND/OR sequences" do
    a = create(:property, size: 1, name: 'A')
    b = create(:property, size: 2, name: 'B')
    create(:property, size: 3, name: 'C')

    result = dispatch(PropertiesController, :index, {
      'where' => [{ 'size' => { 'eq' => 1 } }, 'OR', { 'name' => { 'eq' => 'B' } }],
      'order' => { 'id' => 'asc' },
      'limit' => 10
    })

    assert_equal [a.id, b.id], result.json.map { |p| p['id'] }
  end

  test "round trip: show with a nested include" do
    photo = create(:photo)

    result = dispatch(AccountsController, :show,
      { 'id' => photo.property.account_id, 'include' => { 'properties' => { 'limit' => 5 } } })

    assert_equal 200, result.status
    assert_equal [photo.property_id], result.json['properties'].map { |p| p['id'] }
  end

  test "round trip: calculate with select, distinct and group_by" do
    create(:account, status: 'active')
    create(:account, status: 'active')
    last = create(:account, status: 'suspended')

    result = dispatch(AccountsController, :calculate,
      { 'select' => [{ 'count' => '*' }], 'group_by' => 'status', 'where' => { 'status' => { 'in' => ['active', 'suspended'] } } })

    assert_equal 200, result.status
    assert_equal({ 'active' => 2, 'suspended' => 1 }, result.json)

    result = dispatch(AccountsController, :calculate, { 'select' => [{ 'count' => '*', 'maximum' => 'id' }] })
    assert_equal [[3, last.id]], result.json

    result = dispatch(AccountsController, :calculate, { 'select' => [{ 'count' => { 'distinct' => 'status' } }] })
    assert_equal [2], result.json
  end

end
