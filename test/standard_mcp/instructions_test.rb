require 'standard_mcp/test_helper'

# Hidden unless the caller sends X-MCP-Staff, and without a table comment.
module Crew
  class Member < ActiveRecord::Base
    self.table_name = 'contacts'
  end

  class MembersController < ::ApplicationController
    allow_mcp only: [:index], if: :staff?

    private

    def staff?
      request.headers['X-MCP-Staff'] == 'true'
    end
  end
end

class InstructionsTest < ActiveSupport::TestCase

  setup do
    StandardMCP::Registry.stubs(:controllers).returns(
      [AccountsController, ContactsController, Crew::MembersController, PropertiesController]
    )
  end

  def request_for(headers = {})
    headers = headers.transform_keys { |k| "HTTP_#{k.upcase.tr('-', '_')}" }
    ActionDispatch::Request.new(Rack::MockRequest.env_for('/mcp', headers))
  end

  def instructions(headers = {})
    StandardMCP::Instructions.for(request_for(headers))
  end

  WRITES = { 'X-MCP-Writes' => 'true' }.freeze

  # --- generated

  test "the database comment opens the instructions" do
    assert instructions.start_with?("Property management data: customer accounts, the properties they own and the people to reach.\n\nResources:\n")
  end

  test "without a database comment the resources open them" do
    ActiveRecord::Base.connection.stubs(:database_comment).returns(nil)

    assert instructions.start_with?("Resources:\n")
  end

  test "resources are one line each, with the table comment and the tools" do
    lines = instructions.lines.map(&:chomp)

    assert_includes lines, 'accounts: A customer organization that owns properties. Tools: list_accounts, get_account, calculate_accounts.'
    assert_includes lines, 'properties: A real estate asset owned by an account. Tools: list_properties, get_property.'
  end

  test "resources follow the request" do
    refute_includes instructions, 'contacts:'
    refute_includes instructions, 'crew/members'
    refute_includes instructions, 'create_property'

    with_writes = instructions(WRITES)
    assert_includes with_writes, 'contacts: A person to reach at an account. Tools: create_contact, update_contact, delete_contact.'
    assert_includes with_writes, 'properties: A real estate asset owned by an account. ' \
      'Tools: list_properties, get_property, create_property, update_property, calculate_properties.'
  end

  test "a resource without a table comment is still listed" do
    StandardMCP::Description.stubs(:table).returns(nil)

    lines = instructions('X-MCP-Staff' => 'true').lines.map(&:chomp)
    assert_includes lines, 'crew/members: Tools: list_crew_members.'
    assert_includes lines, 'accounts: Tools: list_accounts, get_account, calculate_accounts.'
  end

  test "a multi-line table comment is one line" do
    StandardMCP::Description.stubs(:table).returns("Owned by an account.\n  Has photos")

    assert_includes instructions, "accounts: Owned by an account. Has photos. Tools: list_accounts"
  end

  test "the tool names are the ones Tools builds" do
    request = request_for(WRITES.merge('X-MCP-Staff' => 'true'))
    advertised = StandardMCP::Tools.for(request).map(&:name_value) - %w[describe_query describe_attributes]
    named = StandardMCP::Instructions.for(request).scan(/\b(?:list|get|create|update|delete|calculate)_[a-z_]+/).uniq
      .reject { |name| name.end_with?('_*') }

    assert_equal advertised.sort, named.sort
  end

  test "the conventions only mention what the caller can use" do
    reads = instructions
    assert_includes reads, 'next_offset'
    assert_includes reads, '{"size": {"gte": 1000}}'
    assert_includes reads, 'include embeds associations'
    refute_includes reads, 'singular name'
    refute_includes reads, "record's id"

    writes = instructions(WRITES)
    assert_includes writes, 'create_* and update_* take the record under its singular name, e.g. {"contact": {...}}.'
    assert_includes writes, "update_* and delete_* take the record's id."
  end

  test "the conventions say what the describe tools return, with a resource of the caller" do
    text = instructions

    assert_includes text, %(describe_query {"resource": "accounts"} returns the keys, operators and associations of where, order and include; )
    assert_includes text, %(describe_attributes {"resource": "accounts"} returns a record's JSON Schema, with which attributes are read only or required. )
    assert_includes text, 'Pass them the where you will use, as some keys depend on it.'
    refute_includes text, '"/" in a resource name'
  end

  test "no convention makes a describe call mandatory" do
    refute_match(/\b(first|before|must|always)\b/i, instructions[/Conventions:.*/m])
  end

  test "the instructions list no column of a model" do
    text = instructions(WRITES)

    %w[built_on listed_at metadata internal_path caption].each { |name| refute_includes text, name }
  end

  test "the describe line tells how a namespaced resource is written" do
    namespaced = Class.new(ApplicationController) do
      allow_mcp only: [:index]
      def self.model = Account
      def self.name = 'Billing::AccountsController'
      def self.controller_path = 'billing/accounts'
    end
    StandardMCP::Registry.stubs(:controllers).returns([namespaced, AccountsController])

    assert_includes instructions, 'billing/accounts: '
    assert_includes instructions, 'describe_query {"resource": "billing_accounts"} returns'
    assert_includes instructions, '(write a "/" in a resource name as "_")'
  end

  test "the describe line is there only when describe is" do
    StandardMCP.config.describe_tools = false

    refute_includes instructions, 'describe'
  end

  test "there is nothing to say without a database comment or an allowed resource" do
    ActiveRecord::Base.connection.stubs(:database_comment).returns(nil)
    StandardMCP::Registry.stubs(:controllers).returns([ContactsController])

    assert_nil instructions
  end

  test "the database comment alone is enough" do
    StandardMCP::Registry.stubs(:controllers).returns([ContactsController])

    assert_equal 'Property management data: customer accounts, the properties they own and the people to reach.',
      instructions
  end

  test "a controller without a model is left out" do
    modelless = Class.new(ApplicationController) do
      def self.name = 'InstructionsModellessController'
      def self.model = nil
      allow_mcp
    end
    StandardMCP::Registry.stubs(:controllers).returns([AccountsController, modelless])

    refute_includes instructions, 'modelless'
  end

  test "the generated text stays small" do
    assert_operator instructions.length, :<, 900
    assert_operator instructions(WRITES.merge('X-MCP-Staff' => 'true')).length, :<, 1500
  end

  # --- config.instructions

  test "a String replaces the generated instructions" do
    StandardMCP.config.instructions = 'Use these tools carefully.'

    assert_equal 'Use these tools carefully.', instructions
  end

  test "a callable taking the request replaces them" do
    StandardMCP.config.instructions = ->(request) { "Hello #{request.headers['X-Who']}" }

    assert_equal 'Hello Ben', instructions('X-Who' => 'Ben')
  end

  test "a callable taking the request and the default adds to them" do
    StandardMCP.config.instructions = ->(request, default) { "#{default}\n\nSize is in square feet (#{request.headers['X-Who']})." }

    text = instructions('X-Who' => 'Ben')
    assert text.start_with?('Property management data')
    assert_includes text, 'accounts: A customer organization'
    assert text.end_with?("\n\nSize is in square feet (Ben).")
  end

  test "a callable with an optional default gets it too" do
    StandardMCP.config.instructions = proc { |request, default = nil| default }

    assert_includes instructions, 'Resources:'
  end

  test "a callable object is judged by its call method" do
    adder = Class.new { def call(request, default) = "#{default} +" }.new
    replacer = Class.new { def call(request) = 'replaced' }.new

    StandardMCP.config.instructions = adder
    assert instructions.end_with?(' +')

    StandardMCP.config.instructions = replacer
    assert_equal 'replaced', instructions
  end

  test "the generated text is not worked out for a replacement" do
    StandardMCP::Instructions.expects(:generate).never
    StandardMCP.config.instructions = ->(request) { 'Hello' }

    instructions
  end

  test "a callable that returns nothing falls back to the generated instructions" do
    StandardMCP.config.instructions = ->(request) { nil }
    assert_includes instructions, 'Resources:'

    StandardMCP.config.instructions = ->(request, default) { '' }
    assert_includes instructions, 'Resources:'

    StandardMCP.config.instructions = ''
    assert_includes instructions, 'Resources:'
  end

  test "false sends no instructions" do
    StandardMCP.config.instructions = false

    assert_nil instructions
  end
end
