require 'standard_mcp/test_helper'

# schemas_for returns whatever the test sets in .definitions, which is called
# with the where the controller's params carry (nil when it has none).
class SchemaDefinitionsController < ApplicationController
  def self.model
    Property
  end

  cattr_accessor :definitions

  def schemas_for(model)
    return super if self.class.definitions.nil?

    where = params[:where]
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

  test "an Array becomes String-keyed entries" do
    result = definitions([{ name: :size, type: :integer, comment: 'Area', null: true }, { 'name' => 'name', 'type' => 'string' }])

    assert_equal [{ 'name' => 'size', 'type' => 'integer', 'comment' => 'Area', 'null' => true }, { 'name' => 'name', 'type' => 'string' }],
      result.entries
    assert_equal %w[size name], result.names
    assert_equal 'Area', result.find('size')['comment']
    assert_equal 'Area', result.find(:size)['comment']
    assert_nil result.find('rent')
  end

  test "hidden attributes are dropped" do
    result = definitions([{ name: 'size' }, { name: 'rent' }])

    assert_equal %w[size], result.names
  end

  test "schemas_for is asked for the model, on a controller whose params hold the where" do
    where = { 'size' => { 'gte' => 1 } }
    seen = nil
    result = definitions(->(model, passed) { seen = [model, passed.to_unsafe_h]; [] }, where)

    assert_equal [Property, where], seen
    assert_empty result.entries
  end

  test "an array where reaches the params as given" do
    where = [{ 'size' => { 'gte' => 1 } }, 'OR', { 'name' => 'x' }]
    seen = nil
    definitions(->(_, passed) { seen = passed.map { |part| part.respond_to?(:to_unsafe_h) ? part.to_unsafe_h : part }; [] }, where)

    assert_equal where, seen
  end

  test "the params have no where when the agent passed none" do
    seen = :unset
    definitions(->(_, passed) { seen = passed; [] })

    assert_nil seen
  end

  test "one where's definitions don't reach another's" do
    SchemaDefinitionsController.definitions = ->(_, where) { where ? [{ name: 'extra' }] : [{ name: 'size' }] }
    shared = controller

    assert_equal %w[extra], StandardMCP::Schema::Definitions.for(shared, Property, { 'a' => 1 }).names
    assert_equal %w[size], StandardMCP::Schema::Definitions.for(shared, Property, nil).names
    assert_equal %w[extra], StandardMCP::Schema::Definitions.for(shared, Property, { 'a' => 1 }).names
  end

  test "only_in and types are kept for describe_query to pass through" do
    result = definitions([{ name: 'x', type: 'integer', only_in: %w[A], types: { 'A' => 'integer' } }])

    assert_equal %w[A], result.find('x')['only_in']
    assert_equal({ 'A' => 'integer' }, result.find('x')['types'])
  end

  test "an empty list is no definitions" do
    assert_empty definitions([]).entries
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
