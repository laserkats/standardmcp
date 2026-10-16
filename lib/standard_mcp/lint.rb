module StandardMCP
  # Finds the database comments a caller of the MCP tools would miss: the
  # comments are what tool and parameter descriptions are made of, so a table
  # or column without one is context the model never sees.
  #
  # What is checked is every model an MCP-enabled controller serves, plus the
  # models reachable from it through its permitted includes and nested
  # attributes. A column counts as exposed unless the ACL's `excludes` hides it
  # (StandardAPI renders, filters and orders by every other column), minus
  # `config.lint_ignore_columns` (id and the timestamps by default).
  #
  # ACL methods depend on the request, so they are evaluated for an anonymous
  # one: what only some callers see (an `if:` on `allow_mcp` doesn't matter,
  # every MCP-enabled controller is checked) may differ.
  module Lint
    # kind is :database, :table or :column; table and column are nil where they
    # don't apply; model names the (first) model that exposes the table.
    Finding = Data.define(:kind, :table, :column, :model) do
      def to_s
        case kind
        when :database then 'database has no comment'
        when :table then 'table has no comment'
        else "#{column} has no comment"
        end
      end
    end

    # Raised by `run(strict: true)` when something is missing; carries the
    # findings.
    class Failure < Error
      attr_reader :findings

      def initialize(findings)
        @findings = findings
        super("#{findings.size} missing comment#{'s' unless findings.size == 1}")
      end
    end

    class << self
      # Prints a report to +io+ and returns the findings (an Array of Finding,
      # empty when everything has a comment). +strict+ raises Failure after
      # printing instead of returning when there are any. +ignore_columns+
      # defaults to `config.lint_ignore_columns`; +database_comment+ turns the
      # check of the database's own comment off when false.
      def run(io: $stdout, strict: false, ignore_columns: nil, database_comment: true)
        ignore = Array(ignore_columns || StandardMCP.config.lint_ignore_columns).map(&:to_s)
        exposed = exposed_columns
        findings = []
        findings << Finding.new(kind: :database, table: nil, column: nil, model: nil) if database_comment && missing_database_comment?

        exposed.each_value do |entry|
          model = entry[:model]
          findings << Finding.new(kind: :table, table: model.table_name, column: nil, model: model.name) unless Description.table(model)

          entry[:columns].sort.each do |name|
            next if ignore.include?(name) || Description.column(model, name)

            findings << Finding.new(kind: :column, table: model.table_name, column: name, model: model.name)
          end
        end

        report(io, findings, exposed, ignore)
        raise Failure, findings if strict && findings.any?

        findings
      end

      private

      # { table name => { model:, columns: [names] } } for every model exposed
      # by an MCP-enabled controller. STI models share a table, so one entry
      # takes the union of their columns.
      def exposed_columns
        request = ActionDispatch::Request.new(Rack::MockRequest.env_for('/mcp'))
        exposed = {}

        Registry.controllers.sort_by(&:name).each do |klass|
          next unless klass.model

          controller = Registry.controller_for(klass, request)
          visit(controller, klass.model, Schema::Input.includes(controller), exposed, [])
        end

        exposed.sort.to_h
      end

      # +tree+ is the permitted include tree below +model+ (pruned of what the
      # ACL hides). +nesting+ is the models written through on the way here,
      # which also stops nested attributes that loop back; nil once the path
      # went through an include, since a record that is only read can't be
      # written through (the nested attributes of an included model don't count).
      def visit(controller, model, tree, exposed, nesting)
        return unless model.table_exists?

        entry = exposed[model.table_name] ||= { model: model, columns: [] }
        entry[:columns] |= model.column_names - Schema::Input.hidden(controller, model)

        tree.each do |name, subtree|
          klass = related_class(model.reflect_on_association(name))
          visit(controller, klass, subtree, exposed, nil) if klass
        end
        return unless nesting

        Schema::Attributes.nested(controller, model).each do |reflection|
          klass = related_class(reflection)
          visit(controller, klass, {}, exposed, nesting + [model]) if klass && !nesting.include?(klass)
        end
      end

      # nil for a missing association, a polymorphic one (its class depends on
      # the record) or one whose class doesn't exist.
      def related_class(reflection)
        Schema::Input.klass_for(reflection) unless reflection.nil? || reflection.polymorphic?
      end

      def missing_database_comment?
        Instructions.database_comment.blank?
      end

      def report(io, findings, exposed, ignore)
        io.puts 'StandardMCP comment lint'
        io.puts 'ACLs are evaluated for an anonymous request; per-request ACLs may expose more to some callers.'
        io.puts "Ignored columns: #{ignore.join(', ')}" if ignore.any?
        io.puts

        if findings.empty?
          io.puts "All #{exposed.size} exposed tables and their columns have comments."
          return
        end

        io.puts 'database: no comment' if findings.any? { |finding| finding.kind == :database }

        findings.reject { |finding| finding.kind == :database }.group_by(&:table).each do |table, group|
          io.puts "#{table} (#{group.first.model})"
          group.each { |finding| io.puts "  #{finding}" }
        end

        counts = findings.group_by(&:kind).transform_values(&:size)
        parts = []
        parts << 'the database' if counts[:database]
        parts << "#{counts[:table]} #{'table'.pluralize(counts[:table])}" if counts[:table]
        parts << "#{counts[:column]} #{'column'.pluralize(counts[:column])}" if counts[:column]

        io.puts
        io.puts "Summary: #{findings.size} missing #{'comment'.pluralize(findings.size)} (#{parts.join(', ')}) " \
          "across #{exposed.size} #{'table'.pluralize(exposed.size)} checked"
      end
    end
  end
end
