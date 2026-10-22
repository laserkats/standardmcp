require 'standard_mcp/test_helper'

# Orders and includes vary by caller, as the controller sees the request.
class DescriptionVaryingController < ApplicationController
  def self.model
    Property
  end

  def property_orders
    request.headers['X-Admin'] == 'true' ? super + [:rent] : super
  end

  def property_includes
    request.headers['X-Admin'] == 'true' ? super : [:account]
  end
end

class DescriptionTest < ActiveSupport::TestCase

  def request_for(headers = {})
    env = Rack::MockRequest.env_for('/mcp', headers.transform_keys { |k| "HTTP_#{k.upcase.tr('-', '_')}" })
    ActionDispatch::Request.new(env)
  end

  def describe(klass, action, headers = {})
    StandardMCP::Description.for(StandardMCP::Registry.controller_for(klass, request_for(headers)), action)
  end

  # --- for

  test "index: action sentence, table comment, then guidance" do
    description = describe(PropertiesController, :index)

    assert_equal 'List properties. A real estate asset owned by an account. ' \
      'Filter with where; page with limit and offset, using next_offset from the result.', description
  end

  test "show: action sentence and table comment" do
    assert_equal 'Get one account by id. A customer organization that owns properties.', describe(AccountsController, :show)
  end

  test "calculate: action sentence, table comment, guidance" do
    assert_equal 'Aggregate accounts (count, sum, min, max, average), optionally grouped. ' \
      'A customer organization that owns properties. Filter with where; group with group_by.',
      describe(AccountsController, :calculate)
  end

  test "the guidance does not repeat the schema" do
    description = describe(PropertiesController, :index)

    refute_match(/integer|minimum|maximum|boolean/, description)
  end

  test "no description lists includes, orders or required attributes" do
    %i[index show create update calculate].each do |action|
      description = describe(PropertiesController, action)

      refute_match(/Includes:|Order by:|Required:/, description, action.to_s)
      %w[photos created_at].each { |name| refute_includes description, name, "#{action} names #{name}" }
    end
  end

  test "descriptions don't change with the caller's orders and includes" do
    assert_equal describe(DescriptionVaryingController, :index), describe(DescriptionVaryingController, :index, 'X-Admin' => 'true')
    assert_equal describe(DescriptionVaryingController, :show), describe(DescriptionVaryingController, :show, 'X-Admin' => 'true')
  end

  test "create: ignored attributes, and where the writable and required ones are" do
    assert_equal 'Create one property. A real estate asset owned by an account. ' \
      "#{StandardMCP::Description::IGNORED} " \
      'Writable and required attributes: describe_attributes {"resource": "properties"}.', describe(PropertiesController, :create)
    assert_equal 'Create one contact. A person to reach at an account. ' \
      "#{StandardMCP::Description::IGNORED} " \
      'Writable and required attributes: describe_attributes {"resource": "contacts"}.', describe(ContactsController, :create)
  end

  test "update: send only what changes" do
    assert_equal 'Update one property by id. A real estate asset owned by an account. ' \
      "Send only the attributes to change. #{StandardMCP::Description::IGNORED} " \
      'Writable and required attributes: describe_attributes {"resource": "properties"}.',
      describe(PropertiesController, :update)
  end

  test "the describe pointer is only there with the describe tools" do
    StandardMCP.config.describe_tools = false

    assert_equal "Create one property. A real estate asset owned by an account. #{StandardMCP::Description::IGNORED}",
      describe(PropertiesController, :create)
    refute_includes describe(PropertiesController, :update), 'describe'
    refute_includes describe(PropertiesController, :show), 'describe'
  end

  test "destroy: delete is permanent" do
    assert_equal 'Delete one contact by id. A person to reach at an account. This is permanent.',
      describe(ContactsController, :destroy)
  end

  test "unknown actions are rejected" do
    assert_raises(ArgumentError) { describe(AccountsController, :tables) }
  end

  test "a table without a comment leaves a clean description" do
    StandardMCP::Description.stubs(:table).returns(nil)

    assert_equal 'Get one account by id.', describe(AccountsController, :show)
  end

  test "action may be a string" do
    assert_equal describe(AccountsController, :show), describe(AccountsController, 'show')
  end

  # --- table, column

  test "table returns the table comment or nil" do
    assert_equal 'A customer organization that owns properties.', StandardMCP::Description.table(Account)

    connection.create_table(:uncommented_things)
    model = Class.new(ActiveRecord::Base) { self.table_name = 'uncommented_things' }
    assert_nil StandardMCP::Description.table(model)
  end

  test "column returns the column comment or nil" do
    assert_equal 'Display name of the organization.', StandardMCP::Description.column(Account, 'name')
    assert_equal 'Display name of the organization.', StandardMCP::Description.column(Account, :name)
    assert_nil StandardMCP::Description.column(Account, 'notes')
    assert_nil StandardMCP::Description.column(Account, 'not_a_column')
  end

  test "comments are read every time, not memoized" do
    assert_equal 'A customer organization that owns properties.', StandardMCP::Description.table(Account)

    connection.change_table_comment(:accounts, 'Renamed in a migration.')
    connection.change_column_comment(:accounts, :notes, 'Now documented.')
    Account.reset_column_information

    assert_equal 'Renamed in a migration.', StandardMCP::Description.table(Account)
    assert_equal 'Now documented.', StandardMCP::Description.column(Account, 'notes')
    assert_includes describe(AccountsController, :show), 'Renamed in a migration.'
  ensure
    Account.reset_column_information
  end

end
