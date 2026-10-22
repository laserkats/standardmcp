require 'standard_mcp/test_helper'

# Permits a filter key that is neither a column nor an association, which
# StandardAPI's ACL check lets through to activerecord-filter.
class DispatcherPhantomWhereController < ApplicationController
  allow_mcp

  def self.model
    Property
  end

  def property_wheres
    super + [:foo]
  end
end

# Says whether the request it runs for is MCP's.
class DispatcherFlagController < ApplicationController
  allow_mcp only: [:index]

  def self.model
    Account
  end

  def index
    render json: { mcp: mcp_request? }
  end
end

# Records the where its ACL's schemas hook saw.
class DispatcherSchemaController < ApplicationController
  allow_mcp only: [:index, :update]

  cattr_accessor :seen

  def self.model
    Property
  end

  def property_schemas(schemas)
    self.class.seen = params[:where]&.to_unsafe_h
    schemas
  end
end

class DispatcherUpdateOnlyController < ApplicationController
  allow_mcp only: [:update]

  def self.model
    Property
  end
end

class DispatcherDestroyOnlyController < ApplicationController
  allow_mcp only: [:destroy]

  def self.model
    Property
  end
end

class DispatcherTest < ActiveSupport::TestCase

  def request_for(headers = {}, env = {})
    headers = headers.transform_keys { |k| "HTTP_#{k.upcase.tr('-', '_')}" }
    ActionDispatch::Request.new(Rack::MockRequest.env_for('/mcp', headers.merge(env)))
  end

  def dispatch(klass, action, params = {}, headers = {}, env = {})
    StandardMCP::Dispatcher.new(request_for(headers, env)).call(klass, action, params)
  end

  # Writes enabled, and a bearer token so CSRF verification passes.
  def writes(account_id = 0)
    { 'X-MCP-Writes' => 'true', 'Authorization' => "Bearer #{account_id}" }
  end

  # --- reads

  test "index returns StandardAPI JSON" do
    account = create(:account)

    result = dispatch(AccountsController, :index, { 'limit' => 10 })

    assert_equal 200, result.status
    assert_kind_of Hash, result.headers
    assert_kind_of String, result.body
    assert_equal [account.id], result.json.map { |a| a['id'] }
    assert_equal account.name, result.json.first['name']
  end

  test "show returns the record" do
    account = create(:account)

    result = dispatch(AccountsController, :show, { 'id' => account.id })

    assert_equal 200, result.status
    assert_equal account.id, result.json['id']
    assert_equal account.status, result.json['status']
  end

  test "calculate returns aggregates" do
    create_list(:account, 3)

    result = dispatch(AccountsController, :calculate, { 'select' => [{ 'count' => '*' }] })

    assert_equal 200, result.status
    assert_equal [3], result.json
  end

  test "where, limit and order are applied" do
    create(:account, name: 'b')
    create(:account, name: 'c')
    create(:account, name: 'a')

    result = dispatch(AccountsController, :index,
      { 'where' => { 'name' => { 'in' => ['a', 'b'] } }, 'order' => { 'name' => 'desc' }, 'limit' => 1 })

    assert_equal ['b'], result.json.map { |a| a['name'] }
  end

  test "include loads associations" do
    property = create(:property)

    result = dispatch(AccountsController, :show, { 'id' => property.account_id, 'include' => ['properties'] })

    assert_equal [property.id], result.json['properties'].map { |p| p['id'] }
  end

  test "ACL excludes are still applied" do
    photo = create(:photo)

    result = dispatch(PropertiesController, :show, { 'id' => photo.property_id, 'include' => ['photos'] })

    photos = result.json['photos']
    assert_equal [photo.id], photos.map { |p| p['id'] }
    assert_equal photo.caption, photos.first['caption']
    refute photos.first.key?('internal_path')
    refute_includes result.body, photo.internal_path
  end

  # --- masks and auth forwarding

  test "mask_for restricts rows through the forwarded Authorization header" do
    mine = create(:account)
    other = create(:account)

    all = dispatch(AccountsController, :index, { 'limit' => 10 })
    scoped = dispatch(AccountsController, :index, { 'limit' => 10 }, 'Authorization' => "Bearer #{mine.id}")

    assert_equal [mine.id, other.id].sort, all.json.map { |a| a['id'] }.sort
    assert_equal [mine.id], scoped.json.map { |a| a['id'] }
  end

  test "mask_for applies to other controllers' tables" do
    mine = create(:property)
    create(:property)

    result = dispatch(PropertiesController, :index, { 'limit' => 10 }, 'Authorization' => "Bearer #{mine.account_id}")

    assert_equal [mine.id], result.json.map { |p| p['id'] }
  end

  test "show of a masked record is a 404 Result, not a raise" do
    mine = create(:account)
    other = create(:account)

    result = dispatch(AccountsController, :show, { 'id' => other.id }, 'Authorization' => "Bearer #{mine.id}")

    assert_equal 404, result.status
    assert_equal({ 'error' => 'Account not found' }, result.json)
  end

  test "404 body does not leak the query" do
    result = dispatch(AccountsController, :show, { 'id' => 0 }, 'Authorization' => 'Bearer 5')

    assert_equal 404, result.status
    refute_match(/WHERE|SELECT|accounts/i, result.body)
  end

  test "session is readable through the snapshot but writes stay detached" do
    mine = create(:account)
    create(:account)
    outer = { 'account_id' => mine.id }

    result = dispatch(AccountsController, :index, { 'limit' => 10 }, {}, 'rack.session' => outer)

    assert_equal [mine.id], result.json.map { |a| a['id'] }
    assert_equal({ 'account_id' => mine.id }, outer, 'inner request must not write the outer session')
  end

  test "request context is forwarded" do
    env = {}
    ActiveSupport::Notifications.subscribed(->(*, payload) { env.update(payload) }, 'process_action.action_controller') do
      dispatch(AccountsController, :index, { 'limit' => 1 },
        { 'User-Agent' => 'mcp-client/1.0', 'Cookie' => 'a=b', 'Host' => 'api.example.com' },
        'REMOTE_ADDR' => '10.1.2.3')
    end

    assert_equal 'api.example.com', env[:headers]['Host']
    assert_equal 'mcp-client/1.0', env[:headers]['User-Agent']
    assert_equal 'a=b', env[:headers]['Cookie']
  end

  test "dispatch_env is merged into the inner request" do
    seen = nil
    StandardMCP.config.dispatch_env = ->(request) {
      { 'standardmcp.test.user' => request.headers['X-User'] }
    }
    ActiveSupport::Notifications.subscribed(->(*, payload) { seen = payload[:headers]['standardmcp.test.user'] }, 'process_action.action_controller') do
      dispatch(AccountsController, :index, { 'limit' => 1 }, 'X-User' => 'sam')
    end

    assert_equal 'sam', seen
  end

  test "every dispatched request carries the dispatched flag" do
    seen = nil
    ActiveSupport::Notifications.subscribed(->(*, payload) { seen = payload[:headers][StandardMCP::DISPATCHED_ENV] }, 'process_action.action_controller') do
      dispatch(AccountsController, :index, { 'limit' => 1 })
    end

    assert_equal true, seen
    assert_equal 'standardmcp.dispatched', StandardMCP::DISPATCHED_ENV
  end

  test "dispatch_env can't drop or change the dispatched flag" do
    seen = nil
    StandardMCP.config.dispatch_env = ->(request) { { StandardMCP::DISPATCHED_ENV => false } }
    ActiveSupport::Notifications.subscribed(->(*, payload) { seen = payload[:headers][StandardMCP::DISPATCHED_ENV] }, 'process_action.action_controller') do
      dispatch(AccountsController, :index, { 'limit' => 1 })
    end

    assert_equal true, seen
  end

  test "the dispatched controller answers true to mcp_request?" do
    assert_equal({ 'mcp' => true }, dispatch(DispatcherFlagController, :index).json)

    StandardMCP.config.dispatch_env = ->(request) { { StandardMCP::DISPATCHED_ENV => nil } }
    assert_equal({ 'mcp' => true }, dispatch(DispatcherFlagController, :index).json)
  end

  # --- routing context

  test "path parameters, format and path are set" do
    account = create(:account)
    payload = nil

    ActiveSupport::Notifications.subscribed(->(*, p) { payload = p }, 'process_action.action_controller') do
      dispatch(AccountsController, :show, { 'id' => account.id })
    end

    assert_equal 'AccountsController', payload[:controller]
    assert_equal 'show', payload[:action]
    assert_equal :json, payload[:format]
    assert_equal "/accounts/#{account.id}", payload[:path]
    assert_equal 'GET', payload[:method]
    assert_equal account.id.to_s, payload[:params]['id']
    assert_equal 'accounts', payload[:params]['controller']
  end

  test "index path has no id and uses GET" do
    payload = nil
    ActiveSupport::Notifications.subscribed(->(*, p) { payload = p }, 'process_action.action_controller') do
      dispatch(AccountsController, :index, { 'limit' => 1 })
    end

    assert_equal '/accounts', payload[:path]
    assert_equal 'GET', payload[:method]
    assert_nil payload[:params]['id']
  end

  test "path parameters cannot be overridden by tool arguments" do
    payload = nil
    ActiveSupport::Notifications.subscribed(->(*, p) { payload = p }, 'process_action.action_controller') do
      dispatch(AccountsController, :index, { 'limit' => 1, 'controller' => 'photos', 'action' => 'destroy', 'format' => 'html' })
    end

    assert_equal 'AccountsController', payload[:controller]
    assert_equal 'index', payload[:action]
    assert_equal :json, payload[:format]
  end

  test "HTTP methods follow the action" do
    assert_equal({ index: 'GET', show: 'GET', calculate: 'GET', create: 'POST', update: 'PATCH', destroy: 'DELETE',
      read_schema: 'GET', write_schema: 'GET' }, StandardMCP::Dispatcher::METHODS)
  end

  # --- writes

  test "create returns 201 with the record" do
    account = create(:account)

    result = dispatch(PropertiesController, :create,
      { 'property' => { 'name' => 'Tower', 'account_id' => account.id } }, writes)

    assert_equal 201, result.status
    assert_equal 'Tower', result.json['name']
    assert_equal 'Tower', Property.find(result.json['id']).name
  end

  test "create with invalid attributes is a 400 with StandardAPI's error body" do
    account = create(:account)

    result = dispatch(PropertiesController, :create,
      { 'property' => { 'name' => '', 'account_id' => account.id } }, writes)

    assert_equal 400, result.status
    assert_equal({ 'name' => ["can't be blank"] }, result.json['errors'])
    assert_equal 0, Property.count
  end

  test "update returns 200 and persists" do
    property = create(:property)

    result = dispatch(PropertiesController, :update,
      { 'id' => property.id, 'property' => { 'name' => 'Renamed' } }, writes(property.account_id))

    assert_equal 200, result.status
    assert_equal 'Renamed', result.json['name']
    assert_equal 'Renamed', property.reload.name
  end

  test "attributes outside the ACL are dropped" do
    property = create(:property)
    original = property.created_at

    result = dispatch(PropertiesController, :update,
      { 'id' => property.id, 'property' => { 'name' => 'Ok', 'created_at' => '2001-01-01T00:00:00Z' } }, writes(property.account_id))

    assert_equal 200, result.status
    assert_equal original.to_i, property.reload.created_at.to_i
  end

  test "writes without forgery verification come back as a 422 Result" do
    account = create(:account)

    result = dispatch(PropertiesController, :create,
      { 'property' => { 'name' => 'Tower', 'account_id' => account.id } }, 'X-MCP-Writes' => 'true')

    assert_equal 422, result.status
    assert_equal 0, Property.count
  end

  test "a dispatch_env key honored by verified_request? lets writes through" do
    account = create(:account)
    StandardMCP.config.dispatch_env = ->(request) { { ApplicationController::VERIFIED_ENV => true } }

    result = dispatch(PropertiesController, :create,
      { 'property' => { 'name' => 'Tower', 'account_id' => account.id } }, 'X-MCP-Writes' => 'true')

    assert_equal 201, result.status
  end

  test "destroy returns 204 and the affected rows" do
    contact = create(:contact)

    result = dispatch(ContactsController, :destroy, { 'id' => contact.id }, writes(contact.account_id))

    assert_equal 204, result.status
    assert_equal '1', result.headers.find { |key, _| key.casecmp?('Affected-Rows') }&.last.to_s
    refute Contact.exists?(contact.id)
  end

  test "destroy of a masked record is a 404 that names only the model" do
    mine = create(:account)
    other = create(:contact)

    result = dispatch(ContactsController, :destroy, { 'id' => other.id }, writes(mine.id))

    assert_equal 404, result.status
    assert_equal({ 'error' => 'Contact not found' }, result.json)
    assert Contact.exists?(other.id)
  end

  test "constraints only the database knows are 4xx results, in plain words" do
    {
      ActiveRecord::NotNullViolation => [400, 'A required value is missing'],
      ActiveRecord::RecordNotUnique => [409, 'A record with the same unique value already exists'],
      ActiveRecord::InvalidForeignKey => [400, "A foreign key points at a record that doesn't exist"],
      ActiveRecord::ValueTooLong => [400, "A value is out of range, too long or otherwise doesn't fit its column"],
      ActiveModel::RangeError => [400, "A value is out of range, too long or otherwise doesn't fit its column"]
    }.each do |error, (status, message)|
      ContactsController.any_instance.stubs(:create).raises(error, 'INSERT INTO "contacts" secret')

      result = dispatch(ContactsController, :create, { 'contact' => { 'name' => 'x' } }, writes)

      assert_equal status, result.status, error.name
      assert_equal({ 'error' => message }, result.json, error.name)
    end
  end

  test "a foreign key that blocks a destroy says so" do
    ContactsController.any_instance.stubs(:destroy).raises(ActiveRecord::InvalidForeignKey, 'secret')

    result = dispatch(ContactsController, :destroy, { 'id' => 1 }, writes)

    assert_equal 409, result.status
    assert_equal({ 'error' => "Other records still refer to this one, so it can't be deleted" }, result.json)
  end

  test "database errors on a read are still server errors" do
    AccountsController.any_instance.stubs(:index).raises(ActiveRecord::NotNullViolation, 'secret')

    assert_raises(ActiveRecord::NotNullViolation) { dispatch(AccountsController, :index, { 'limit' => 1 }) }
  end

  test "allowed? says whether call would let the action through" do
    dispatcher = StandardMCP::Dispatcher.new(request_for(writes))

    assert dispatcher.allowed?(ContactsController, :destroy)
    assert dispatcher.allowed?(ContactsController, 'create')
    refute dispatcher.allowed?(ContactsController, :index)
    refute dispatcher.allowed?(PropertiesController, :destroy)
    refute StandardMCP::Dispatcher.new(request_for).allowed?(ContactsController, :create)
  end

  # --- read_schema and write_schema

  test "read_schema renders the JSON Schema of a record" do
    result = dispatch(AccountsController, :read_schema)

    assert_equal 200, result.status
    assert_equal 'Account', result.json['title']
    assert_equal 'object', result.json['type']
    assert_equal %w[id name status notes created_at updated_at errors], result.json['properties'].keys
  end

  test "write_schema renders the JSON Schema of the params of create and update" do
    result = dispatch(ContactsController, :write_schema, {}, writes)

    assert_equal 200, result.status
    assert_equal 'Contact', result.json['title']
    assert_equal ['contact'], result.json['properties'].keys
  end

  test "read_schema is allowed with any allowed action on the controller" do
    assert StandardMCP::Dispatcher.new(request_for).allowed?(AccountsController, :read_schema)
    assert StandardMCP::Dispatcher.new(request_for(writes)).allowed?(ContactsController, :read_schema)
    # The schema is reachable by a caller who can only write.
    assert_equal 200, dispatch(ContactsController, :read_schema, {}, writes).status
  end

  test "write_schema is allowed only with create or update on the controller" do
    assert StandardMCP::Dispatcher.new(request_for(writes)).allowed?(ContactsController, :write_schema)
    assert StandardMCP::Dispatcher.new(request_for(writes)).allowed?(PropertiesController, :write_schema)
    assert StandardMCP::Dispatcher.new(request_for).allowed?(DispatcherUpdateOnlyController, :write_schema)

    # Reads and a destroy don't write.
    refute StandardMCP::Dispatcher.new(request_for).allowed?(AccountsController, :write_schema)
    refute StandardMCP::Dispatcher.new(request_for).allowed?(PropertiesController, :write_schema)
    refute StandardMCP::Dispatcher.new(request_for).allowed?(DispatcherDestroyOnlyController, :write_schema)
    refute StandardMCP::Dispatcher.new(request_for).allowed?(ContactsController, :write_schema)
  end

  test "write_schema is refused for a read-only caller" do
    error = assert_raises(StandardMCP::ActionNotAllowed) { dispatch(AccountsController, :write_schema) }
    assert_equal 'write_schema is not allowed on AccountsController', error.message
    assert_raises(StandardMCP::ActionNotAllowed) { dispatch(PropertiesController, :write_schema) }
  end

  test "the schema actions are refused for a controller the caller has no action on" do
    %i[read_schema write_schema].each do |action|
      refute StandardMCP::Dispatcher.new(request_for).allowed?(ContactsController, action)
      refute StandardMCP::Dispatcher.new(request_for).allowed?(ApplicationController, action)
    end

    error = assert_raises(StandardMCP::ActionNotAllowed) { dispatch(ContactsController, :read_schema) }
    assert_equal 'read_schema is not allowed on ContactsController', error.message
  end

  test "the schema actions re-check allow_mcp on every call" do
    request = request_for(writes)
    dispatcher = StandardMCP::Dispatcher.new(request)
    assert_equal 200, dispatcher.call(ContactsController, :read_schema).status
    assert_equal 200, dispatcher.call(ContactsController, :write_schema).status

    request.headers['X-MCP-Writes'] = 'false'
    assert_raises(StandardMCP::ActionNotAllowed) { dispatcher.call(ContactsController, :read_schema) }
    assert_raises(StandardMCP::ActionNotAllowed) { dispatcher.call(ContactsController, :write_schema) }
  end

  test "write_schema takes no include" do
    result = dispatch(ContactsController, :write_schema, { 'include' => { 'account' => true } }, writes)

    assert_equal 200, result.status
    assert_equal dispatch(ContactsController, :write_schema, {}, writes).json, result.json
  end

  test "read_schema and write_schema read the where from the params" do
    %i[read_schema write_schema].each do |action|
      DispatcherSchemaController.seen = nil

      dispatch(DispatcherSchemaController, action, { 'where' => { 'account_id' => 1 } })

      assert_equal({ 'account_id' => 1 }, DispatcherSchemaController.seen, action.to_s)
    end
  end

  test "an action that is not one of the actions or the schema actions is not allowed" do
    refute StandardMCP::Dispatcher.new(request_for).allowed?(AccountsController, :tables)
  end

  # --- StandardAPI error responses

  test "missing limit is a 400 with StandardAPI's message" do
    result = dispatch(AccountsController, :index, {})

    assert_equal 400, result.status
    assert_equal 'param is missing or the value is empty: limit', result.body
    assert_nil result.json
  end

  # --- authorization

  test "destroy on properties is not allowed" do
    property = create(:property)

    assert_raises(StandardMCP::ActionNotAllowed) do
      dispatch(PropertiesController, :destroy, { 'id' => property.id }, writes)
    end
    assert Property.exists?(property.id)
  end

  test "create without the writes header is not allowed" do
    assert_raises(StandardMCP::ActionNotAllowed) do
      dispatch(PropertiesController, :create, { 'property' => { 'name' => 'x' } })
    end
    assert_equal 0, Property.count
  end

  test "actions of controllers that did not opt in are not allowed" do
    assert_raises(StandardMCP::ActionNotAllowed) { dispatch(PhotosController, :index, { 'limit' => 1 }) }
  end

  test "non-tool actions are not allowed" do
    assert_raises(StandardMCP::ActionNotAllowed) { dispatch(AccountsController, :tables) }
  end

  test "string action names are accepted" do
    assert_equal 200, dispatch(AccountsController, 'index', { 'limit' => 1 }).status
  end

  # --- errors

  test "5xx exceptions are re-raised" do
    Account.stubs(:filter).raises(RuntimeError, 'boom')

    assert_raises(RuntimeError) { dispatch(AccountsController, :index, { 'limit' => 1 }) }
  end

  test "client errors Rails maps to 4xx become Results" do
    Account.stubs(:filter).raises(ActionController::BadRequest, 'secret detail')

    result = dispatch(AccountsController, :index, { 'limit' => 1 })

    assert_equal 400, result.status
    assert_equal({ 'error' => 'Bad Request' }, result.json)
  end

  # A filter the model-level check (Schema::Where) would have caught reaches
  # activerecord-filter or Postgres when it is dispatched directly.
  test "an unknown filter column is a 400 Result" do
    result = dispatch(DispatcherPhantomWhereController, :index, { 'where' => { 'foo' => { 'eq' => 1 } }, 'limit' => 1 })

    assert_equal 400, result.status
    assert_equal({ 'error' => "where names a column or association that doesn't exist" }, result.json)
  end

  # StandardAPI checks every where against the ACL's wheres before filtering.
  test "a filter the ACL wheres don't permit is a 400 Result" do
    result = dispatch(PropertiesController, :index, { 'where' => { 'foo' => { 'eq' => 1 } }, 'limit' => 1 })

    assert_equal 400, result.status
    assert_match(/foo/, result.body)
  end

  test "an unsupported filter operator is a 400 Result" do
    result = dispatch(PropertiesController, :index, { 'where' => { 'size' => { 'bogus' => 1 } }, 'limit' => 1 })

    assert_equal 400, result.status
    assert_equal({ 'error' => 'where uses an operator or association filter that is not supported' }, result.json)
  end

  test "an operator Postgres refuses is a 400 Result that leaks neither SQL nor the mask" do
    mine = create(:account)

    result = dispatch(PropertiesController, :index, { 'where' => { 'size' => { 'ilike' => 'a%' } }, 'limit' => 1 },
      'Authorization' => "Bearer #{mine.id}")

    assert_equal 400, result.status
    assert_equal({ 'error' => "where has a value or operator that doesn't fit the column's type" }, result.json)
    refute_match(/SELECT|account_id|ilike|~~/, result.body)
  end

  test "a malformed tsquery is a 400 Result" do
    result = dispatch(PropertiesController, :index, { 'where' => { 'name' => { 'ts_match' => 'a &' } }, 'limit' => 1 })

    assert_equal 400, result.status
    assert_match(/where has a value or operator/, result.json['error'])
  end

  test "other database errors are not filter errors" do
    Account.stubs(:filter).raises(ActiveRecord::StatementInvalid, 'PG::ConnectionBad')

    assert_raises(ActiveRecord::StatementInvalid) { dispatch(AccountsController, :index, { 'limit' => 1 }) }
  end

  # --- Result

  test "Result#json is nil for blank and non-JSON bodies" do
    result = ->(body) { StandardMCP::Dispatcher::Result.new(status: 200, headers: {}, body: body) }

    assert_nil result.call('').json
    assert_nil result.call('  ').json
    assert_nil result.call('nope').json
    assert_equal({ 'a' => 1 }, result.call('{"a":1}').json)
  end

  # --- instrumentation

  test "dispatch.standard_mcp is instrumented" do
    events = []
    ActiveSupport::Notifications.subscribed(->(*args) { events << args.last }, 'dispatch.standard_mcp') do
      dispatch(AccountsController, :index, { 'limit' => 1 })
    end

    assert_equal [{ controller: AccountsController, action: :index }], events
  end

  test "disallowed calls are not instrumented" do
    events = []
    ActiveSupport::Notifications.subscribed(->(*args) { events << args.last }, 'dispatch.standard_mcp') do
      assert_raises(StandardMCP::ActionNotAllowed) { dispatch(AccountsController, :destroy, { 'id' => 1 }) }
    end

    assert_empty events
  end

end
