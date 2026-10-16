require 'standard_mcp/test_helper'

# Hides a column of the model and an association, as an ACL excludes would.
class SchemaWhereHidingController < ApplicationController
  def self.model
    Property
  end

  def property_includes
    [:account, :photos]
  end

  def property_excludes(_record)
    { rent: true, photos: true }
  end
end

# Includes two levels deep: shallow lists them all, whatever where_depth says.
class SchemaWhereDeepController < ApplicationController
  def self.model
    Account
  end

  def account_includes
    [{ properties: [:photos] }]
  end
end

class SchemaWhereTest < ActiveSupport::TestCase

  def request_for(headers = {})
    env = Rack::MockRequest.env_for('/mcp', headers.transform_keys { |k| "HTTP_#{k.upcase.tr('-', '_')}" })
    ActionDispatch::Request.new(env)
  end

  def controller(klass)
    StandardMCP::Registry.controller_for(klass, request_for)
  end

  def schema(klass, action = :index)
    StandardMCP::Schema::Input.for(controller(klass), action)
  end

  def where_property(klass, action = :index)
    schema(klass, action).dig('properties', 'where')
  end

  def where_description(klass, action = :index)
    where_property(klass, action)['description']
  end

  def errors(klass, where)
    StandardMCP::Schema::Where.errors(controller(klass), where)
  end

  # --- schema

  test "shallow is the default and where is a loose object" do
    where = where_property(PropertiesController)

    assert_equal %w[description type], where.keys.sort
    assert_equal %w[object array], where['type']
  end

  test "the schema has no filter definitions" do
    index = schema(PropertiesController)

    refute index.key?('$defs') && index['$defs'].key?('where')
    assert_equal ['direction'], index['$defs'].keys
    refute schema(AccountsController, :calculate).key?('$defs')
    refute_match(/_filter|\$ref.*where/, JSON.generate(index.except('$defs')))
  end

  test "the description lists columns with types, comments and enum values" do
    description = where_description(PropertiesController)

    assert_includes description, "\nid (integer)\n"
    assert_includes description, "\nsize (integer): Rentable area in square feet.\n"
    assert_includes description, "\nname (string): Marketing name of the property.\n"
    assert_includes description, "\ndescription (text): Free-form description of the property.\n"
    assert_includes description, "\nkind (office|retail|industrial): Asset class of the property.\n"
    assert_includes description, "\navailable (boolean): Whether the property can be leased now.\n"
    assert_includes description, "\ntags (string[]): Free-form labels.\n"
    assert_includes description, "\nmetadata (jsonb): Unstructured attributes from the source system.\n"
  end

  test "a column without a comment is listed by name and type" do
    assert_includes where_description(AccountsController), "\nnotes (text)\n"
  end

  test "the description teaches the operator object and the AND/OR array" do
    description = where_description(AccountsController)

    assert_includes description, '{"size": {"gte": 1000}}'
    assert_includes description, '{"name": {"eq": null}} for is null'
    assert_includes description, 'alternating filters with "AND" or "OR"'
  end

  test "operators are described for the column types the model has" do
    description = where_description(PropertiesController)

    assert_includes description, 'numbers, dates and strings: eq, not, in, not_in, gt, gte, lt, lte'
    assert_includes description, 'strings also: like'
    assert_includes description, 'ilike'
    assert_includes description, 'ts_match'
    assert_includes description, 'booleans: eq, not'
    assert_includes description, 'enums, uuids and other types: eq, not, in, not_in'
    assert_includes description, 'array columns: eq, not, contains, contained_by, overlaps, excludes'
    assert_includes description, 'json: eq and not (null only), contains, contained_by, has_key'
    refute_includes description, 'geometry'
    refute_includes description, 'ranges'
  end

  test "operators the model has no column for are left out" do
    description = where_description(AccountsController)

    assert_includes description, 'strings also: like'
    refute_includes description, 'booleans'
    refute_includes description, 'array columns'
    refute_includes description, 'json:'
  end

  test "associations are listed with their table comment, without their columns" do
    description = where_description(AccountsController)

    assert_includes description, "\nproperties: A real estate asset owned by an account.\n"
    assert_includes description, '{"properties": {"name": {"eq": "Example"}}}'
    refute_includes description, 'Rentable area'
    refute_includes description, 'size ('
  end

  test "a belongs_to association is described by its foreign key comment" do
    description = where_description(PropertiesController)

    assert_includes description, "\naccount: The account that owns this property.\n"
    assert_includes description, "\nphotos: An image attached to a property.\n"
  end

  test "nested includes are listed by dotted path at any where_depth" do
    StandardMCP.config.where_depth = 0
    description = where_description(SchemaWhereDeepController)

    assert_includes description, "\nproperties: A real estate asset owned by an account.\n"
    assert_includes description, "\nproperties.photos: An image attached to a property.\n"
    assert_includes description, 'properties.photos is {"properties": {"photos": {...}}}'
  end

  test "no association section without associations" do
    klass = Class.new(ApplicationController) do
      def self.model = Account
      def account_includes = []
    end

    refute_includes where_description(klass), 'Associations'
  end

  test "hidden columns and associations are absent" do
    description = where_description(SchemaWhereHidingController)

    refute_includes description, 'rent'
    refute_includes description, 'photos'
    assert_includes description, "\naccount: "
  end

  test "hidden columns of associated models are not offered or accepted" do
    klass = Class.new(ApplicationController) do
      def self.model = Account
      def account_includes = [:properties]
      def property_excludes(_record) = { size: true }
    end

    assert_equal [], errors(klass, { 'properties' => { 'name' => { 'eq' => 'HQ' } } })
    assert_match(/Unknown column 'size' for properties/, errors(klass, { 'properties' => { 'size' => { 'gte' => 1 } } }).first)
  end

  test "calculate shares the where of index" do
    assert_equal where_property(AccountsController, :index), where_property(AccountsController, :calculate)
  end

  test "order, include, limit and the rest are the same in both modes" do
    shallow = schema(PropertiesController)
    StandardMCP.config.input_schema_depth = 'deep'
    deep = schema(PropertiesController)

    assert_equal deep['properties'].except('where'), shallow['properties'].except('where')
    assert_equal deep['$defs']['direction'], shallow['$defs']['direction']
    assert_equal deep['required'], shallow['required']
  end

  test "deep mode is the typed schema" do
    StandardMCP.config.input_schema_depth = :deep
    deep = schema(PropertiesController)

    assert deep['$defs'].key?('where')
    assert deep['$defs'].key?('integer_filter')
    assert deep.dig('properties', 'where', 'anyOf')
  end

  test "the shallow schema is a fraction of the deep one" do
    shallow = JSON.generate(schema(PropertiesController)).size
    StandardMCP.config.input_schema_depth = 'deep'

    assert_operator shallow, :<, JSON.generate(schema(PropertiesController)).size / 2
  end

  # --- errors

  test "valid filters have no errors" do
    [
      {},
      { 'size' => { 'gte' => 1000 } },
      { 'name' => { 'eq' => nil } },
      { 'name' => { 'ilike' => '%hq%', 'not' => 'x' } },
      { 'kind' => { 'in' => %w[office retail] } },
      { 'available' => { 'eq' => true } },
      { 'built_on' => { 'gte' => '2020-01-01' } },
      { 'listed_at' => { 'lt' => '2020-01-01T00:00:00Z' } },
      { 'rent' => { 'gt' => 1.5 } },
      { 'tags' => { 'contains' => ['a'] } },
      { 'metadata' => { 'has_key' => 'a' } },
      { 'name' => { 'ts_match' => ['hq', 'english'] } },
      { 'account' => { 'name' => { 'eq' => 'Acme' } } },
      { 'photos' => { 'format' => { 'eq' => 'jpg' } }, 'size' => { 'gt' => 1 } },
      [{ 'size' => { 'gt' => 1 } }, 'OR', { 'size' => { 'lt' => 0 } }],
      [{ 'size' => { 'gt' => 1 } }]
    ].each do |where|
      assert_equal [], errors(PropertiesController, where), where.inspect
    end
  end

  test "an unknown column names the model's columns and associations" do
    message = errors(PropertiesController, { 'foo' => { 'eq' => 1 } }).first

    assert_match(/\AUnknown column 'foo' for properties \(columns: id, account_id, name, size/, message)
    assert_includes message, 'associations: account, photos'
  end

  test "a hidden column is unknown" do
    assert_match(/Unknown column 'rent'/, errors(SchemaWhereHidingController, { 'rent' => { 'gt' => 1 } }).first)
    assert_match(/Unknown column 'photos'/, errors(SchemaWhereHidingController, { 'photos' => { 'format' => { 'eq' => 'jpg' } } }).first)
  end

  test "an association the controller doesn't include is unknown" do
    klass = Class.new(ApplicationController) do
      def self.model = Property
      def property_includes = [:account]
    end

    assert_match(/Unknown column 'photos' for properties/, errors(klass, { 'photos' => { 'id' => { 'eq' => 1 } } }).first)
  end

  test "an unknown column inside an association names that table" do
    assert_match(/Unknown column 'bogus' for accounts/, errors(PropertiesController, { 'account' => { 'bogus' => { 'eq' => 1 } } }).first)
  end

  test "an operator the column's type doesn't take" do
    assert_match(/\AUnsupported operator 'ilike' for size \(integer\); use eq, not, in, not_in, gt, gte, lt, lte\z/,
      errors(PropertiesController, { 'size' => { 'ilike' => 'a%' } }).first)
    assert_match(/Unsupported operator 'gt' for kind \(office\|retail\|industrial\)/,
      errors(PropertiesController, { 'kind' => { 'gt' => 'a' } }).first)
    assert_match(/Unsupported operator 'contains' for name \(string\)/,
      errors(PropertiesController, { 'name' => { 'contains' => 'a' } }).first)
    assert_match(/Unsupported operator 'bogus' for size/, errors(PropertiesController, { 'size' => { 'bogus' => 1 } }).first)
  end

  test "activerecord-filter aliases and shorthands are not accepted" do
    assert_match(/Unsupported operator 'gteq'/, errors(PropertiesController, { 'size' => { 'gteq' => 1 } }).first)
    assert_match(/size takes an operator object/, errors(PropertiesController, { 'size' => 5 }).first)
    assert_match(/size takes an operator object/, errors(PropertiesController, { 'size' => [1, 2] }).first)
    assert_match(/name takes an operator object/, errors(PropertiesController, { 'name' => nil }).first)
    assert_match(/size takes an operator object/, errors(PropertiesController, { 'size' => {} }).first)
  end

  test "a value of the wrong type" do
    assert_equal ['Invalid value for size: "abc" (gte expects an integer)'],
      errors(PropertiesController, { 'size' => { 'gte' => 'abc' } })
    assert_equal ['Invalid value for size: 1.5 (eq expects an integer or null)'],
      errors(PropertiesController, { 'size' => { 'eq' => 1.5 } })
    assert_equal ['Invalid value for size: 1 (in expects an array of integers)'],
      errors(PropertiesController, { 'size' => { 'in' => 1 } })
    assert_equal ['Invalid value for available: "yes" (eq expects a boolean or null)'],
      errors(PropertiesController, { 'available' => { 'eq' => 'yes' } })
    assert_match(/Invalid value for rent: "x" \(gt expects a number\)/, errors(PropertiesController, { 'rent' => { 'gt' => 'x' } }).first)
  end

  test "a malformed date or datetime" do
    assert_match(/built_on: "garbage" \(gt expects a date \(YYYY-MM-DD\)\)/,
      errors(PropertiesController, { 'built_on' => { 'gt' => 'garbage' } }).first)
    assert_match(/listed_at: "2020-01-01" \(lt expects a datetime \(ISO 8601\)\)/,
      errors(PropertiesController, { 'listed_at' => { 'lt' => '2020-01-01' } }).first)
  end

  test "an enum value outside the list" do
    assert_equal ['Invalid value for kind: "bogus" (eq expects one of office, retail, industrial, null)'],
      errors(PropertiesController, { 'kind' => { 'eq' => 'bogus' } })
    assert_match(/Invalid value for kind: \["bogus"\] \(in expects an array of values from office, retail, industrial\)/,
      errors(PropertiesController, { 'kind' => { 'in' => ['bogus'] } }).first)
  end

  test "values for array, json and text search columns" do
    assert_match(/Invalid value for tags/, errors(PropertiesController, { 'tags' => { 'contains' => 'x' } }).first)
    assert_match(/Invalid value for metadata: 5/, errors(PropertiesController, { 'metadata' => { 'has_key' => 5 } }).first)
    assert_match(/Invalid value for metadata: 5/, errors(PropertiesController, { 'metadata' => { 'eq' => 5 } }).first)
    assert_match(/Invalid value for name: 1/, errors(PropertiesController, { 'name' => { 'ts_match' => 1 } }).first)
  end

  test "an association takes a filter object" do
    assert_match(/The filter on account must be an object of columns, got 5/, errors(PropertiesController, { 'account' => 5 }).first)
    assert_match(/The filter on photos must be an object/, errors(PropertiesController, { 'photos' => true }).first)
  end

  test "every problem is reported, with the path through associations" do
    messages = errors(PropertiesController, {
      'size' => { 'ilike' => 'a' }, 'foo' => { 'eq' => 1 }, 'account' => { 'name' => { 'gte' => 1 } }
    })

    assert_equal 3, messages.size
    assert_match(/Unsupported operator 'ilike' for size/, messages[0])
    assert_match(/Unknown column 'foo'/, messages[1])
    assert_match(/Invalid value for account.name: 1/, messages[2])
  end

  test "an array must alternate filters with AND and OR" do
    [['OR'], [{ 'size' => { 'eq' => 1 } }, { 'size' => { 'eq' => 2 } }], [{ 'size' => { 'eq' => 1 } }, 'OR'], [], ['AND', {}, 'OR']].each do |where|
      assert_match(/must alternate filter objects with "AND" or "OR"/, errors(PropertiesController, where).first, where.inspect)
    end
  end

  test "the filters in an array are checked" do
    messages = errors(PropertiesController, [{ 'size' => { 'gte' => 'a' } }, 'AND', { 'foo' => { 'eq' => 1 } }])

    assert_equal 2, messages.size
  end

  test "a long value is cut in the message" do
    message = errors(PropertiesController, { 'size' => { 'gte' => 'a' * 500 } }).first

    assert_operator message.size, :<, 150
    assert_includes message, '...'
  end

  test "nothing about the caller's mask is consulted" do
    controller = controller(PropertiesController)
    controller.expects(:mask_for).never

    StandardMCP::Schema::Where.errors(controller, { 'size' => { 'gte' => 'abc' } })
  end

end
