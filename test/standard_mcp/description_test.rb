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
      'Filter with where; page with limit and offset, using next_offset from the result. ' \
      'Includes: account, photos. Order by: id, name, size, created_at.', description
  end

  test "show: action sentence, table comment, includes" do
    assert_equal 'Get one account by id. A customer organization that owns properties. Includes: properties.',
      describe(AccountsController, :show)
  end

  test "calculate: action sentence, table comment, guidance" do
    assert_equal 'Aggregate accounts (count, sum, min, max, average), optionally grouped. ' \
      'A customer organization that owns properties. Filter with where; group with group_by.',
      describe(AccountsController, :calculate)
  end

  test "nested includes are listed by path" do
    klass = Class.new(ApplicationController) do
      def self.model = Account
      def account_includes = [{ properties: [:photos] }]
    end

    description = StandardMCP::Description.for(StandardMCP::Registry.controller_for(klass, request_for), :show)

    assert_includes description, 'Includes: properties, properties.photos.'
  end

  test "the guidance does not repeat the schema" do
    description = describe(PropertiesController, :index)

    refute_match(/integer|minimum|maximum|boolean/, description)
  end

  test "hidden associations are not listed" do
    klass = Class.new(ApplicationController) do
      def self.model = Property
      def property_includes = [:account, :photos]
      def property_excludes(_record) = { photos: true }
    end

    description = StandardMCP::Description.for(StandardMCP::Registry.controller_for(klass, request_for), :show)

    assert_includes description, 'Includes: account.'
  end

  test "orders and includes follow the caller" do
    plain = describe(DescriptionVaryingController, :index)
    admin = describe(DescriptionVaryingController, :index, 'X-Admin' => 'true')

    assert_includes plain, 'Includes: account.'
    assert_includes plain, 'Order by: id, name, size, created_at.'
    assert_includes admin, 'Includes: account, photos.'
    assert_includes admin, 'Order by: id, name, size, created_at, rent.'
  end

  test "create: names the required attributes" do
    assert_equal 'Create one property. A real estate asset owned by an account. Required: name. ' \
      "#{StandardMCP::Description::IGNORED} Includes: account, photos. " \
      'Full column details: describe {"resource": "properties"}.', describe(PropertiesController, :create)
    assert_includes describe(ContactsController, :create), 'Required: name.'
  end

  test "create leaves out the required sentence when nothing is required" do
    refute_includes describe(AccountsController, :create), 'Required'
  end

  test "update: send only what changes" do
    assert_equal 'Update one property by id. A real estate asset owned by an account. ' \
      "Send only the attributes to change. #{StandardMCP::Description::IGNORED} Includes: account, photos. " \
      'Full column details: describe {"resource": "properties"}.',
      describe(PropertiesController, :update)
  end

  test "the describe pointer is only there with the describe tool" do
    StandardMCP.config.describe_tool = false

    refute_includes describe(PropertiesController, :create), 'describe'
    refute_includes describe(PropertiesController, :update), 'describe'
    refute_includes describe(PropertiesController, :show), 'describe'
  end

  test "destroy: delete is permanent" do
    assert_equal 'Delete one contact by id. A person to reach at an account. This is permanent.',
      describe(ContactsController, :destroy)
  end

  test "write includes follow the caller" do
    assert_includes describe(DescriptionVaryingController, :create), 'Includes: account.'
    assert_includes describe(DescriptionVaryingController, :update, 'X-Admin' => 'true'), 'Includes: account, photos.'
  end

  test "unknown actions are rejected" do
    assert_raises(ArgumentError) { describe(AccountsController, :tables) }
  end

  test "a table without a comment leaves a clean description" do
    StandardMCP::Description.stubs(:table).returns(nil)

    assert_equal 'Get one account by id. Includes: properties.', describe(AccountsController, :show)
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
