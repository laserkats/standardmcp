# StandardMCP

> Status: pre-release / work in progress. The API below is planned, not final.

StandardMCP exposes [StandardAPI](https://github.com/waratuman/standardapi)
resources as [MCP](https://modelcontextprotocol.io) tools using the official
`mcp` gem. Tool calls are dispatched in-process to the StandardAPI controller
actions, so ACLs, masking, excludes and rendering are reused.

## Install

```ruby
gem "standardmcp"
```

## Planned usage

```ruby
class AccountsController < ApplicationController
  include StandardAPI::Controller

  # Read-only for everyone.
  allow_mcp only: [:index, :show, :calculate]
  # Writes only for admins.
  allow_mcp only: [:create, :update], if: :admin?
end

# config/routes.rb
standard_mcp "/mcp"
```

`allow_mcp` takes `only:`, `except:`, `if:` and `unless:`, modelled on
`before_action`. The controller must include `StandardAPI::Controller`.

- Exposable actions are `index`, `show`, `create`, `update`, `destroy` and
  `calculate`. Unknown names raise `ArgumentError`.
- `only:` and `except:` are mutually exclusive. With neither, every exposable
  action the controller actually has is covered.
- `if:` / `unless:` accept a Symbol (a controller method, private allowed), a
  Proc (zero arity runs with `instance_exec`, otherwise it is called with the
  controller) or an Array of these. All `if:` must be truthy and all `unless:`
  falsy.
- `allow_mcp` can be called several times. An action is exposed when any rule
  covers it and that rule's conditions pass. Subclasses inherit rules and may
  add their own.
- Conditions run per request on a controller instance bound to the MCP request,
  so `current_user`, `request`, `params` and `headers` are available. When they
  fail, the tool is hidden from `tools/list` (and refused on call).
- Row-level restriction is not handled here; use StandardAPI's `mask_for`.
- Table and column comments (Postgres) become tool and parameter descriptions.

## Tools

One tool per allowed (controller, action). Controller paths become names
(`admin/accounts` is `list_admin_accounts` and `get_admin_account`).

| Action      | Tool                | Arguments                                         |
| ----------- | ------------------- | ------------------------------------------------- |
| `index`     | `list_accounts`     | `where`, `order`, `include`, `limit`, `offset`, `distinct` |
| `show`      | `get_account`       | `id`, `include`                                   |
| `calculate` | `calculate_accounts`| `where`, `select`, `group_by`                     |
| `create`    | `create_account`    | `account` (required), `include`                   |
| `update`    | `update_account`    | `id`, `account` (both required), `include`        |
| `destroy`   | `delete_account`    | `id`                                              |

Annotations: reads are read-only and idempotent; create is neither destructive
nor idempotent; update and delete are destructive and idempotent.

### Writes

The record goes under its singular name, as StandardAPI's `params.require`
wants it: `{"property": {"name": "Tower"}, "include": {"photos": true}}`. The
attributes are the ACL's `attributes` list, typed from the columns with the
column comments as descriptions, and the tool rejects anything else.

- `required` on create: a permitted NOT NULL column or presence-validated
  attribute that has no default. An update needs at least one attribute and
  none in particular.
- Validators become keywords where that is safe for input: enums (AR enums and
  unconditional `inclusion`), `length`, `numericality` bounds and `format`
  (only when the Ruby regexp means the same in ECMA 262, else the description
  says "Must match /.../"). Validators with `if:`, `unless:` or a non-matching
  `on:` are left to Rails, whose errors come back as tool errors with `errors`.
  `null` is offered only for nullable columns. Ids, timestamps, database-filled
  and (on update) `attr_readonly` columns, and columns an ACL `excludes` hides,
  are not accepted.
- Nested attributes (an ACL `nested` list) are accepted as StandardAPI does:
  the association as an object (or an array of objects), each with an optional
  `id` to update an existing record, `<association>_ids`, and the foreign key
  of a `belongs_to`. A nested collection replaces the whole set. With
  `input_schema_depth = 'deep'` they are typed from the nested model's own ACL;
  by default (`'shallow'`) the association is a loose object and its
  description lists the permitted attributes (`name (type): comment`), while
  the top-level attributes stay typed. StandardAPI and ActiveRecord check the
  nested values then, and their problems come back as tool errors.
- The ACL is asked for the schema without a record (`attributes(nil)`). A
  per-record `attributes(record)` can therefore still drop a key the schema
  accepted. StandardAPI drops such keys silently, so the result reports them as
  `ignored_attributes` (`["size", "photos.internal_path"]`) when there are
  any. For an update they are worked out from the record as StandardAPI finds
  it (through the controller's own `resources`, so `mask_for` applies); a
  create asks about a new record, nested records are always judged as new ones
  and a lookup that fails falls back to the nil-record list.
- A masked or missing id is `"Property not found"` for update and delete,
  whatever the mask. Delete returns `{"success": true, "affected_rows": 1}`.
  Constraints only the database knows (foreign key, NOT NULL, unique, out of
  range) are tool errors in plain words, without SQL. A write a model callback
  refuses (`throw :abort`) says why in the model's own errors:
  `"Contact could not be deleted: Locked contacts cannot be deleted"` (just
  `"Contact could not be deleted"` when it added none).

## Context from comments

The gem takes the application's context from database comments (Postgres), so
the documentation lives with the schema and can't drift from it:

| Comment            | Becomes                                                                 |
| ------------------ | ----------------------------------------------------------------------- |
| database           | the opening paragraph of the server instructions                        |
| table              | the tool descriptions, and the table's line in the instructions         |
| column             | the description of the column in `where`, in write inputs and nested records |
| foreign key column | the description of its association (else the associated table's comment) |

Write them in migrations:

```ruby
create_table :accounts, comment: 'A customer organization that owns properties.' do |t|
  t.string :name, comment: 'Display name of the organization.'
end

add_column :accounts, :status, :string, comment: 'Lifecycle status: active or suspended.'
change_table_comment :accounts, from: nil, to: 'A customer organization.'
change_column_comment :accounts, :notes, from: nil, to: 'Free-form notes from sales.'
```

The database comment is set with `COMMENT ON DATABASE app IS '...'` (StandardAPI
reads it back as `connection.database_comment`).

Say what a value means rather than what its column is called: the lifecycle
behind a `status`, the unit of a `size`, how a hierarchy is stored. `rake
standard_mcp:lint` lists what is still missing.

### Server instructions

The instructions sent when a client connects are generated from those comments,
for the request at hand (what `allow_mcp` hides from the caller is left out):

```
Property management data: customer accounts, the properties they own and the people to reach.

Resources:
accounts: A customer organization that owns properties. Tools: list_accounts, get_account, calculate_accounts.
properties: A real estate asset owned by an account. Tools: list_properties, get_property.

Conventions: list_* tools return one page; pass the result's next_offset as offset to get the next. Filters (where) take operator objects such as {"size": {"gte": 1000}}; a tool's where description lists its columns and operators. include embeds associations in the result.
```

A model without a table comment is still listed, with its tools. The operators
and columns stay in each tool's `where` description, so every tool is
self-contained and the instructions stay short.

`config.instructions` changes them:

```ruby
# Add domain context to the generated text (a callable taking two arguments):
config.instructions = ->(request, default) do
  "#{default}\n\nSizes are in square feet. A TIM is a tenant improvement allowance."
end

# Replace it (a String, or a callable taking the request):
config.instructions = 'Use these tools carefully.'
config.instructions = ->(request) { "Hello #{request.headers['X-Who']}" }

# Send none:
config.instructions = false
```

A callable that returns nothing falls back to the generated text. The text is
only worked out for `initialize` (and `server/discover`), not for every call.

## Checking the result

Both tasks run in the host app (`bundle exec rake ...`).

### `rake standard_mcp:lint`

Lists the tables and columns exposed through MCP tools that have no comment:
every MCP-enabled controller's model, and the models reachable through its
permitted includes and nested attributes. A column counts when the ACL's
`excludes` doesn't hide it; `id`, `created_at` and `updated_at` are skipped
(`config.lint_ignore_columns`, or `IGNORE_COLUMNS=id,created_at` for one run).

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

The exit status is 0 unless `STRICT=1` is set and something is missing, which
makes it usable in CI (`STRICT=1 bundle exec rake standard_mcp:lint`). A missing
database comment is reported too; `DATABASE_COMMENT=0` skips that. The logic is
`StandardMCP::Lint.run(io: $stdout, strict: false)`, which returns the findings.

ACL methods need a request, so they are evaluated for an anonymous one. A
controller whose `attributes`, `includes` or `excludes` depend on the caller may
expose more to some callers than is checked here.

### `rake standard_mcp:tools`

Prints the server instructions and `tools/list` a caller would get, without a
client:

```
$ HEADERS='X-MCP-Writes: true' FORMAT=summary bundle exec rake standard_mcp:tools
list_accounts           3075  List accounts.
get_account              905  Get one account by id.
create_contact          1378  Create one contact.
...
11 tools, 24258 characters (instructions: 868 characters)
```

- `HEADERS`: `Name: value` pairs separated by `;` or newlines (a value that
  contains `;` goes on a line of its own).
- `FORMAT`: `json` (the default: `{"instructions": ..., "tools": [...]}`) or
  `summary` (a line per tool with its size in compact-JSON characters and the
  first sentence of its description, then the total).
- `TOOL=list_accounts`: only that tool (its full definition for `json`).

Per-request ACLs and `allow_mcp` conditions are evaluated with the given
headers only: there is no session, and no cookies unless you pass a `Cookie`
header. The call is `StandardMCP::Preview.call(headers:, format:, tool:, io:)`.

## Mounting the endpoint

```ruby
# config/routes.rb
standard_mcp '/mcp'
```

routes POST, GET and DELETE `/mcp` (named `standard_mcp`) to
`StandardMCP::ServerController#handle`. That controller inherits from
`config.parent_controller` (`ApplicationController` by default) and is defined
again after every code reload.

To own the controller (to add callbacks, say), include the endpoint and route
to it:

```ruby
class McpController < ApplicationController
  include StandardMCP::Endpoint
end

# config/routes.rb
standard_mcp '/mcp', to: 'mcp#handle'
```

The endpoint is stateless and answers with plain JSON: a server (and its tools)
is built for every request, so what a caller sees depends on that caller. There
are no sessions, no SSE stream and no server-initiated messages; GET answers 405.
A `tools/call` builds only the tool it names.

### Authentication

The gem does no authentication. Callbacks of the controller (its parent's
`before_action`s) run first, so authenticate there and render a 401 (with a
`WWW-Authenticate` header) for MCP clients; `config.parent_controller` can point
at a controller that does only that. Tool calls then run in-process with the
caller's credentials (Authorization, Cookie, remote address, host), so
`current_user`, ACLs and `mask_for` resolve as for a normal request.
`config.dispatch_env` adds more Rack env entries (an internal-user key, say).

- CSRF: the endpoint skips forgery protection, which is safe because the
  transport only accepts `Content-Type: application/json`, which a cross-site
  form or no-preflight request can't send. The in-process calls themselves run
  your `protect_from_forgery` like any request, so write tools need
  bearer-style authentication or a `verified_request?` that honors a key set
  through `dispatch_env`; otherwise a write comes back as a tool error.
- Origin: a request with an `Origin` header must be same-origin or match
  `config.allowed_origins`, else 403. Requests without one (non-browser
  clients) pass.
- Host (DNS rebinding): left to Rails; set `config.hosts` in production.

### Try it

```
npx @modelcontextprotocol/inspector
```

and connect to `http://localhost:3000/mcp` with the "Streamable HTTP" transport
(add an `Authorization` header if your app needs one).

## Configuration

```ruby
StandardMCP.configure do |config|
  config.server_name = 'my-app'              # default: the app's module name
  config.server_version = '1.0.0'            # default: the gem's version
  config.parent_controller = 'ApplicationController'
  config.instructions = ->(request, default) { "#{default}\n\n..." } # default: generated from comments; see above
  config.lint_ignore_columns = %w[id created_at updated_at]
  config.dispatch_env = ->(request) { {} }
  config.default_limit = 25
  config.input_schema_depth = 'shallow'      # or 'deep'
  config.where_depth = 1                     # only used by 'deep'
  config.output_schema = false
  config.validate_results = nil              # default: on outside production
  config.allowed_origins = nil               # e.g. ['https://claude.ai', /\Ahttps:\/\/.*\.example\.com\z/]
  config.exception_reporter = ->(exception, server_context) { Rails.error.report(exception) }
end
```

- `input_schema_depth`: `'shallow'` leaves `where` a bare object and lists the
  filterable columns in the tool description (a fraction of the tokens; calls are
  checked against the model before they run), and likewise leaves the nested
  records of a write loose. `'deep'` spells out `where` in the schema, nested
  associations up to `where_depth`, and the nested records of a write, and the
  server rejects bad filters and nested values by schema validation.
- `output_schema`: declare an `outputSchema` per tool (about a quarter more
  `tools/list`). `structuredContent` is returned either way.
- `validate_results`: check results against the output schema; only has an
  effect with `output_schema`.
- `default_limit`: page size for `index` when neither the controller nor the
  caller sets one.
- `allowed_origins`: Strings (exact) and/or Regexps accepted besides the
  endpoint's own origin; nil accepts only that. Regexps are anchored to the
  whole origin, so `/https:\/\/[a-z]+\.example\.com/` won't accept
  `https://app.example.com.evil.example`.
- `instructions`: nil generates them from the comments; a String or a callable
  taking the request replaces that, a callable taking the request and the
  generated text adds to it, false sends none.
- `lint_ignore_columns`: columns `standard_mcp:lint` doesn't expect a comment on.
- `exception_reporter`: called with unexpected errors; nil keeps the mcp gem's.

Argument validation against the tool's input schema is always on.

## Development

Requires a local Postgres. The test app uses the `standardmcp-test` database.

```
bundle install
bundle exec rake test
```
