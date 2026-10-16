namespace :standard_mcp do
  desc 'List tables and columns exposed through MCP tools that have no database comment ' \
    '(STRICT=1 fails when any are missing; IGNORE_COLUMNS=id,created_at overrides config.lint_ignore_columns; ' \
    'DATABASE_COMMENT=0 skips the database comment)'
  task lint: :environment do
    options = {
      strict: ENV['STRICT'].to_s.match?(/\A(1|true|yes)\z/i),
      database_comment: !ENV['DATABASE_COMMENT'].to_s.match?(/\A(0|false|no)\z/i)
    }
    options[:ignore_columns] = ENV['IGNORE_COLUMNS'].split(',').map(&:strip) if ENV['IGNORE_COLUMNS']

    begin
      StandardMCP::Lint.run(**options)
    rescue StandardMCP::Lint::Failure
      exit 1
    end
  end

  desc 'Print the server instructions, tools/list and resource templates a caller would get ' \
    "(HEADERS='Authorization: Bearer 1; X-A: b', FORMAT=json|summary, TOOL=list_accounts, " \
    'URI=standardmcp://schema/accounts to print what reading it returns)'
  task tools: :environment do
    StandardMCP::Preview.call(headers: ENV['HEADERS'].to_s, format: ENV['FORMAT'], tool: ENV['TOOL'], uri: ENV['URI'])
  rescue ArgumentError => e
    abort "standard_mcp:tools: #{e.message}"
  end
end
