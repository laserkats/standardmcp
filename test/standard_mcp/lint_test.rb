require 'standard_mcp/test_helper'
require 'rake'

# Account with `notes` hidden by the ACL: nothing it exposes is uncommented.
class LintHidingController < ApplicationController
  allow_mcp

  def self.model
    Account
  end

  def account_excludes(record = nil)
    { notes: true }
  end
end

# Reaches photos only through nested attributes: no includes.
class LintNestedController < ApplicationController
  allow_mcp

  def self.model
    Property
  end

  def property_includes
    []
  end
end

class LintTest < ActiveSupport::TestCase

  setup do
    StandardMCP::Registry.stubs(:controllers).returns([AccountsController, ContactsController, PropertiesController])
    @io = StringIO.new
  end

  teardown do
    Photo.reset_column_information
  end

  def lint(**options)
    StandardMCP::Lint.run(io: @io, **options)
  end

  def tuples(findings)
    findings.map { |finding| [finding.table, finding.column].compact.join('.') }
  end

  # --- findings

  test "reports exposed columns without a comment" do
    findings = lint

    assert_includes tuples(findings), 'accounts.notes'
    assert_includes tuples(findings), 'photos.caption'
    assert_equal %i[column], findings.map(&:kind).uniq
    assert_equal 'Account', findings.find { |finding| finding.column == 'notes' }.model
  end

  test "id and the timestamps are not expected to have comments" do
    assert_equal %w[accounts.notes photos.caption], tuples(lint).sort
  end

  test "the ignore list can be changed in the configuration" do
    StandardMCP.config.lint_ignore_columns = %w[id notes]

    names = tuples(lint)
    refute_includes names, 'accounts.notes'
    assert_includes names, 'accounts.created_at'
    assert_includes names, 'photos.caption'
  end

  test "the ignore list can be changed per run" do
    names = tuples(lint(ignore_columns: %w[id created_at updated_at notes caption]))

    assert_empty names
  end

  test "an empty ignore list reports the id and the timestamps" do
    names = tuples(lint(ignore_columns: []))

    assert_includes names, 'accounts.id'
    assert_includes names, 'photos.updated_at'
  end

  test "reports a table without a comment" do
    connection.change_table_comment(:contacts, nil)

    finding = lint.find { |f| f.kind == :table }
    assert_equal 'contacts', finding.table
    assert_equal 'Contact', finding.model
  end

  test "reports a column without a comment" do
    connection.change_column_comment(:properties, :size, nil)
    Property.reset_column_information

    assert_includes tuples(lint), 'properties.size'
  ensure
    Property.reset_column_information
  end

  test "reports a missing database comment unless asked not to" do
    ActiveRecord::Base.connection.stubs(:database_comment).returns(nil)

    assert_includes lint.map(&:kind), :database
    assert_includes @io.string, 'database: no comment'

    assert_not_includes lint(database_comment: false).map(&:kind), :database
  end

  test "models reached through includes are checked" do
    StandardMCP::Registry.stubs(:controllers).returns([ContactsController])

    # contacts include :account, which isn't served by any controller here
    assert_equal %w[accounts.notes], tuples(lint)
  end

  test "models reached through nested attributes are checked" do
    StandardMCP::Registry.stubs(:controllers).returns([LintNestedController])

    findings = lint
    assert_equal %w[photos.caption], tuples(findings)
  end

  test "columns the ACL excludes are not exposed" do
    StandardMCP::Registry.stubs(:controllers).returns([LintHidingController])

    assert_empty lint
  end

  test "a controller without a model is skipped" do
    modelless = Class.new(ApplicationController) do
      def self.name = 'LintModellessController'
      def self.model = nil
    end
    StandardMCP::Registry.stubs(:controllers).returns([modelless, LintHidingController])

    assert_empty lint
  end

  # --- report

  test "the report is grouped by table and ends with a summary" do
    lint

    assert_includes @io.string, 'ACLs are evaluated for an anonymous request'
    assert_includes @io.string, "accounts (Account)\n  notes has no comment\n"
    assert_includes @io.string, "photos (Photo)\n  caption has no comment\n"
    assert_match(/^Summary: 2 missing comments \(2 columns\) across 4 tables checked$/, @io.string)
  end

  test "the report says so when nothing is missing" do
    StandardMCP::Registry.stubs(:controllers).returns([LintHidingController])
    lint

    assert_includes @io.string, 'have comments.'
    refute_includes @io.string, 'Summary'
  end

  # --- strict

  test "strict raises after reporting when something is missing" do
    error = assert_raises(StandardMCP::Lint::Failure) { lint(strict: true) }

    assert_equal 2, error.findings.size
    assert_equal '2 missing comments', error.message
    assert_includes @io.string, 'Summary'
  end

  test "strict returns when nothing is missing" do
    StandardMCP::Registry.stubs(:controllers).returns([LintHidingController])

    assert_equal [], lint(strict: true)
  end

  # --- rake

  # A fresh Rake application with the Railtie's task blocks loaded, as
  # `rails` would, and a stand-in for the :environment task.
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

  test "the Railtie loads standard_mcp:lint" do
    with_rake_tasks do
      assert Rake::Task.task_defined?('standard_mcp:lint')

      out, = capture_io { Rake::Task['standard_mcp:lint'].invoke }
      assert_includes out, 'accounts (Account)'
      assert_includes out, 'Summary: 2 missing comments'
    end
  end

  test "the task passes with STRICT=1 only when nothing is missing" do
    with_rake_tasks do
      with_env('STRICT' => '1') do
        capture_io do
          error = assert_raises(SystemExit) { Rake::Task['standard_mcp:lint'].invoke }
          assert_equal 1, error.status
        end
      end
    end

    with_rake_tasks do
      with_env('STRICT' => '1', 'IGNORE_COLUMNS' => 'id,created_at,updated_at,notes,caption') do
        out, = capture_io { Rake::Task['standard_mcp:lint'].invoke }
        assert_includes out, 'have comments.'
      end
    end
  end

  test "the task exits normally without STRICT" do
    with_rake_tasks do
      with_env('STRICT' => nil) do
        out, = capture_io { Rake::Task['standard_mcp:lint'].invoke }
        assert_includes out, 'Summary: 2 missing comments'
      end
    end
  end
end
