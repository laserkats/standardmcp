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

class SchemaWhereTest < ActiveSupport::TestCase

  # Other test files define MCP controllers of their own, which would be
  # among the resources an association is named after.
  setup do
    StandardMCP::Registry.stubs(:controllers).returns([AccountsController, ContactsController, PropertiesController])
  end

  # A controller for +model+ that has a path, as a named one does, and whatever
  # ACL methods the block defines (they win over the test app's ACLs).
  def anonymous(model, &block)
    Class.new(ApplicationController) do
      define_singleton_method(:model) { model }
      define_singleton_method(:controller_path) { model.model_name.plural }
      class_eval(&block)
    end
  end

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

    refute index.key?('$defs')
    refute schema(AccountsController, :calculate).key?('$defs')
    refute_match(/_filter|\$ref/, JSON.generate(index))
  end

  test "the description is two sentences that point at describe_query for the keys" do
    description = where_description(PropertiesController)

    assert_equal 'Filter records with operator objects, e.g. {"size": {"gte": 1000}}; all keys must match. ' \
      'Keys, operators and associations: describe_query {"resource": "properties"} (pass the same where).', description
  end

  test "the description lists no column, operator or association" do
    description = where_description(PropertiesController)

    %w[available built_on listed_at metadata tags rent photos account like ilike].each do |word|
      refute_includes description, word
    end
  end

  test "without the describe tools the description has no pointer" do
    StandardMCP.config.describe_tools = false

    assert_equal 'Filter records with operator objects, e.g. {"size": {"gte": 1000}}; all keys must match.',
      where_description(PropertiesController)
  end

  test "calculate shares the where of index" do
    assert_equal where_property(AccountsController, :index), where_property(AccountsController, :calculate)
  end

  test "limit, offset and the rest are the same in both modes" do
    shallow = schema(PropertiesController)
    StandardMCP.config.input_schema_depth = 'deep'
    deep = schema(PropertiesController)

    assert_equal deep['properties'].slice('limit', 'offset', 'distinct'), shallow['properties'].slice('limit', 'offset', 'distinct')
    assert_equal deep['required'], shallow['required']
  end

  test "deep mode is the typed schema" do
    StandardMCP.config.input_schema_depth = :deep
    deep = schema(PropertiesController)

    assert deep['$defs'].key?('where')
    assert deep['$defs'].key?('integer_filter')
    assert deep.dig('properties', 'where', 'anyOf')
  end

  test "deep mode offers only the keys the ACL wheres permit" do
    StandardMCP.config.input_schema_depth = 'deep'
    klass = anonymous(Property) do
      def property_includes = [:account, :photos]
      def property_wheres = [:id, :name, :account]
    end
    where = schema(klass).dig('$defs', 'where', 'properties')

    assert_equal %w[id name account], where.keys
    # The account's own ACL decides what is offered below it.
    assert_equal %w[id name status notes created_at updated_at], where['account']['properties'].keys
  end

  test "deep mode offers an association only when it is permitted and included" do
    StandardMCP.config.input_schema_depth = 'deep'
    permitted_not_included = anonymous(Property) do
      def property_includes = [:photos]
      def property_wheres = [:id, :account, :photos]
    end
    where = schema(permitted_not_included).dig('$defs', 'where', 'properties')

    assert_equal %w[id photos], where.keys
  end

  test "deep mode narrows the operators to the ones the ACL lists" do
    StandardMCP.config.input_schema_depth = 'deep'
    klass = anonymous(Property) do
      def property_wheres = [{ size: [:gt, :lt] }, { name: [:eq, :in] }, { kind: [:eq] }, :available]
    end
    defs = schema(klass)['$defs']
    where = defs['where']['properties']

    assert_equal %w[gt lt], defs[where['size']['$ref'].delete_prefix('#/$defs/')]['properties'].keys
    assert_equal %w[eq in], defs[where['name']['$ref'].delete_prefix('#/$defs/')]['properties'].keys
    assert_equal %w[eq], where['kind']['properties'].keys
    assert_equal %w[eq not], defs[where['available']['$ref'].delete_prefix('#/$defs/')]['properties'].keys
  end

  test "deep mode accepts a filter_on key without checking its value" do
    StandardMCP.config.input_schema_depth = 'deep'
    Property.filter_on(:search) { |value| Property.all }
    klass = anonymous(Property) do
      def property_wheres = [:id, :search]
    end

    assert_equal({}, schema(klass).dig('$defs', 'where', 'properties', 'search'))
  ensure
    Property.filters.delete('search')
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

  test "an unknown key says which describe call to make" do
    assert_equal ["Unknown filter key 'foo' for properties. Call describe_query {\"resource\": \"properties\"} " \
      'with this where to see the keys you can filter on.'],
      errors(PropertiesController, { 'foo' => { 'eq' => 1 } })
  end

  test "the describe pointer is left out without the describe tools" do
    StandardMCP.config.describe_tools = false

    assert_equal ["Unknown filter key 'foo' for properties."], errors(PropertiesController, { 'foo' => { 'eq' => 1 } })
  end

  test "a column the ACL wheres don't permit is unknown" do
    klass = anonymous(Property) do
      def property_wheres = [:id, :name]
    end

    assert_equal [], errors(klass, { 'name' => { 'eq' => 'HQ' } })
    assert_match(/\AUnknown filter key 'size' for /, errors(klass, { 'size' => { 'gte' => 1 } }).first)
    assert_match(/\AUnknown filter key 'account' for /, errors(klass, { 'account' => { 'name' => { 'eq' => 'a' } } }).first)
  end

  test "a model without ACL wheres can't be filtered on" do
    klass = anonymous(Property) do
      def property_wheres = []
    end

    assert_match(/\AUnknown filter key 'id'/, errors(klass, { 'id' => { 'eq' => 1 } }).first)
  end

  test "a hidden column is unknown" do
    assert_match(/Unknown filter key 'rent'/, errors(SchemaWhereHidingController, { 'rent' => { 'gt' => 1 } }).first)
    assert_match(/Unknown filter key 'photos'/, errors(SchemaWhereHidingController, { 'photos' => { 'format' => { 'eq' => 'jpg' } } }).first)
  end

  test "an association is filterable when the ACL wheres permit it, included or not" do
    klass = anonymous(Property) do
      def property_includes = [:account]
      def property_wheres = [:id, :photos]
    end

    assert_equal [], errors(klass, { 'photos' => { 'id' => { 'eq' => 1 } } })
  end

  test "an unknown key inside an association names that association's resource" do
    assert_equal ["Unknown filter key 'bogus' for accounts (under account). " \
      'Call describe_query {"resource": "accounts"} to see the keys you can filter on.'],
      errors(PropertiesController, { 'account' => { 'bogus' => { 'eq' => 1 } } })
  end

  test "an association no resource serves is named by its table" do
    StandardMCP::Registry.stubs(:controllers).returns([PropertiesController])

    assert_match(/\AUnknown filter key 'bogus' for accounts \(under account\)\. Call describe_query {"resource": "accounts"}/,
      errors(PropertiesController, { 'account' => { 'bogus' => { 'eq' => 1 } } }).first)
  end

  test "hidden columns of associated models are not accepted" do
    klass = anonymous(Account) do
      def property_excludes(_record) = { size: true }
    end

    assert_equal [], errors(klass, { 'properties' => { 'name' => { 'eq' => 'HQ' } } })
    assert_match(/Unknown filter key 'size' for properties \(under properties\)/,
      errors(klass, { 'properties' => { 'size' => { 'gte' => 1 } } }).first)
  end

  test "an association's keys are judged by the associated model's own wheres" do
    # PhotoACL leaves internal_path out of its wheres.
    assert_match(/Unknown filter key 'internal_path' for /,
      errors(PropertiesController, { 'photos' => { 'internal_path' => { 'eq' => 'x' } } }).first)
  end

  test "a key the ACL permits but the model doesn't know is permitted by name" do
    klass = anonymous(Property) do
      def property_wheres = [:id, :anything]
    end

    assert_equal [], errors(klass, { 'anything' => { 'eq' => 1 } })
  end

  test "an association's ids are checked as ids of the associated model" do
    assert_equal [], errors(PropertiesController, { 'photo_ids' => { 'in' => [1] } })
    assert_match(/Invalid value for photo_ids.id: "x"/, errors(PropertiesController, { 'photo_ids' => { 'eq' => 'x' } }).first)
  end

  test "a filter_on key is permitted by name and its value isn't checked" do
    Property.filter_on(:search) { |value| Property.all }
    klass = anonymous(Property) do
      def property_wheres = [:id, :search]
    end

    assert_equal [], errors(klass, { 'search' => 'anything', 'id' => { 'eq' => 1 } })
    assert_equal [], errors(klass, { 'search' => { 'whatever' => [1, 2] } })
  ensure
    Property.filters.delete('search')
  end

  test "an operator the ACL doesn't list for a column is not allowed" do
    klass = anonymous(Property) do
      def property_wheres = [{ name: [:eq, :in] }, { size: [:gt, :not] }, :kind]
    end

    assert_equal [], errors(klass, { 'name' => { 'eq' => 'a', 'in' => ['b'] } })
    assert_equal ["Operator 'ilike' isn't allowed on properties.name (allowed: eq, in)."],
      errors(klass, { 'name' => { 'ilike' => 'a%' } })
    # not is an alias of the neq the ACL lists
    assert_equal [], errors(klass, { 'size' => { 'gt' => 1, 'not' => 2 } })
    assert_equal ["Operator 'lt' isn't allowed on properties.size (allowed: not, gt)."], errors(klass, { 'size' => { 'lt' => 1 } })
    assert_equal [], errors(klass, { 'kind' => { 'in' => ['office'] } })
  end

  test "an operator that is no operator of the type is unsupported, whatever the ACL lists" do
    klass = anonymous(Property) do
      def property_wheres = [{ name: [:eq, :in] }]
    end

    assert_equal ["Unsupported operator 'contains' for name (string); use eq, in"],
      errors(klass, { 'name' => { 'contains' => 'a' } })
  end

  test "a key from the definitions of the where is checked as its type" do
    klass = anonymous(Property) do
      def property_wheres = [:id, :custom_score, :custom_label]

      def schemas_for(model)
        [{ name: 'custom_score', type: 'integer' }, { name: 'custom_label', type: 'string', enum: %w[a b] }]
      end
    end

    assert_equal [], errors(klass, { 'custom_score' => { 'gte' => 1 } })
    assert_equal ['Invalid value for custom_score: "x" (gte expects an integer)'], errors(klass, { 'custom_score' => { 'gte' => 'x' } })
    assert_match(/Unsupported operator 'like' for custom_score \(integer\)/, errors(klass, { 'custom_score' => { 'like' => 'x' } }).first)
    assert_match(/Invalid value for custom_label: "c"/, errors(klass, { 'custom_label' => { 'eq' => 'c' } }).first)
  end

  test "a definition the ACL wheres don't permit is unknown" do
    klass = anonymous(Property) do
      def property_wheres = [:id]

      def schemas_for(model)
        [{ name: 'custom_score', type: 'integer' }]
      end
    end

    assert_match(/\AUnknown filter key 'custom_score'/, errors(klass, { 'custom_score' => { 'gte' => 1 } }).first)
  end

  test "schemas_for runs once per check, on a controller whose params hold the where" do
    where = { 'size' => { 'gte' => 1 }, 'name' => { 'eq' => 'a' }, 'account' => { 'name' => { 'eq' => 'b' } } }
    controller = controller(PropertiesController)
    PropertiesController.any_instance.expects(:schemas_for).once.with(Property).returns([{ name: 'size', type: 'integer' }, { name: 'name', type: 'string' }])

    assert_equal [], StandardMCP::Schema::Where.errors(controller, where)
  end

  test "the where reaches the params the definitions are read with" do
    where = { 'size' => { 'gte' => 1 } }
    seen = nil
    klass = anonymous(Property) do
      define_method(:schemas_for) do |_model|
        seen = params[:where].to_unsafe_h
        [{ name: 'size', type: 'integer' }]
      end
    end

    assert_equal [], errors(klass, where)
    assert_equal where, seen
  end

  test "schemas_for is not asked for a where that has no shape" do
    controller = controller(PropertiesController)
    PropertiesController.any_instance.expects(:schemas_for).never

    assert_match(/must alternate/, StandardMCP::Schema::Where.errors(controller, [{}, {}]).first)
    assert_match(/must be an object of keys, got 5/, StandardMCP::Schema::Where.errors(controller, 5).first)
    assert_equal [], StandardMCP::Schema::Where.errors(controller, nil)
  end

  test "a definition with a type for each group takes the operators of any of them" do
    klass = anonymous(Property) do
      def property_wheres = [:id, :x]

      def schemas_for(model)
        [{ name: 'x', types: { 'A' => 'integer', 'B' => 'string' } }]
      end
    end

    assert_equal [], errors(klass, { 'x' => { 'eq' => 'a' } })
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
    assert_match(/The filter on account must be an object of keys, got 5/, errors(PropertiesController, { 'account' => 5 }).first)
    assert_match(/The filter on photos must be an object/, errors(PropertiesController, { 'photos' => true }).first)
  end

  test "every problem is reported, with the path through associations" do
    messages = errors(PropertiesController, {
      'size' => { 'ilike' => 'a' }, 'foo' => { 'eq' => 1 }, 'account' => { 'name' => { 'gte' => 1 } }
    })

    assert_equal 3, messages.size
    assert_match(/Unsupported operator 'ilike' for size/, messages[0])
    assert_match(/Unknown filter key 'foo'/, messages[1])
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

  # --- order and include

  def order_errors(klass, order)
    StandardMCP::Schema::Where.order_errors(controller(klass), order)
  end

  def include_errors(klass, include)
    StandardMCP::Schema::Where.include_errors(controller(klass), include)
  end

  test "an unknown order key says which describe call to make" do
    assert_equal ["Unknown order key 'rent' for properties. Call describe_query {\"resource\": \"properties\"} " \
      'to see the keys you can order by.'], order_errors(PropertiesController, { 'rent' => 'asc' })
  end

  test "order keys are the ACL orders, in any of the shapes StandardAPI takes" do
    assert_equal [], order_errors(PropertiesController, nil)
    assert_equal [], order_errors(PropertiesController, { 'size' => 'desc', 'name' => { 'asc' => 'nulls_first' } })
    assert_equal [], order_errors(PropertiesController, 'size')
    assert_equal [], order_errors(PropertiesController, ['size', { 'name' => 'asc' }])
    assert_equal [], order_errors(PropertiesController, { 'size.x' => 'asc' }), 'a dotted key is judged by its first segment'
    assert_equal 2, order_errors(PropertiesController, ['rent', { 'tags' => 'asc' }, 'size']).size
  end

  test "an unknown include key says which describe call to make" do
    assert_equal ["Unknown include key 'nope' for properties. Call describe_query {\"resource\": \"properties\"} " \
      'to see the associations you can include.'], include_errors(PropertiesController, { 'nope' => {} })
  end

  test "include keys are the ACL includes; nested ones are left to StandardAPI" do
    assert_equal [], include_errors(PropertiesController, nil)
    assert_equal [], include_errors(PropertiesController, { 'photos' => true, 'account' => { 'anything' => {} } })
    assert_equal [], include_errors(PropertiesController, 'photos')
    assert_equal [], include_errors(PropertiesController, ['photos', { 'account' => {} }])
    assert_equal 1, include_errors(AccountsController, { 'properties' => {}, 'photos' => {} }).size
  end

  test "order and include pointers are left out without the describe tools" do
    StandardMCP.config.describe_tools = false

    assert_equal ["Unknown order key 'rent' for properties."], order_errors(PropertiesController, { 'rent' => 'asc' })
    assert_equal ["Unknown include key 'nope' for properties."], include_errors(PropertiesController, { 'nope' => {} })
  end

  # --- checked definitions (what the describe tools check a where with)

  test "checked_definitions returns the definitions of a where that holds up" do
    definitions = StandardMCP::Schema::Where.checked_definitions(controller(PropertiesController), { 'size' => { 'gte' => 1 } })

    assert_includes definitions.names, 'size'
  end

  test "checked_definitions raises Invalid with the messages of a where that does not" do
    error = assert_raises(StandardMCP::Schema::Where::Invalid) do
      StandardMCP::Schema::Where.checked_definitions(controller(PropertiesController), { 'foo' => { 'eq' => 1 }, 'size' => { 'gte' => 'x' } })
    end

    assert_equal 2, error.errors.size
    assert_equal error.errors.join('; '), error.message
  end

  test "checked_definitions takes no where" do
    assert_includes StandardMCP::Schema::Where.checked_definitions(controller(PropertiesController), nil).names, 'name'
  end

end
