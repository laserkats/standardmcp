# Changelog

## Unreleased

- Initial gem scaffold and Postgres-backed test app.
- `allow_mcp` controller DSL (`only`, `except`, `if`, `unless`, multiple rules)
  and `StandardMCP::Registry` for finding MCP-enabled controllers and the
  actions allowed for a request.
- Write tools: `create_<singular>`, `update_<singular>` and `delete_<singular>`
  for `allow_mcp` controllers, with input schemas from the ACL's permitted
  attributes (types, comments, enums, validator constraints, required, nested
  attributes in shallow or deep form), output schemas, `ignored_attributes` for
  keys StandardAPI drops, and database constraint violations as tool errors.
- `StandardMCP::Endpoint` (a controller concern serving the MCP Streamable HTTP
  transport, stateless and JSON-only), the default `StandardMCP::ServerController`
  and the `standard_mcp '/mcp'` route helper. A `tools/call` builds only the
  tool it names (`Tools.for(request, only:)`, which keeps the per-request
  `allow_mcp` conditions). The endpoint skips CSRF protection (the transport
  refuses non-JSON content types), checks `Origin` (`allowed_origins`) and
  validates results outside production (`validate_results`). New
  configuration: `allowed_origins`, `exception_reporter`, `validate_results`.
- Server instructions generated from database comments
  (`StandardMCP::Instructions`): the database comment, a line per resource the
  request may use (table comment and tool names) and the shared conventions.
  `config.instructions` can now add to them (a callable taking the request and
  the generated text), replace them (a String or a callable taking the request,
  as before) or switch them off (`false`).
- `rake standard_mcp:lint` (`StandardMCP::Lint`): tables and columns exposed
  through MCP tools without a database comment, `STRICT=1` for CI, and
  `config.lint_ignore_columns` (`id`, `created_at`, `updated_at` by default).
- `rake standard_mcp:tools` (`StandardMCP::Preview`): prints the instructions
  and `tools/list` for given `HEADERS`, as `FORMAT=json|summary`, or one
  `TOOL`.
- A delete (or save) refused by a model callback now answers
  "<Model> could not be deleted: <the model's errors>" instead of a generic
  status. A refused delete was previously raised as a server error.
