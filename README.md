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
- [Resources and `describe`](#resources-and-describe)
- [Application context from the database](#application-context-from-the-database)
- [Mounting and authentication](#mounting-and-authentication)
- [Configuration](#configuration)
- [Auditing and verification](#auditing-and-verification)
- [Development](#development)

## Requirements

- Ruby 3.2+, Rails 8.0+
- StandardAPI 9.0+ (your controllers include `StandardAPI::Controller`, ACLs
  in `app/controllers/acl`)
- PostgreSQL: table and column comments are the application context, and the
  filter operators are activerecord-filter's Postgres set. This is what the gem
  is tested against.

## Installation

StandardAPI 9 isn't released to RubyGems yet (RubyGems has 7.1.4), and neither
is StandardMCP, so both come from git for now. Pin refs:

```ruby
# Gemfile
gem 'standardapi', git: 'https://github.com/waratuman/standardapi.git', ref: '6222967041a6b0c243e1e8aec33dfc2eb13167aa'
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
| ACL `attributes` (strong params) | The write tools' typed attributes; anything else is rejected, and keys a per-record ACL drops come back as `ignored_attributes` |
| ACL `nested` | Nested records in create/update, as StandardAPI accepts them (`photos`, `photo_ids`, foreign keys) |
| ACL `includes` | The `include` argument and the associations `where` can filter on |
| ACL `orders` | The `order` argument |
| ACL `excludes` | Excluded attributes are absent from responses and from every schema and description |
| `mask_for` | Row-level restriction on every read, count, update and delete; a masked id reads as "not found" |
| `resource_limit` / `default_limit` | The `limit` maximum and default (`config.default_limit` when the controller has none) |
| activerecord-filter (`where`) | Filtering with operator objects, checked against the model before the call |
| `calculate` | `calculate_*` tools (count, sum, min, max, average, `group_by`) and the `total` of list pages |
| jbuilder views (`_record`, includes, eager loading) | The JSON the tools return, identical to your JSON API |
| `json_schema` view | Output schemas, when you turn them on |
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

Plus `describe` ([below](#resources-and-describe)). Reads are annotated
read-only and idempotent; create is neither destructive nor idempotent; update
and delete are destructive and idempotent.

Results are JSON as your API renders it, as both `structuredContent` and text:
`{"records": [...], "offset": 0, "next_offset": 25, "total": 112}` for lists
(`total` only when the caller may also use `calculate`; `next_offset` is null on
the last page), `{"record": {...}}` for get, create and update, `{"result": ...}`
for calculate and `{"success": true, "affected_rows": 1}` for delete.

### Filtering

`where` takes an operator object per column, and associations nest:

```json
{"where": {"size": {"gte": 1000}, "kind": {"in": ["office", "retail"]},
           "name": {"not": null}, "account": {"name": {"ilike": "%acme%"}}}}
```

An array alternating filters with `"AND"`/`"OR"` combines them. By default the
schema keeps `where` a plain object and its description lists the columns
(type, enum values, comment), the operators per column type and the
associations, which keeps `tools/list` small. Calls are checked against the
model before they run, so an unknown column, an operator that doesn't fit the
type or a bad enum value is a readable tool error, not an empty result. Set
`input_schema_depth = 'deep'` to have the schema spell all of it out instead.

### Writes

The record goes under its singular name, as `params.require` expects:
`{"property": {"name": "Tower", "kind": "office"}, "include": {"photos": true}}`.

- The attributes are the ACL's `attributes`, typed from the columns, with
  their comments. Ids, timestamps, database-filled columns and excluded ones
  aren't accepted.
- Required on create: permitted NOT NULL or presence-validated attributes
  without a default. An update needs at least one attribute.
- Validators become input constraints where that's safe (enums, `length`,
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

## Resources and `describe`

The tool schemas stay shallow; the full detail is one call or read away.

- **`describe`** takes `{"resource": "properties"}` (the controller path with
  `/` as `_`; its enum lists the caller's own) and returns a compact document:
  the table comment, the caller's tools, every column (type, nullable,
  comment, enum, orderable, writable), every association (kind, the resource
  serving it, whether it can be included, filtered or written through) and the
  `where` rules once per column type. List, calculate, create and update
  descriptions end with a pointer to it.
- **`standardmcp://schema/{resource}`** is the same document as a resource
  template, for clients that read resources.
- **`standardmcp://<resource>/{id}`** (e.g. `standardmcp://accounts/42`) is a
  template per controller the caller may `show`, so a user can attach a
  record as context. Reading it is a dispatched `show`.

Everything is built for the caller. A schema is readable when the caller has
any MCP action on that controller; masked, missing, forbidden and unknown URIs
all answer the same "Resource not found" (JSON-RPC -32602). Record reads have
no `include` (the `mcp` gem only matches plain `{var}` placeholders). The
endpoint serves templates only (`resources/list` is empty) and is stateless, so
there are no subscriptions. How a client shows templates or lets the model read
them is up to the client, which is why `describe` is also a tool.

## Application context from the database

The gem reads your application's context from Postgres comments, so the
documentation lives with the schema and is read fresh on every request (no
caching; a migration that changes a comment shows up immediately):

| Comment | Read with | Becomes |
| --- | --- | --- |
| Database | `connection.database_comment` (StandardAPI) | The opening paragraph of the server instructions |
| Table | `connection.table_comment(table)` | Tool descriptions, the table's line in the instructions, the `describe` document |
| Column | `column.comment` | The column's line in `where`, its description in write inputs and nested records, the `describe` document |
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

Conventions: list_* tools return one page; pass the result's next_offset as offset to get the next. Filters (where) take operator objects such as {"size": {"gte": 1000}}; a tool's where description lists its columns and operators. include embeds associations in the result. describe {"resource": "accounts"} returns a resource's columns, types, enums, operators and associations.
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
| `input_schema_depth` | `'shallow'` | `'shallow'`: `where` and nested write records are loose objects described in prose, and calls are checked before dispatch. `'deep'`: both are fully typed in the schema |
| `where_depth` | `1` | Deep mode only: association levels `where` spells out, bounded by the ACL's includes |
| `output_schema` | `false` | Declare an `outputSchema` per tool (from StandardAPI's `json_schema` view; about a quarter more `tools/list`). Results carry `structuredContent` either way |
| `validate_results` | on outside production | Check results against the output schema (needs `output_schema`) |
| `resources` | `%i[schema records]` | Resource templates served; `[]` for none (and `resources` isn't advertised) |
| `describe_tool` | `true` | The `describe` tool and the pointers to it |
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
list_accounts           3136  List accounts.
get_account              905  Get one account by id.
create_contact          1438  Create one contact.
...
describe                 494  Describe a resource: its columns with types, enums and filter operators, and its associations.

12 tools, 25244 characters (instructions: 974 characters)
3 resource templates, 719 characters: standardmcp://schema/{resource}, standardmcp://accounts/{id}, standardmcp://properties/{id}
```

| ENV | Effect |
| --- | --- |
| `HEADERS` | `Name: value` pairs separated by `;` or newlines (a value containing `;` goes on its own line) |
| `FORMAT=json` (default) / `summary` | Full `{"instructions", "tools", "resourceTemplates"}` JSON, or a line per tool with its size in compact-JSON characters |
| `TOOL=list_accounts` | Only that tool |
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
