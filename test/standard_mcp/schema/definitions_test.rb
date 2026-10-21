require 'standard_mcp/test_helper'

# The hook returns whatever the test sets in @definitions.
class SchemaDefinitionsController < ApplicationController
  def self.model
    Property
  end

  cattr_accessor :definitions

  def model_attribute_definitions(model, where)
    self.class.definitions.respond_to?(:call) ? self.class.definitions.call(model, where) : self.class.definitions
  end

  def property_excludes(_record)
    { rent: true }
  end
end

class SchemaDefinitionsTest < ActiveSupport::TestCase

  teardown { SchemaDefinitionsController.definitions = nil }

  def controller
    request = ActionDispatch::Request.new(Rack::MockRequest.env_for('/mcp'))
    StandardMCP::Registry.controller_for(SchemaDefinitionsController, request)
  end

  def definitions(returned, where = nil)
    SchemaDefinitionsController.definitions = returned
    StandardMCP::Schema::Definitions.for(controller, Property, where)
  end

  test "an Array becomes String-keyed entries and has no groups" do
    result = definitions([{ name: :size, type: :integer, comment: 'Area', null: true }, { 'name' => 'name', 'type' => 'string' }])

    assert_equal [{ 'name' => 'size', 'type' => 'integer', 'comment' => 'Area', 'null' => true }, { 'name' => 'name', 'type' => 'string' }],
      result.entries
    assert_nil result.groups
    refute result.grouped?
    assert_equal %w[size name], result.names
    assert_equal 'Area', result.find('size')['comment']
    assert_equal 'Area', result.find(:size)['comment']
    assert_nil result.find('rent')
  end

  test "hidden attributes are dropped" do
    result = definitions([{ name: 'size' }, { name: 'rent' }])

    assert_equal %w[size], result.names
  end

  test "the hook is given the model and the where as passed" do
    where = { 'size' => { 'gte' => 1 } }
    seen = nil
    result = definitions(->(model, passed) { seen = [model, passed]; [] }, where)

    assert_equal [Property, where], seen
    assert_empty result.entries
  end

  test "the where is nil when the agent passed none" do
    seen = :unset
    definitions(->(_, passed) { seen = passed; [] })

    assert_nil seen
  end

  test "a Hash of groups is merged, one entry per name in first-seen order" do
    result = definitions(
      'A' => [{ name: 'size', type: 'integer', comment: 'From A' }, { name: 'a_only', type: 'string' }],
      'B' => [{ name: 'size', type: 'integer', comment: 'From B' }, { name: 'b_only', type: 'string' }]
    )

    assert_equal %w[A B], result.groups
    assert result.grouped?
    assert_equal %w[size a_only b_only], result.names
  end

  test "a name missing from some groups lists the groups that have it" do
    result = definitions('A' => [{ name: 'size', type: 'integer' }, { name: 'x', type: 'string' }],
      'B' => [{ name: 'size', type: 'integer' }], 'C' => [{ name: 'x', type: 'string' }, { name: 'size', type: 'integer' }])

    assert_nil result.find('size')['only_in']
    assert_equal %w[A C], result.find('x')['only_in']
  end

  test "a type that differs between groups is replaced by a type for each group" do
    result = definitions('A' => [{ name: 'x', type: 'integer' }], 'B' => [{ name: 'x', type: 'string' }])
    entry = result.find('x')

    refute entry.key?('type')
    assert_equal({ 'A' => 'integer', 'B' => 'string' }, entry['types'])
    refute entry.key?('only_in')
  end

  test "an array flag that differs counts as a different type" do
    result = definitions('A' => [{ name: 'x', type: 'string', array: true }], 'B' => [{ name: 'x', type: 'string', array: false }])
    entry = result.find('x')

    assert_equal({ 'A' => 'string[]', 'B' => 'string' }, entry['types'])
    refute entry.key?('type')
    refute entry.key?('array')
  end

  test "the same type in every group stays one type" do
    result = definitions('A' => [{ name: 'x', type: 'string', array: true }], 'B' => [{ name: 'x', type: 'string', array: true }])

    assert_equal 'string', result.find('x')['type']
    assert_equal true, result.find('x')['array']
    refute result.find('x').key?('types')
  end

  test "a name in only some groups with different types has both" do
    result = definitions('A' => [{ name: 'x', type: 'integer' }], 'B' => [{ name: 'x', type: 'string' }], 'C' => [])

    assert_equal %w[A B], result.find('x')['only_in']
    assert_equal({ 'A' => 'integer', 'B' => 'string' }, result.find('x')['types'])
  end

  test "the other fields come from the first group that has the name" do
    result = definitions('A' => [{ name: 'x', type: 'integer', comment: 'First', withheld: true }],
      'B' => [{ name: 'x', type: 'integer', comment: 'Second', null: true }])

    assert_equal 'First', result.find('x')['comment']
    assert_equal true, result.find('x')['withheld']
    refute result.find('x').key?('null')
  end

  test "hidden attributes are dropped from every group" do
    result = definitions('A' => [{ name: 'rent' }, { name: 'size' }], 'B' => [{ name: 'rent' }])

    assert_equal %w[size], result.names
    assert_equal %w[A B], result.groups
    assert_equal %w[A], result.find('size')['only_in']
  end

  test "group labels are Strings" do
    assert_equal %w[1 two], definitions(1 => [{ name: 'size' }], :two => [{ name: 'size' }]).groups
  end

  test "an empty Hash is grouped with no groups, and nil is no definitions" do
    assert_equal [], definitions({}).groups
    assert_empty definitions({}).entries
    assert_empty definitions(nil).entries
  end

  test "an entry without a name is dropped" do
    assert_equal %w[size], definitions([{ type: 'integer' }, { name: '' }, { name: 'size' }]).names
  end

  test "the type label shows an array" do
    assert_equal 'integer', StandardMCP::Schema::Definitions.type_label({ 'type' => 'integer' })
    assert_equal 'integer[]', StandardMCP::Schema::Definitions.type_label({ 'type' => 'integer', 'array' => true })
    assert_nil StandardMCP::Schema::Definitions.type_label({ 'name' => 'x' })
  end

  test "by default the entries are StandardAPI's definitions of the model" do
    request = ActionDispatch::Request.new(Rack::MockRequest.env_for('/mcp'))
    result = StandardMCP::Schema::Definitions.for(StandardMCP::Registry.controller_for(PropertiesController, request), Property, nil)

    assert_equal Property.attribute_names, result.names
    assert_equal 'Rentable area in square feet.', result.find('size')['comment']
    assert_equal %w[office retail industrial], result.find('kind')['enum']
  end

end
