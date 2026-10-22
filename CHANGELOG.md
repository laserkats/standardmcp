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
- Progressive discovery. The `describe` tool is replaced by `describe_query`
  (the keys and operators of `where`, the `order` keys, the associations to
  include) and `describe_attributes` (`{ "read": ..., "write": ... }`, the JSON
  Schemas StandardAPI's `read_schema` and `write_schema` actions render,
  unchanged: types, descriptions, enums, defaults, `readOnly`, `required`,
  validation constraints; `write` only for a caller who may create or update),
  both taking an optional `where`; `standardmcp://schema/{resource}` is now
  `{ "query": ..., "attributes": { "read": ..., "write": ... } }`. In the default shallow mode no
  tool schema or description lists a column, key or association: `where`,
  `order`, `include`, the written record and a calculate's `select` and
  `group_by` are loose and point at the describe tools. `config.describe_tool`
  is now `describe_tools`.
- Calls are checked without a describe call first: `where` keys against the
  ACL's `wheres` (and its operator lists), a top-level `order` and `include`
  against the ACL, `select` and `group_by` against the columns, and a written
  record against the typed schema. Errors say which describe call to make.
- Attributes can depend on the where: `describe_attributes` dispatches the
  controller's `read_schema` and `write_schema` actions in-process (callbacks
  and authentication run) with the where as `params[:where]`, and `describe_query` and the
  where checks ask `schemas_for` on a controller bound to it, so the ACL's
  `schemas` hook (StandardAPI PR 108) can read `params[:where]` and use
  `mcp_request?`. `describe_query` copies `only_in` and `types` from a
  definition that carries them. The dispatcher allows `read_schema` for a
  caller with any allowed MCP action on the controller, and `write_schema` for
  one who may create or update.
- `config.max_limit` (100 by default) caps the page size of `list_*` apart from
  the controller's `resource_limit`. `mcp_request?` and
  `StandardMCP::DISPATCHED_ENV` tell a request MCP dispatched.
- No tool input schema or `describe_query` document carries `format: uuid`.
- Output schemas (`config.output_schema`) take the record from StandardAPI's
  `read_schema_for` instead of adapting the removed `json_schema` view, so they
  follow StandardAPI's read schema (including its `format: uuid` and
  `additionalProperties: false`); the includes a call may ask for are described
  but not required.
- Builds on standardapi PR 109 (stacked on PR 108) and master's ACL `wheres`;
  deep mode only offers the keys and operators the ACL's `wheres` permit.
