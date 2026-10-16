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
