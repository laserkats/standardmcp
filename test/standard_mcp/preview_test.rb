require 'standard_mcp/test_helper'
require 'rake'

# Only visible to a caller that sends a bearer token.
class PreviewBearerController < ApplicationController
  allow_mcp only: [:index], if: -> { current_account_id.present? }

  def self.model
    Account
  end
end

class PreviewTest < ActiveSupport::TestCase

  setup do
    StandardMCP::Registry.stubs(:controllers).returns([AccountsController, ContactsController, PropertiesController])
    @io = StringIO.new
  end

  def preview(**options)
    StandardMCP::Preview.call(io: @io, **options)
  end

  # --- parse_headers

  test "headers are parsed from pairs separated by semicolons or newlines" do
    assert_equal({ 'Authorization' => 'Bearer 1', 'X-MCP-Writes' => 'true' },
      StandardMCP::Preview.parse_headers('Authorization: Bearer 1; X-MCP-Writes: true'))
    assert_equal({ 'A' => '1', 'B' => '2' }, StandardMCP::Preview.parse_headers("A: 1\nB: 2\r\n\n"))
  end

  test "a header value keeps its colons and blank input is no headers" do
    assert_equal({ 'Referer' => 'https://example.com:3000/x' }, StandardMCP::Preview.parse_headers('Referer: https://example.com:3000/x'))
    assert_equal({}, StandardMCP::Preview.parse_headers(nil))
    assert_equal({}, StandardMCP::Preview.parse_headers(' ; '))
  end

  test "a header without a name or a colon is refused" do
    assert_raises(ArgumentError) { StandardMCP::Preview.parse_headers('Authorization Bearer 1') }
    assert_raises(ArgumentError) { StandardMCP::Preview.parse_headers(': 1') }
  end

  # --- formats

  test "json prints the instructions and tools/list" do
    result = preview
    printed = JSON.parse(@io.string)

    assert_equal %w[instructions tools], printed.keys
    assert_equal %w[calculate_accounts get_account get_property list_accounts list_properties], printed['tools'].map { |t| t['name'] }.sort
    assert_equal StandardMCP::Tools.for(preview_request).map(&:to_h).map { |t| JSON.parse(JSON.generate(t)) }, printed['tools']
    assert_includes printed['instructions'], 'Resources:'
    assert_equal printed['tools'].size, result[:tools].size
  end

  test "summary has a line per tool and the totals" do
    preview(format: 'summary')
    lines = @io.string.lines.map(&:chomp)

    line = lines.find { |l| l.start_with?('list_accounts') }
    assert_match(/\Alist_accounts +\d+ +List accounts\.\z/, line)
    size = line[/\d+/].to_i
    tool = StandardMCP::Tools.for(preview_request).find { |t| t.name_value == 'list_accounts' }
    assert_equal JSON.generate(tool.to_h).length, size

    assert_match(/\A5 tools, \d+ characters \(instructions: \d+ characters\)\z/, lines.last)
  end

  test "an unknown format is refused" do
    assert_raises(ArgumentError) { preview(format: 'xml') }
  end

  test "a blank format is json" do
    preview(format: '')

    assert JSON.parse(@io.string).key?('tools')
  end

  # --- TOOL

  test "TOOL prints just that tool" do
    preview(tool: 'get_account')

    printed = JSON.parse(@io.string)
    assert_equal 'get_account', printed['name']
    assert printed.key?('inputSchema')
  end

  test "TOOL with the summary format prints one line" do
    preview(tool: 'get_account', format: 'summary')

    assert_equal 2, @io.string.lines.reject { |l| l.strip.empty? }.size
    assert_match(/\A1 tool, \d+ characters\z/, @io.string.lines.last.chomp)
  end

  test "an unknown tool says what is available" do
    error = assert_raises(ArgumentError) { preview(tool: 'list_nothing') }

    assert_includes error.message, 'No tool named "list_nothing"'
    assert_includes error.message, 'list_accounts'
  end

  # --- headers

  test "headers decide what is hidden" do
    names = preview(headers: 'X-MCP-Writes: true')[:tools].map { |t| t[:name] }

    assert_includes names, 'create_property'
    assert_includes names, 'delete_contact'
    refute_includes preview[:tools].map { |t| t[:name] }, 'create_property'
  end

  test "headers can be a Hash" do
    result = preview(headers: { 'X-MCP-Writes' => 'true' })

    assert_includes result[:tools].map { |t| t[:name] }, 'create_property'
    assert_includes result[:instructions], 'create_contact'
  end

  test "an Authorization header reaches the conditions" do
    StandardMCP::Registry.stubs(:controllers).returns([PreviewBearerController])

    assert_empty preview[:tools]
    assert_equal %w[list_preview_bearer], preview(headers: 'Authorization: Bearer 7')[:tools].map { |t| t[:name] }
  end

  test "the configured instructions are previewed" do
    StandardMCP.config.instructions = ->(request) { "For #{request.headers['X-Who']}" }

    assert_equal 'For Ben', preview(headers: 'X-Who: Ben')[:instructions]
  end

  # --- rake

  def preview_request
    ActionDispatch::Request.new(Rack::MockRequest.env_for('/mcp'))
  end

  def with_rake_tasks
    previous = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    StandardMCP::Railtie.instance.send(:run_tasks_blocks, Rails.application)
    yield
  ensure
    Rake.application = previous
  end

  def with_env(env)
    previous = env.keys.to_h { |key| [key, ENV[key]] }
    env.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  test "the Railtie loads standard_mcp:tools, which reads HEADERS, FORMAT and TOOL" do
    with_rake_tasks do
      assert Rake::Task.task_defined?('standard_mcp:tools')

      with_env('HEADERS' => 'X-MCP-Writes: true', 'FORMAT' => 'summary', 'TOOL' => nil) do
        out, = capture_io { Rake::Task['standard_mcp:tools'].invoke }
        assert_match(/^create_property /, out)
      end
    end

    with_rake_tasks do
      with_env('HEADERS' => nil, 'FORMAT' => nil, 'TOOL' => 'list_accounts') do
        out, = capture_io { Rake::Task['standard_mcp:tools'].invoke }
        assert_equal 'list_accounts', JSON.parse(out)['name']
      end
    end
  end

  test "the task aborts on an unknown tool" do
    with_rake_tasks do
      with_env('HEADERS' => nil, 'FORMAT' => nil, 'TOOL' => 'nope') do
        _, err = capture_io do
          assert_raises(SystemExit) { Rake::Task['standard_mcp:tools'].invoke }
        end
        assert_includes err, 'No tool named "nope"'
      end
    end
  end
end
