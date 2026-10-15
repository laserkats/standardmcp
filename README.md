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

# config/routes.rb (planned)
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

## Development

Requires a local Postgres. The test app uses the `standardmcp-test` database.

```
bundle install
bundle exec rake test
```
