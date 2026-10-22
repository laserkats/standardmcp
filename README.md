# StandardMCP

> Status: pre-release. The API may still change.

StandardMCP turns the [StandardAPI](https://github.com/waratuman/standardapi)
controllers your Rails app already has into an [MCP](https://modelcontextprotocol.io)
server, using the official `mcp` gem. You opt a controller in with one line;
the gem builds the tools, schemas and descriptions from that controller, its
ACL and your database comments, and runs every call through the controller's
own action. Whatever StandardAPI enforces for your JSON API (permitted
attributes, includes, orders, excludes, `mask_for`, limits, rendering) applies
to MCP calls too, so there is one way in and out of the system.

```ruby
class AccountsController < ApplicationController
  include StandardAPI::Controller

  allow_mcp only: [:index, :show, :calculate]
end

# config/routes.rb
standard_mcp '/mcp'
```

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [What StandardAPI provides](#what-standardapi-provides)
- [Exposing actions with `allow_mcp`](#exposing-actions-with-allow_mcp)
- [The tools your app gets](#the-tools-your-app-gets)
- [Resources and the describe tools](#resources-and-the-describe-tools)
- [Attributes that depend on the where](#attributes-that-depend-on-the-where)
- [Application context from the database](#application-context-from-the-database)
- [Mounting and authentication](#mounting-and-authentication)
- [Configuration](#configuration)
- [Auditing and verification](#auditing-and-verification)
- [Development](#development)

## Requirements

- Ruby 3.2+, Rails 8.0+
- StandardAPI 9.0+ (your controllers include `StandardAPI::Controller`, ACLs
  in `app/controllers/acl`), with ACL `wheres` for everything an agent filters
  on: StandardAPI checks every `where` against them, and so does the gem. A
  model whose ACL has no `wheres` can't be filtered on
- PostgreSQL: table and column comments are the application context, and the
  filter operators are activerecord-filter's Postgres set. This is what the gem
  is tested against.

## Installation

StandardAPI 9 isn't released to RubyGems yet (RubyGems has 7.1.4), and neither
is StandardMCP, so both come from git for now. Pin refs. The StandardAPI one is
PR 109 (the `write_schema`, `read_schema` and `query_schema` actions built from
`schemas_for`), stacked on PR 108 (attribute definitions, `schemas_for` and the
ACL `schemas` hook), which builds on master's ACL `wheres`:

```ruby
# Gemfile
gem 'standardapi', git: 'https://github.com/waratuman/standardapi.git', ref: '1da51f24cc80a7b4bba6afabce24cb64cc7fb9fc'
gem 'standardmcp', git: 'https://github.com/laserkats/standardmcp.git', ref: '<commit>'
```

Then:

1. Mount the endpoint in `config/routes.rb`: `standard_mcp '/mcp'`.
2. Opt controllers in with `allow_mcp` (below).
3. Optionally add `config/initializers/standard_mcp.rb` (see
   [Configuration](#configuration)).
4. Comment your tables and columns, and check with `rake standard_mcp:lint`.
5. Preview what a caller gets with `rake standard_mcp:tools`, then connect a
   client (see [Try it](#try-it)).

## What StandardAPI provides

Every tool call is dispatched in-process to the controller action
(`AccountsController.action(:index).call(env)`) with the caller's credentials,
so the gem reuses StandardAPI rather than reimplementing it:

| StandardAPI piece | What MCP gets from it |
| --- | --- |
| ACL `attributes` (strong params) | Which attributes are writable (the `write` schema of `describe_attributes`); anything else is rejected, and keys a per-record ACL drops come back as `ignored_attributes` |
| ACL `nested` | Nested records in create/update, as StandardAPI accepts them (`photos`, `photo_ids`, foreign keys) |
| ACL `includes` | The `include` argument and the associations `describe_query` lists |
| ACL `orders` | The `order` argument and the order keys `describe_query` lists |
| ACL `wheres` | The keys (and, if listed, the operators) a `where` may use: what `describe_query` lists and every call is checked against |
| ACL `excludes` | Excluded attributes are absent from responses and from every schema and description |
| ACL `schemas` (PR 108) | Adjusts the attribute definitions, which `describe_attributes` and `describe_query` read (and the read and write schemas are built from); it can read `params[:where]` ([below](#attributes-that-depend-on-the-where)) |
| `mask_for` | Row-level restriction on every read, count, update and delete; a masked id reads as "not found" |
| `resource_limit` / `default_limit` | The `limit` maximum and default (`config.default_limit` when the controller has none), and `config.max_limit` caps it for MCP |
| activerecord-filter (`where`) | Filtering with operator objects, checked against the ACL and the model before the call |
| `calculate` | `calculate_*` tools (count, sum, min, max, average, `group_by`) and the `total` of list pages |
| jbuilder views (`_record`, includes, eager loading) | The JSON the tools return, identical to your JSON API |
| `read_schema` and `write_schema` actions (PR 109) | `describe_attributes`, unchanged, and the record schema of output schemas when you turn them on |
| Model validators | Input constraints that are safe to check up front (enums, length, numeric bounds, simple formats); the rest come back as validation errors |
| Table, column and database comments | Tool, argument and server descriptions ([below](#application-context-from-the-database)) |

The gem doesn't authenticate; your controller callbacks do, exactly as for an
HTTP request ([Authentication](#authentication)).

## Exposing actions with `allow_mcp`

`allow_mcp` takes `only:`, `except:`, `if:` and `unless:`, like `before_action`:

```ruby
class PropertiesController < ApplicationController
  include StandardAPI::Controller

  # Reads for everyone who can reach the endpoint.
  allow_mcp only: [:index, :show, :calculate]
  # Writes only for admins.
  allow_mcp only: [:create, :update, :destroy], if: :admin?
end
```

- Exposable actions: `index`, `show`, `create`, `update`, `destroy`,
  `calculate`. With neither `only:` nor `except:`, every one of them the
  controller has is covered. `only:` with `except:`, or an unknown action,
  raises `ArgumentError`.
- `if:` / `unless:` take a Symbol (a controller method, private is fine), a
  Proc (zero arity runs with `instance_exec`, otherwise it gets the controller)
  or an Array of them. All `if:` must be truthy and all `unless:` falsy.
- Several calls combine: an action is exposed when any rule covers it and that
  rule's conditions pass. Subclasses inherit the rules and can add their own.
- Conditions run per request, on a controller instance bound to the MCP
  request, so `current_user`, `request`, `params` and `headers` work. A tool
  whose conditions fail is left out of that caller's `tools/list`, and a call
  to it is refused anyway.
- Row-level restriction belongs in `mask_for`, as for your JSON API.
- `mcp_request?` tells an agent's request from your app's own. It is true on
  the controller instance conditions and schemas are evaluated on, and in the
  in-process request of a tool call: the Dispatcher sets the Rack env key
  `standardmcp.dispatched` (`StandardMCP::DISPATCHED_ENV`) after
  `config.dispatch_env`, so that can't drop it. Use it in an ACL or an
  `if:`/`unless:` to treat agents differently:

  ```ruby
  def property_attributes(record = nil)
    mcp_request? ? super - [:internal_notes] : super
  end
  ```

## The tools your app gets

One tool per allowed (controller, action), named from the controller path
(`admin/accounts` gives `list_admin_accounts`, `get_admin_account`):

| Action | Tool | Arguments |
| --- | --- | --- |
| `index` | `list_accounts` | `where`, `order`, `include`, `limit`, `offset`, `distinct` |
| `show` | `get_account` | `id`, `include` |
| `calculate` | `calculate_accounts` | `select` (required), `where`, `group_by` |
| `create` | `create_account` | `account` (required), `include` |
| `update` | `update_account` | `id`, `account` (both required), `include` |
| `destroy` | `delete_account` | `id` |

Plus `describe_query` and `describe_attributes`
([below](#resources-and-the-describe-tools)). The tool schemas stay small:
`where`, `order`, `include` and the written record are loose objects that point
at those two tools, so `tools/list` doesn't grow with the width of your models
(`input_schema_depth = 'deep'` brings the typed schemas back). Reads are
annotated read-only and idempotent; create is neither destructive nor
idempotent; update and delete are destructive and idempotent.

`list_*` takes at most `config.max_limit` records (100 by default), whatever
the controller's `resource_limit` allows its JSON API: a bigger `limit` is
rejected by schema validation.

Results are JSON as your API renders it, as both `structuredContent` and text:
`{"records": [...], "offset": 0, "next_offset": 25, "total": 112}` for lists
(`total` only when the caller may also use `calculate`; `next_offset` is null on
the last page), `{"record": {...}}` for get, create and update, `{"result": ...}`
for calculate and `{"success": true, "affected_rows": 1}` for delete.

### Filtering

`where` takes an operator object per key, and associations nest:

```json
{"where": {"size": {"gte": 1000}, "kind": {"in": ["office", "retail"]},
           "name": {"not": null}, "account": {"name": {"ilike": "%acme%"}}}}
```

An array alternating filters with `"AND"`/`"OR"` combines them. The keys are
the ones your ACL's `wheres` permit (an ACL can also list the operators a key
takes: `{ name: [:eq, :in] }`), and an association nests only if the ACL permits
it by name; what is below it is judged by the associated model's own ACL, as
StandardAPI does. The schema keeps `where` a plain object with a sentence
pointing at `describe_query`, which lists the keys, their types, the operators
and the associations.

Calls are checked against the ACL and the model before they run, with nothing
to call first. A mistake is a readable tool error that says what to do next, not
an empty result:

```
Unknown filter key 'foo' for properties. Call describe_query {"resource": "properties"} with this where to see the keys you can filter on.
Operator 'like' isn't allowed on properties.name (allowed: eq, in).
Invalid value for size: "abc" (gte expects an integer)
Unknown order key 'rent' for properties. Call describe_query {"resource": "properties"} to see the keys you can order by.
```

A top-level `order` and `include` are checked the same way (what is nested in
them is StandardAPI's to check), and so are the `select` and `group_by` of a
calculate, which only name columns.

### Writes

The record goes under its singular name, as `params.require` expects:
`{"property": {"name": "Tower", "kind": "office"}, "include": {"photos": true}}`.

- The attributes are the ACL's `attributes`, with their types and comments in
  `describe_attributes`. Ids, timestamps, database-filled columns and excluded
  ones aren't accepted. The tool schema keeps the record a loose object; the
  call is held to the typed schema when it is made, so a key the ACL doesn't
  permit, a value of the wrong type or outside an enum, or a missing required
  attribute is a tool error that points at `describe_attributes`.
- Required on create: permitted NOT NULL or presence-validated attributes
  without a default. An update needs at least one attribute.
- Validators become constraints where that's safe (enums, `length`,
  `numericality` bounds, `format` when the regexp means the same in ECMA 262).
  Conditional validators are left to Rails; their errors come back as tool
  errors with `errors`.
- Nested attributes (ACL `nested`) work as in StandardAPI: an object or array
  of objects, each with an optional `id`, or `<association>_ids`. A nested
  collection replaces the whole set.
- The schema asks the ACL without a record. If a per-record
  `attributes(record)` drops a key, the result lists it in
  `ignored_attributes`.
- A masked or missing id is `"Property not found"`. Database constraint
  failures (foreign key, NOT NULL, unique, range) and model callbacks that
  abort (`"Contact could not be deleted: ..."`) are tool errors in plain words,
  without SQL.

## Resources and the describe tools

The tool schemas stay shallow; the detail is one call or read away. Nothing
requires a describe call first (calls are checked on their own and their errors
say which describe call to make), but both take the `where` the agent is about
to use, since some keys depend on it
([below](#attributes-that-depend-on-the-where)).

- **`describe_query`** takes `{"resource": "properties", "where": {...}}`
  (the controller path with `/` as `_`; its enum lists the caller's own; `where`
  is optional) and returns what the caller can ask of a list or calculate. Only
  the sections the caller can use are there: `where` (index or calculate),
  `order` (index) and `include` (index, show, create or update).

  ```json
  {"resource": "properties",
   "description": "A real estate asset owned by an account.",
   "where": {
     "keys": [{"name": "size", "type": "integer", "description": "Rentable area in square feet."},
              {"name": "kind", "type": "string", "enum": ["office", "retail", "industrial"]},
              {"name": "name", "type": "string", "operators": ["eq", "in"]},
              {"name": "search", "kind": "filter"}],
     "operators": {"integer": ["eq", "not", "in", "not_in", "gt", "gte", "lt", "lte"], "enum": ["eq", "not", "in", "not_in"]},
     "associations": [{"name": "account", "resource": "accounts"}],
     "rules": "Every key takes an operator object, e.g. ..."},
   "order": {"keys": [{"name": "size", "type": "integer"}], "rules": "..."},
   "include": [{"name": "account", "kind": "belongs_to", "resource": "accounts"}]}
  ```

  The keys are what the ACL's `wheres` permit (a column it doesn't permit isn't
  there); a key whose ACL entry lists operators carries its own list, the rest
  use `operators`, given once per type. A `filter` key is a `filter_on` filter
  whose value isn't checked. Associations are named with the resource behind
  them and nothing else: to see an association's keys, describe that resource.
- **`describe_attributes`** takes the same arguments and returns
  `{"read": ..., "write": ...}`, the JSON Schemas StandardAPI's `read_schema` and
  `write_schema` actions render, each exactly as the action renders it:
  - `read` is a record as `list_*` and `get_*` return it: each attribute's type
    (decimals are strings), description (from the column comment), enum and
    nullability, and `required`.
  - `write` is what `create_*` and `update_*` accept, under the record's
    singular name: only the attributes the ACL's `attributes` permit, with
    type, description, enum, default, `readOnly` (the model marks it
    `attr_readonly`), `required` (for a create) and the validation constraints
    (length, numeric bounds, patterns), and the associations the ACL's `nested`
    permits. It is there only when the caller may create or update.

  The gem doesn't change either. Both are the actions dispatched in-process
  like a tool call, so your callbacks and authentication run (a 401 is a tool
  error), and the `where` goes in as `params[:where]`, where your ACL's
  `schemas` hook can read it. No `include` is passed (`read` has no
  associations). The caller needs an allowed MCP action on the controller.
- **`standardmcp://schema/{resource}`** is `{"query": ..., "attributes":
  {"read": ..., "write": ...}}`, the two documents for no where, as a resource
  template for clients that read resources.
- **`standardmcp://<resource>/{id}`** (e.g. `standardmcp://accounts/42`) is a
  template per controller the caller may `show`, so a user can attach a
  record as context. Reading it is a dispatched `show`.

Everything is built for the caller. A schema is readable when the caller has
any MCP action on that controller; masked, missing, forbidden and unknown URIs
all answer the same "Resource not found" (JSON-RPC -32602). Record reads have
no `include` (the `mcp` gem only matches plain `{var}` placeholders). The
endpoint serves templates only (`resources/list` is empty) and is stateless, so
there are no subscriptions. How a client shows templates or lets the model read
them is up to the client, which is why the describe tools exist. A where that
couldn't list (an unknown key, say) is a tool error from either of them, as it
would be from `list_*`.

## Attributes that depend on the where

The gem never knows what your models mean. If the attributes of a record depend
on which records you are asking about (say each project defines its own ticket
fields), say so in the ACL's `schemas` hook (StandardAPI PR 108) by reading
`params[:where]`: the where the agent passed, in the params of the request the
hook runs in. It is nil when the agent passed none, and an Array alternating
filters with `"AND"`/`"OR"` when it passed one.

```ruby
module TicketACL
  def schemas(schemas)
    where = params[:where]
    project_ids = where.dig('project_id', 'in') if where.respond_to?(:key?)
    return schemas unless project_ids

    schemas + Project.where(id: project_ids).flat_map(&:fields).map do |field|
      { name: field.key, type: field.type, comment: field.help, null: true, read_only: true }
    end
  end
end
```

The hook sees the same where in both places an agent reads it:

- `describe_attributes` dispatches the controller's `read_schema` and
  `write_schema` actions with the where as `params[:where]`, so both list what
  the hook adds (`write` only if the ACL's `attributes` permit it).
- `describe_query` and the check of every call's `where` ask `schemas_for` on a
  controller whose params hold the where (a new instance per call, so one
  where's definitions never reach another's).

Use `mcp_request?` in the hook to treat agents differently from your own JSON
API. Attributes an ACL `excludes` hides are dropped from `describe_query`.

The definitions are Hashes in the shape of StandardAPI's `schemas_for` (`name`,
`type`, `enum`, `default`, `primary_key`, `null`, `array`, `comment`,
`auto_populated`, `read_only`, `required` and `validations`, Symbol keys). If
one carries `only_in` (the groups of records that have the attribute) or
`types` (its type in each group), `describe_query` copies them onto the key; the
gem doesn't work them out. The keys a `where` may use are still the ACL's
`wheres`, so permit the names your definitions add (and, to write them, the
ACL's `attributes`). `wheres` is static: it can't depend on the where.

## Application context from the database

The gem reads your application's context from Postgres comments, so the
documentation lives with the schema and is read fresh on every request (no
caching; a migration that changes a comment shows up immediately):

| Comment | Read with | Becomes |
| --- | --- | --- |
| Database | `connection.database_comment` (StandardAPI) | The opening paragraph of the server instructions |
| Table | `connection.table_comment(table)` | Tool descriptions, the table's line in the instructions, both describe documents |
| Column | `column.comment` | The key's description in `describe_query`, the attribute's in both schemas of `describe_attributes` |
| Foreign key column | `column.comment` | Its association's description (else the associated table's comment) |

Write them in migrations:

```ruby
create_table :accounts, comment: 'A customer organization that owns properties.' do |t|
  t.string :name, comment: 'Display name of the organization.'
end

add_column :accounts, :status, :string, comment: 'Lifecycle status: active or suspended.'
change_table_comment :accounts, from: nil, to: 'A customer organization.'
change_column_comment :accounts, :notes, from: nil, to: 'Free-form notes from sales.'
```

The database comment is `COMMENT ON DATABASE my_app IS '...'`. Write what a
value means rather than what the column is called: the lifecycle behind a
`status`, the unit of a `size`, how a hierarchy is stored.

### Server instructions

When a client connects, it gets instructions generated from those comments for
that caller (what `allow_mcp` hides is left out):

```
Property management data: customer accounts, the properties they own and the people to reach.

Resources:
accounts: A customer organization that owns properties. Tools: list_accounts, get_account, calculate_accounts.
properties: A real estate asset owned by an account. Tools: list_properties, get_property.

Conventions: list_* tools return one page; pass the result's next_offset as offset to get the next. Filters (where) take operator objects such as {"size": {"gte": 1000}}. include embeds associations in the result. describe_query {"resource": "accounts"} returns the keys, operators and associations of where, order and include; describe_attributes {"resource": "accounts"} returns the JSON Schema of a record and, for writers, of the params of create and update (which attributes are read only or required). Pass them the where you will use, as some keys depend on it.
```

Domain knowledge that doesn't fit a single column goes in
`config.instructions`:

```ruby
# Add to the generated text (a callable taking two arguments):
config.instructions = ->(request, default) do
  "#{default}\n\nSizes are in square feet. Markets are a hierarchy: US|California|San Francisco."
end

config.instructions = 'Replace them entirely.'          # or ->(request) { ... }
config.instructions = false                              # send none
```

## Mounting and authentication

```ruby
# config/routes.rb
standard_mcp '/mcp'
```

routes POST, GET and DELETE `/mcp` (named `standard_mcp`) to
`StandardMCP::ServerController#handle`, which inherits from
`config.parent_controller` (`ApplicationController` by default). To own the
controller, include the endpoint and route to it:

```ruby
class McpController < ApplicationController
  include StandardMCP::Endpoint
  before_action :authenticate_mcp_client!
end

# config/routes.rb
standard_mcp '/mcp', to: 'mcp#handle'
```

The endpoint is the stateless Streamable HTTP transport with plain JSON
responses: a server and its tools are built per request (a `tools/call` builds
only the tool it names), with no sessions or SSE stream; GET answers 405.

### Authentication

- The gem does none. The controller's callbacks (its parent's
  `before_action`s) run first: authenticate there and render a 401 with a
  `WWW-Authenticate` header for MCP clients.
- Tool calls run in-process with the caller's `Authorization`, `Cookie`,
  remote address and host, so `current_user`, ACLs and `mask_for` resolve as
  for a normal request. `config.dispatch_env` adds Rack env entries (e.g. an
  internal-user key your `current_user` honors).
- CSRF: the endpoint skips forgery protection, which is safe because the
  transport only accepts `Content-Type: application/json`, which a cross-site
  form can't send. The in-process calls still run your `protect_from_forgery`,
  so writes need bearer-style auth or a `verified_request?` that honors a key
  set through `dispatch_env`; otherwise a write is a tool error.
- Origin: a request with an `Origin` header must be same-origin or match
  `config.allowed_origins`, else 403. Requests without one (non-browser
  clients) pass. Host checks (DNS rebinding) are Rails' `config.hosts`.

## Configuration

```ruby
# config/initializers/standard_mcp.rb
StandardMCP.configure do |config|
  config.server_name = 'my-app'
  config.allowed_origins = ['https://claude.ai']
  config.instructions = ->(request, default) { "#{default}\n\n..." }
  config.exception_reporter = ->(exception, server_context) { Rails.error.report(exception) }
end
```

| Option | Default | Effect |
| --- | --- | --- |
| `server_name` | the app's module name | Reported to clients on `initialize` |
| `server_version` | the gem's version | Reported to clients on `initialize` |
| `parent_controller` | `'ApplicationController'` | What `StandardMCP::ServerController` inherits from (its callbacks authenticate) |
| `instructions` | `nil` (generated) | A String or `->(request)` replaces the generated text; `->(request, default)` extends it; `false` sends none |
| `dispatch_env` | `->(request) { {} }` | Extra Rack env for the in-process calls |
| `allowed_origins` | `nil` | Origins accepted besides the endpoint's own: exact Strings (case-insensitive) or Regexps, anchored to the whole origin |
| `default_limit` | `25` | Page size when neither the controller's `default_limit` nor the caller sets one |
| `max_limit` | `100` | The most one `list_*` call may ask for, apart from the controller's `resource_limit` (the `limit` maximum is the smaller of the two, the default page is held to it); `nil` turns the cap off |
| `input_schema_depth` | `'shallow'` | `'shallow'`: `where`, `order`, `include` and the written record are loose objects that point at the describe tools, so `tools/list` names no column, and calls are checked before dispatch. `'deep'`: the typed schemas; `where` offers only the keys and operators the ACL's `wheres` permit. Deep types real columns only, not attributes that depend on the where, and grows with your models |
| `where_depth` | `1` | Deep mode only: association levels `where` spells out, bounded by the ACL's includes |
| `output_schema` | `false` | Declare an `outputSchema` per tool (the record from StandardAPI's `read_schema`). It lists every column of every model again, so next to the small shallow input schemas it is most of `tools/list` (on the gem's test app, 159% more anonymous, 168% more with `X-MCP-Writes: true`). Results carry `structuredContent` either way |
| `validate_results` | on outside production | Check results against the output schema (needs `output_schema`) |
| `resources` | `%i[schema records]` | Resource templates served; `[]` for none (and `resources` isn't advertised) |
| `describe_tools` | `true` | The `describe_query` and `describe_attributes` tools and the pointers to them |
| `resource_scheme` | `'standardmcp'` | URI scheme of the templates (RFC 3986) |
| `exception_reporter` | `nil` (the mcp gem's) | Called with unexpected errors |
| `lint_ignore_columns` | `%w[id created_at updated_at]` | Columns `standard_mcp:lint` doesn't expect comments on |

Argument validation against each tool's input schema is always on.

## Auditing and verification

Run these in your app (`bundle exec rake ...`).

### `rake standard_mcp:lint`: missing context

Lists the tables and columns exposed through MCP that have no comment: every
MCP-enabled controller's model and the models reachable through its permitted
includes and nested attributes, minus ACL-excluded columns and
`lint_ignore_columns`. A missing database comment is reported too.

```
$ bundle exec rake standard_mcp:lint
StandardMCP comment lint
ACLs are evaluated for an anonymous request; per-request ACLs may expose more to some callers.
Ignored columns: id, created_at, updated_at

accounts (Account)
  notes has no comment
photos (Photo)
  caption has no comment

Summary: 2 missing comments (2 columns) across 4 tables checked
```

| ENV | Effect |
| --- | --- |
| `STRICT=1` | Exit 1 when anything is missing (for CI) |
| `IGNORE_COLUMNS=id,created_at` | Override `lint_ignore_columns` for one run |
| `DATABASE_COMMENT=0` | Don't check the database comment |

ACL methods are evaluated for an anonymous request, so ACLs that depend on the
caller may expose more to some callers than is checked. In code:
`StandardMCP::Lint.run(io: $stdout, strict: false)` returns the findings.

### `rake standard_mcp:tools`: what a caller sees

Prints the server instructions, `tools/list` and resource templates for a
caller, without a client:

```
$ HEADERS='X-MCP-Writes: true' FORMAT=summary bundle exec rake standard_mcp:tools
list_accounts           1588  List accounts.
get_account              743  Get one account by id.
create_contact          1007  Create one contact.
...
describe_query           855  Describe how to query a resource: the keys of where and order with their types and operators, and the associations to include.
describe_attributes     1010  Describe a resource's records as JSON Schemas: "read" is a record as the list and get tools return it and, for callers who may write, "write" is what create and update accept (types, enums, defaults, readOnly, required and validation constraints).

13 tools, 13830 characters (instructions: 1163 characters)
3 resource templates, 841 characters: standardmcp://schema/{resource}, standardmcp://accounts/{id}, standardmcp://properties/{id}
```

| ENV | Effect |
| --- | --- |
| `HEADERS` | `Name: value` pairs separated by `;` or newlines (a value containing `;` goes on its own line) |
| `FORMAT=json` (default) / `summary` | Full `{"instructions", "tools", "resourceTemplates"}` JSON, or a line per tool with its size in compact-JSON characters |
| `TOOL=list_accounts` | Only that tool (`describe_query`, say) |
| `URI=standardmcp://schema/accounts` | What reading that URI returns (or the "Resource not found" it answers) |

Conditions and ACLs see only the headers you pass: no session, and no cookies
unless you pass a `Cookie` header. Use it to check per-role hiding (run it with
an admin's and a viewer's token) and to keep an eye on `tools/list` size. In
code: `StandardMCP::Preview.call(headers:, format:, tool:, uri:, io:)`.

### Try it

With the app running:

```
npx @modelcontextprotocol/inspector
```

Connect to `http://localhost:3000/mcp` with the "Streamable HTTP" transport,
adding an `Authorization` header if your app needs one.

### Result validation in development

`config.output_schema = true` makes the tools declare output schemas, and
`validate_results` (on outside production) then checks every result against
them, which catches drift between the schemas and what your views render.

## Development

Working on the gem itself needs a local Postgres; the test app uses the
`standardmcp-test` database.

```
bundle install
bundle exec rake test
```
