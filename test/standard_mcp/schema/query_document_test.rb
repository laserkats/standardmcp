require 'standard_mcp/test_helper'

# Narrow ACL: operators listed for some keys, a filter_on key, a key the model
# doesn't know, associations, and an association to order through.
class QueryDocNarrowController < ApplicationController
  def self.model
    Property
  end

  def property_wheres
    [{ name: [:eq, :in] }, { size: [:gt, :not] }, :kind, :account, :photos, :search, :anything, :available]
  end

  def property_orders
    [:id, :size, :account]
  end

  def property_includes
    [:account, :photos]
  end
end

# Definitions that depend on the where: records of a group carry attributes the
# others don't.
class QueryDocGroupedController < ApplicationController
  def self.model
    Property
  end

  def property_wheres
    [:id, :x, :y, :z]
  end

  def property_orders
    [:id, :x]
  end

  def model_attribute_definitions(model, where)
    ids = where.is_a?(Hash) && where.dig('id', 'in')
    return [{ name: 'id', type: 'integer' }, { name: 'z', type: 'boolean', comment: 'Only this one.' }] unless ids

    {
      'Group A' => [{ name: 'id', type: 'integer' }, { name: 'x', type: 'integer' }, { name: 'y', type: 'string', comment: 'A y.' }],
      'Group B' => [{ name: 'id', type: 'integer' }, { name: 'x', type: 'string' }, { name: 'z', type: 'boolean' }]
    }
  end
end

# The ACL permits a definition and a column the definitions leave out.
class QueryDocPartialController < ApplicationController
  def self.model
    Property
  end

  def property_wheres
    [:id, :size, :custom]
  end

  def model_attribute_definitions(model, where)
    [{ name: 'id', type: 'integer' }, { name: 'custom', type: 'datetime', comment: 'Custom stamp.' }, { name: 'hidden_by_acl', type: 'string' }]
  end
end

class SchemaQueryDocumentTest < ActiveSupport::TestCase

  LINKS = { Account => 'accounts', Photo => 'gallery', Property => 'properties' }.freeze
  READS = %i[index show calculate].freeze

  setup do
    Property.filter_on(:search) { |value| Property.all }
  end

  teardown do
    Property.filters.delete('search')
  end

  def request_for(headers = {})
    env = Rack::MockRequest.env_for('/mcp', headers.transform_keys { |k| "HTTP_#{k.upcase.tr('-', '_')}" })
    ActionDispatch::Request.new(env)
  end

  def doc(klass = PropertiesController, actions: READS, where: nil, links: LINKS, headers: {})
    controller = StandardMCP::Registry.controller_for(klass, request_for(headers))
    StandardMCP::Schema::QueryDocument.for(controller, name: 'properties', actions: actions, links: links, where: where)
  end

  def keys(document)
    document['where']['keys'].map { |key| key['name'] }
  end

  def key(document, name)
    document['where']['keys'].find { |k| k['name'] == name } or flunk "no where key #{name}"
  end

  # --- header

  test "the document names the resource and carries the table comment" do
    document = doc

    assert_equal 'properties', document['resource']
    assert_equal 'A real estate asset owned by an account.', document['description']
    refute document.key?('groups')
  end

  test "no false, nil or empty value anywhere" do
    check = ->(value, path) do
      case value
      when Hash then value.each { |k, v| check.(v, "#{path}.#{k}") }
      when Array
        refute_empty value, "#{path} is empty"
        value.each_with_index { |v, i| check.(v, "#{path}[#{i}]") }
      else refute_includes [false, nil, ''], value, "#{path} is #{value.inspect}"
      end
    end

    [PropertiesController, AccountsController, QueryDocNarrowController, QueryDocGroupedController].each do |klass|
      check.(doc(klass), klass.name)
      check.(doc(klass, where: { 'id' => { 'in' => [1, 2] } }), "#{klass.name} grouped") if klass == QueryDocGroupedController
    end
  end

  # --- where keys

  test "the keys are the attributes the ACL wheres permit, with type, comment and enum" do
    document = doc

    assert_equal %w[id account_id name size description kind available built_on listed_at rent tags metadata created_at updated_at],
      keys(document)
    assert_equal({ 'name' => 'size', 'type' => 'integer', 'description' => 'Rentable area in square feet.' }, key(document, 'size'))
    assert_equal({ 'name' => 'id', 'type' => 'integer' }, key(document, 'id'))
    assert_equal({ 'name' => 'kind', 'type' => 'string', 'enum' => %w[office retail industrial], 'description' => 'Asset class of the property.' },
      key(document, 'kind'))
    assert_equal 'string[]', key(document, 'tags')['type']
    assert_equal 'jsonb', key(document, 'metadata')['type']
    assert_equal 'datetime', key(document, 'listed_at')['type']
    assert_equal 'decimal', key(document, 'rent')['type']
  end

  test "a column the ACL wheres don't permit is not listed" do
    klass = Class.new(QueryDocNarrowController) { def property_wheres = [:id, :name] }
    document = doc(klass)

    assert_equal %w[id name], keys(document)
    refute_includes JSON.generate(document['where']), 'Rentable area'
  end

  test "hidden columns are absent from where and order" do
    klass = Class.new(ApplicationController) do
      def self.model = Photo
      def photo_orders = [:id, :caption, :internal_path]
      def photo_wheres = [:id, :caption, :internal_path]
      def photo_excludes(_record) = { internal_path: true }
    end
    controller = StandardMCP::Registry.controller_for(klass, request_for)
    document = StandardMCP::Schema::QueryDocument.for(controller, name: 'photos', actions: [:index])

    assert_equal %w[id caption], keys(document)
    assert_equal %w[id caption], document['order']['keys'].map { |k| k['name'] }
    refute_includes JSON.generate(document), 'internal_path'
  end

  test "a filter_on key is a filter, with no type" do
    assert_equal({ 'name' => 'search', 'kind' => 'filter' }, key(doc(QueryDocNarrowController), 'search'))
  end

  test "a key the model doesn't know is listed by name" do
    assert_equal({ 'name' => 'anything' }, key(doc(QueryDocNarrowController), 'anything'))
  end

  test "an association is not a key but is in associations, by name and resource" do
    document = doc(QueryDocNarrowController)

    refute_includes keys(document), 'account'
    assert_equal [{ 'name' => 'account', 'resource' => 'accounts' }, { 'name' => 'photos', 'resource' => 'gallery' }],
      document['where']['associations']
  end

  test "an association no exposed resource serves is only a name" do
    assert_equal [{ 'name' => 'account' }, { 'name' => 'photos' }], doc(QueryDocNarrowController, links: {})['where']['associations']
  end

  test "an association carries none of the associated model's columns" do
    json = JSON.generate(doc(QueryDocNarrowController)['where']['associations'])

    %w[status notes caption format internal_path].each { |name| refute_includes json, name }
    assert_equal %w[name resource], doc['where']['associations'].first.keys
  end

  test "an association permitted by wheres is listed whether or not it can be included" do
    klass = Class.new(QueryDocNarrowController) do
      def property_wheres = [:id, :photos]
      def property_includes = [:account]
    end

    assert_equal [{ 'name' => 'photos', 'resource' => 'gallery' }], doc(klass)['where']['associations']
  end

  # --- operators

  test "operators are given once per type, for the types the keys have" do
    operators = doc['where']['operators']

    assert_equal %w[integer string text enum boolean date datetime decimal string[] jsonb], operators.keys
    assert_equal %w[eq not in not_in gt gte lt lte], operators['integer']
    assert_equal operators['integer'], operators['decimal']
    assert_equal operators['integer'], operators['datetime']
    assert_equal %w[eq not in not_in gt gte lt lte like ilike ts_match], operators['string']
    assert_equal %w[eq not], operators['boolean']
    assert_equal %w[eq not contains contained_by overlaps excludes], operators['string[]']
    assert_equal %w[eq not contains contained_by has_key has_keys has_any_key], operators['jsonb']
  end

  test "an enum takes equality and membership only" do
    assert_equal %w[eq not in not_in], doc['where']['operators']['enum']
    refute key(doc, 'kind').key?('operators')
  end

  test "only the types present are listed" do
    operators = doc(AccountsController)['where']['operators']

    assert_equal %w[integer string text datetime], operators.keys
    refute operators.key?('boolean')
    refute operators.key?('jsonb')
  end

  test "a key doesn't carry operators unless the ACL lists them" do
    document = doc

    document['where']['keys'].each { |k| refute k.key?('operators'), k['name'] }
  end

  test "a key whose ACL entry lists operators carries them, in the names of its type" do
    document = doc(QueryDocNarrowController)

    assert_equal %w[eq in], key(document, 'name')['operators']
    # not is allowed by the neq the ACL lists
    assert_equal %w[not gt], key(document, 'size')['operators']
    refute key(document, 'kind').key?('operators')
  end

  test "types whose keys all have their own list are not in the operator table" do
    operators = doc(QueryDocNarrowController)['where']['operators']

    refute operators.key?('integer'), 'size lists its own and id is not permitted'
    assert_equal %w[enum boolean], operators.keys
  end

  test "the rules explain the operator object, null, AND/OR, enums, nesting and where to look next" do
    rules = doc['where']['rules']

    assert_includes rules, '{"size": {"gte": 1000}}'
    assert_includes rules, '{"name": {"eq": null}} for is null'
    assert_includes rules, '{"name": {"not": null}} for is not null'
    assert_includes rules, 'alternating filters with "AND" or "OR"'
    assert_includes rules, 'nest them under its name, e.g. {"account": {...}}'
    assert_includes rules, 'call describe_query on its resource'
  end

  test "the rules explain the operators of the types listed" do
    assert_includes doc['where']['rules'], 'ts_match takes Postgres to_tsquery syntax'
    assert_includes doc['where']['rules'], 'Array operators take lists.'
    assert_includes doc['where']['rules'], 'For json, eq and not take null only.'

    rules = doc(Class.new(QueryDocNarrowController) { def property_wheres = [:id, :size] })['where']['rules']
    refute_includes rules, 'ts_match'
    refute_includes rules, 'json'
    refute_includes rules, 'nest them under'
  end

  # --- order

  test "order keys are the ACL orders, with their types" do
    order = doc['order']

    assert_equal [{ 'name' => 'id', 'type' => 'integer' }, { 'name' => 'name', 'type' => 'string' },
      { 'name' => 'size', 'type' => 'integer' }, { 'name' => 'created_at', 'type' => 'datetime' }], order['keys']
    assert_includes order['rules'], 'asc or desc'
    assert_includes order['rules'], '{"asc": "nulls_first"}'
    refute order.key?('associations')
  end

  test "an association in the ACL orders is named with its resource" do
    order = doc(QueryDocNarrowController)['order']

    assert_equal %w[id size], order['keys'].map { |k| k['name'] }
    assert_equal [{ 'name' => 'account', 'resource' => 'accounts' }], order['associations']
    assert_includes order['rules'], 'To order through an association, e.g. {"account": {...}}'
  end

  # --- include

  test "include lists the associations the ACL includes, with kind and resource" do
    assert_equal [{ 'name' => 'account', 'kind' => 'belongs_to', 'resource' => 'accounts' },
      { 'name' => 'photos', 'kind' => 'has_many', 'resource' => 'gallery' }], doc['include']
    assert_equal [{ 'name' => 'properties', 'kind' => 'has_many', 'resource' => 'properties' }], doc(AccountsController)['include']
  end

  test "include names no column of the associated model" do
    assert_equal %w[name kind resource], doc['include'].first.keys
  end

  test "an association no exposed resource serves has no resource in include" do
    assert_equal [{ 'name' => 'account', 'kind' => 'belongs_to' }, { 'name' => 'photos', 'kind' => 'has_many' }], doc(links: {})['include']
  end

  test "include is absent when the ACL includes nothing" do
    klass = Class.new(QueryDocNarrowController) { def property_includes = [] }

    refute doc(klass).key?('include')
  end

  test "an association hidden by excludes is not included" do
    klass = Class.new(QueryDocNarrowController) { def property_excludes(_record) = { photos: true } }

    assert_equal %w[account], doc(klass)['include'].map { |a| a['name'] }
  end

  # --- sections follow the caller's actions

  test "a reader of index gets where, order and include" do
    document = doc(actions: %i[index])

    assert document.key?('where')
    assert document.key?('order')
    assert document.key?('include')
  end

  test "calculate alone gets where only" do
    document = doc(actions: %i[calculate])

    assert document.key?('where')
    refute document.key?('order')
    refute document.key?('include')
  end

  test "show alone gets include only" do
    document = doc(actions: %i[show])

    refute document.key?('where')
    refute document.key?('order')
    assert document.key?('include')
  end

  test "create and update get include only" do
    %i[create update].each do |action|
      document = doc(actions: [action])

      assert_equal %w[resource description include], document.keys, action.to_s
    end
  end

  test "a caller that may only destroy has nothing to describe but the resource" do
    assert_equal %w[resource description], doc(actions: %i[destroy]).keys
  end

  test "index without calculate still gets where" do
    refute doc(actions: %i[calculate])['where'].empty?
    assert doc(actions: %i[index]).key?('where')
  end

  # --- definitions that depend on the where

  test "the hook is asked once, for the where the agent will use" do
    where = { 'id' => { 'in' => [1, 2] } }
    klass = Class.new(QueryDocGroupedController) { def property_wheres = [:x] }
    controller = StandardMCP::Registry.controller_for(klass, request_for)
    controller.expects(:model_attribute_definitions).once.with(Property, where).returns([{ name: 'x', type: 'integer' }])

    document = StandardMCP::Schema::QueryDocument.for(controller, name: 'properties', actions: READS, where: where)

    assert_equal %w[x], keys(document)
  end

  test "a document built from definitions the caller already has asks no more" do
    klass = Class.new(QueryDocGroupedController) { def property_wheres = [:x] }
    controller = StandardMCP::Registry.controller_for(klass, request_for)
    controller.expects(:model_attribute_definitions).never
    definitions = StandardMCP::Schema::Definitions::Result.new(entries: [{ 'name' => 'x', 'type' => 'integer' }], groups: nil)

    document = StandardMCP::Schema::QueryDocument.for(controller, name: 'properties', actions: READS, definitions: definitions)

    assert_equal %w[x], keys(document)
  end

  test "without a where the definitions are those of no where" do
    document = doc(QueryDocGroupedController)

    # x and y are permitted by the ACL but not defined for no where: only names.
    assert_equal %w[id z x y], keys(document)
    assert_equal({ 'name' => 'z', 'type' => 'boolean', 'description' => 'Only this one.' }, key(document, 'z'))
    assert_equal({ 'name' => 'x' }, key(document, 'x'))
    refute document.key?('groups')
  end

  test "a where over several groups returns every key, labelled" do
    document = doc(QueryDocGroupedController, where: { 'id' => { 'in' => [1, 2] } })

    assert_equal ['Group A', 'Group B'], document['groups']
    assert_equal %w[id x y z], keys(document)
    assert_equal({ 'name' => 'id', 'type' => 'integer' }, key(document, 'id'))
    assert_equal({ 'name' => 'x', 'types' => { 'Group A' => 'integer', 'Group B' => 'string' } }, key(document, 'x'))
    assert_equal({ 'name' => 'y', 'type' => 'string', 'description' => 'A y.', 'only_in' => ['Group A'] }, key(document, 'y'))
    assert_equal({ 'name' => 'z', 'type' => 'boolean', 'only_in' => ['Group B'] }, key(document, 'z'))
  end

  test "keys with differing types list the operators of each type" do
    operators = doc(QueryDocGroupedController, where: { 'id' => { 'in' => [1, 2] } })['where']['operators']

    assert_equal %w[integer string boolean], operators.keys
    assert_includes operators['string'], 'like'
    assert_includes operators['integer'], 'gt'
  end

  test "the order keys of grouped definitions are labelled too" do
    order = doc(QueryDocGroupedController, where: { 'id' => { 'in' => [1, 2] } })['order']

    assert_equal [{ 'name' => 'id', 'type' => 'integer' },
      { 'name' => 'x', 'types' => { 'Group A' => 'integer', 'Group B' => 'string' } }], order['keys']
  end

  test "a definition the ACL doesn't permit is not a key" do
    assert_equal %w[id custom size], keys(doc(QueryDocPartialController))
    refute_includes JSON.generate(doc(QueryDocPartialController)), 'hidden_by_acl'
  end

  test "a permitted column the definitions leave out is still a key, typed from the column" do
    assert_equal({ 'name' => 'size', 'type' => 'integer', 'description' => 'Rentable area in square feet.' },
      key(doc(QueryDocPartialController), 'size'))
    assert_equal({ 'name' => 'custom', 'type' => 'datetime', 'description' => 'Custom stamp.' }, key(doc(QueryDocPartialController), 'custom'))
  end

end
