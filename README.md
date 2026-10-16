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
  range) are tool errors in plain words, without SQL.

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
  config.instructions = ->(request) { '...' } # String or callable; default: the database comment
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
- `exception_reporter`: called with unexpected errors; nil keeps the mcp gem's.

Argument validation against the tool's input schema is always on.

## Development

Requires a local Postgres. The test app uses the `standardmcp-test` database.

```
bundle install
bundle exec rake test
```
