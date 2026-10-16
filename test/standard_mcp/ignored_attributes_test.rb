require 'standard_mcp/test_helper'

class IgnoredNestedController < ApplicationController
  def self.model
    Property
  end

  def nested_property_attributes
    [:photos, :account]
  end
end

class IgnoredAttributesTest < ActiveSupport::TestCase

  def controller(klass = PropertiesController)
    request = ActionDispatch::Request.new(Rack::MockRequest.env_for('/mcp'))
    StandardMCP::Registry.controller_for(klass, request)
  end

  def ignored(submitted, record = nil, klass = PropertiesController)
    StandardMCP::IgnoredAttributes.for(controller(klass), klass.model, record, submitted)
  end

  test "keys the ACL permits, and the nested association and its ids, are not ignored" do
    assert_empty ignored({ 'name' => 'x', 'size' => 1, 'account_id' => 1, 'photos' => [], 'photo_ids' => [1] })
  end

  test "other keys are reported" do
    assert_equal %w[created_at nope], ignored({ 'name' => 'x', 'created_at' => 'y', 'nope' => 1 })
  end

  test "nested keys are reported with the path of the association" do
    assert_equal %w[photos.internal_path], ignored({ 'photos' => [{ 'id' => 1, 'caption' => 'a', 'internal_path' => 'x' }, { 'format' => 'png' }] })
    assert_equal %w[photos.nope photos.created_at],
      ignored({ 'photos' => [{ 'nope' => 1 }, { 'created_at' => 'x' }] })
  end

  test "the same key is reported once" do
    assert_equal %w[photos.nope], ignored({ 'photos' => [{ 'nope' => 1 }, { 'nope' => 2 }] })
  end

  test "values that are not records are left to StandardAPI" do
    assert_empty ignored({ 'photos' => 'x' })
    assert_empty ignored({ 'photos' => ['x', nil] })
    assert_empty ignored('x')
    assert_empty ignored(nil)
  end

  test "a nested belongs_to or has_one is judged like a collection" do
    ignored = ignored({ 'account' => { 'id' => 1, 'name' => 'x', 'nope' => 1 }, 'account_id' => 1, 'photos' => [] },
      nil, IgnoredNestedController)

    assert_equal %w[account.nope], ignored
  end

  test "the ACL is asked about the record given" do
    seen = []
    PropertiesController.any_instance.stubs(:model_attributes).with { |model, record| seen << [model, record]; true }.returns([:name])
    property = Property.new

    ignored({ 'name' => 'x', 'size' => 1 }, property)

    assert_equal [[Property, property]], seen
  end

  test "an ACL that fails yields nothing rather than failing the write" do
    PropertiesController.any_instance.stubs(:model_attributes).raises(RuntimeError)

    assert_empty ignored({ 'name' => 'x', 'nope' => 1 })
  end

end
