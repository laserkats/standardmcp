require 'json'
require 'rack/mock'

module StandardMCP
  # Runs a StandardAPI controller action in-process and returns what it
  # rendered. `klass.action(name).call(env)` goes through the controller's own
  # callbacks, so ACL permits, mask_for, excludes, eager loading and the
  # jbuilder views apply exactly as they do for a normal HTTP request.
  #
  # The gem doesn't authenticate. The incoming request's credentials
  # (Authorization, Cookie, remote address, host) are copied onto the inner
  # request so the app's own `before_action`s resolve the same caller, and
  # `StandardMCP.config.dispatch_env` can add more (e.g. an internal-user key).
  #
  # CSRF: the inner POST/PATCH/DELETE runs the app's `protect_from_forgery`
  # like any other request, and forgery protection is not disabled here. Apps
  # that use it are expected to authenticate MCP calls with a scheme that
  # skips it (bearer tokens) or to have `verified_request?` honor a key set via
  # `dispatch_env`. An unverified write comes back as a 422 Result.
  class Dispatcher
    Result = Data.define(:status, :headers, :body) do
      # Parsed body, or nil when it is blank or not JSON.
      def json
        return nil if body.nil? || body.strip.empty?
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end
    end

    METHODS = {
      index: 'GET',
      show: 'GET',
      calculate: 'GET',
      create: 'POST',
      update: 'PATCH',
      destroy: 'DELETE',
      read_schema: 'GET',
      write_schema: 'GET'
    }.freeze

    # Env entries copied verbatim from the MCP request when present.
    FORWARDED_ENV = %w[
      HTTP_AUTHORIZATION
      HTTP_COOKIE
      HTTP_USER_AGENT
      HTTP_HOST
      REMOTE_ADDR
      SERVER_NAME
      SERVER_PORT
      HTTPS
      rack.url_scheme
      action_dispatch.remote_ip
      action_dispatch.request_id
    ].freeze

    # A session the inner request can read and write without touching the
    # outer one: it is seeded from a snapshot and has no persistence, since
    # nothing commits it (no session middleware runs for an in-process call).
    class DetachedSessionStore
      def initialize(data)
        @data = data
      end

      def load_session(_request)
        [SecureRandom.hex(16), @data.deep_dup]
      end

      def session_exists?(_request)
        true
      end
    end

    attr_reader :request

    def initialize(request)
      @request = request
    end

    # +params+ is the tool's arguments hash (an `id` becomes the path id).
    def call(klass, action, params = {})
      action = action.to_sym
      ensure_allowed!(klass, action)

      params = (params || {}).to_h.deep_stringify_keys
      ActiveSupport::Notifications.instrument('dispatch.standard_mcp', controller: klass, action: action) do
        perform(klass, action, params)
      end
    end

    # Whether +call+ would let +action+ through, for work that must only
    # happen once it is allowed (call still checks). `read_schema` and
    # `write_schema`, which back `describe_attributes`, are allowed with any
    # allowed action on the controller, the condition under which the describe
    # tools list it; `write_schema` also needs create or update, as it describes
    # what those accept.
    def allowed?(klass, action)
      action = action.to_sym
      return false unless METHODS.key?(action)

      allowed = Registry.controller_for(klass, request).mcp_actions_allowed
      case action
      when :read_schema then allowed.any?
      when :write_schema then (allowed & %i[create update]).any?
      else allowed.include?(action)
      end
    end

    private

    # The one authorization chokepoint. Conditions are per request, so this
    # re-checks even if tools/list advertised the tool.
    def ensure_allowed!(klass, action)
      return if allowed?(klass, action)

      raise ActionNotAllowed, "#{action} is not allowed on #{klass.name}"
    end

    def perform(klass, action, params)
      # The action doesn't check `include` against the ACL, so none goes in.
      params = params.except('include') if action == :write_schema
      id = params.delete('id')
      env = build_env(klass, action, params, id)

      status, headers, rack_body = klass.action(action).call(env)
      Result.new(status: status, headers: headers.to_h, body: collect(rack_body))
    rescue StandardError => e
      kind = write_error(e, action)
      status = client_error_status(e) || (WRITE_STATUSES.fetch(kind, 400) if kind) || (400 if filter_error(e))
      raise unless status

      error_result(status, error_message(e, status, action))
    end

    def build_env(klass, action, params, id)
      path = "/#{klass.controller_path}"
      path += "/#{id}" if id.present?

      env = Rack::MockRequest.env_for(path,
        method: METHODS.fetch(action),
        input: JSON.generate(params),
        'CONTENT_TYPE' => 'application/json',
        'HTTP_ACCEPT' => 'application/json')

      # Cookie/session keys, secret_key_base and friends that the Rails app
      # normally merges in before the router runs.
      env.merge!(Rails.application.env_config)
      FORWARDED_ENV.each do |key|
        value = request.get_header(key)
        env[key] = value unless value.nil?
      end

      path_parameters = { controller: klass.controller_path, action: action.to_s, format: 'json' }
      path_parameters[:id] = id.to_s if id.present?
      env['action_dispatch.request.path_parameters'] = path_parameters
      env['rack.session'] = detached_session(env)

      env.merge!(StandardMCP.config.dispatch_env.call(request) || {})
      # Last, so dispatch_env can't drop it.
      env[DISPATCHED_ENV] = true
      env
    end

    # Reading through the cookie works because the outer session is
    # snapshotted; writes (and reset_session) only touch the copy, so a tool
    # call can't change the caller's real session.
    def detached_session(env)
      outer = request.get_header('rack.session')
      data = outer ? outer.to_hash : {}
      inner = ActionDispatch::Request.new(env)
      ActionDispatch::Request::Session.create(DetachedSessionStore.new(data), inner, {}).tap do |session|
        env['rack.session.options'] = session.options.to_hash
      end
    end

    def collect(rack_body)
      body = +''
      rack_body.each { |chunk| body << chunk }
      body
    ensure
      rack_body.close if rack_body.respond_to?(:close)
    end

    # action(...).call skips ShowExceptions, so exceptions that Rails would
    # render as a 4xx surface here instead. 5xx (and unmapped) ones re-raise.
    def client_error_status(error)
      # Not mapped by Rails (RecordNotSaved is), though it is the same thing:
      # a callback refused the change.
      return 422 if error.is_a?(ActiveRecord::RecordNotDestroyed)

      status = ActionDispatch::ExceptionWrapper.status_code_for_exception(error.class.name)
      status if (400..499).cover?(status)
    end

    # The messages for a `where` that activerecord-filter or Postgres rejected,
    # which Schema::Where normally catches first (tools check the filter before
    # dispatching). Rendering is lazy, so the error arrives wrapped in an
    # ActionView::Template::Error.
    FILTER_MESSAGES = {
      unknown: "where names a column or association that doesn't exist",
      unsupported: 'where uses an operator or association filter that is not supported',
      database: "where has a value or operator that doesn't fit the column's type"
    }.freeze

    # :unknown, :unsupported or :database for a filter the query couldn't
    # build or Postgres refused (bad value or operator, bad tsquery), else nil.
    # Other database errors are server problems and stay out.
    def filter_error(error)
      error = error.cause if error.is_a?(ActionView::Template::Error) && error.cause

      case error
      when ActiveRecord::UnkownFilterError then :unknown
      when ActiveRecord::StatementInvalid then :database if database_filter_error?(error.cause)
      when RuntimeError then :unsupported if error.message.start_with?('Not Supported: ')
      end
    end

    def database_filter_error?(cause)
      return false unless defined?(PG::Error)

      [PG::DataException, PG::SyntaxError, PG::UndefinedFunction, PG::UndefinedObject, PG::DatatypeMismatch].any? { |klass| cause.is_a?(klass) }
    end

    WRITE_MESSAGES = {
      reference: "A foreign key points at a record that doesn't exist",
      referenced: "Other records still refer to this one, so it can't be deleted",
      duplicate: 'A record with the same unique value already exists',
      null: 'A required value is missing',
      value: "A value is out of range, too long or otherwise doesn't fit its column"
    }.freeze

    # Conflicts with other records; the rest is a bad value (400).
    WRITE_STATUSES = { referenced: 409, duplicate: 409 }.freeze

    # :reference, :referenced, :duplicate, :null or :value for a write that the
    # type cast or the database refused for the data in it (what a caller can
    # fix), else nil. Validations catch most of these first; these are the
    # constraints and limits only the database knows.
    def write_error(error, action)
      return unless %i[create update destroy].include?(action)

      case error
      when ActiveRecord::InvalidForeignKey then action == :destroy ? :referenced : :reference
      when ActiveRecord::RecordNotUnique then :duplicate
      when ActiveRecord::NotNullViolation then :null
      when ActiveModel::RangeError, ActiveRecord::RangeError, ActiveRecord::ValueTooLong then :value
      when ActiveRecord::StatementInvalid then :value if defined?(PG::DataException) && error.cause.is_a?(PG::DataException)
      end
    end

    # Exception messages can carry SQL or other internals (RecordNotFound
    # includes the scoped WHERE, which would leak a mask), so only the model
    # name for 404s, the missing parameter, a fixed sentence per kind of
    # filter or write error and the model's own errors for a write a callback
    # refused are passed through.
    def error_message(error, status, action)
      if (kind = write_error(error, action))
        return WRITE_MESSAGES.fetch(kind)
      end

      if (kind = filter_error(error))
        return FILTER_MESSAGES.fetch(kind)
      end

      case error
      when ActiveRecord::RecordNotDestroyed, ActiveRecord::RecordNotSaved
        refused_message(error, action)
      when ActiveRecord::RecordNotFound
        error.model ? "#{error.model} not found" : 'Not found'
      when ActionController::ParameterMissing
        "Parameter missing: #{error.param}"
      else
        Rack::Utils::HTTP_STATUS_CODES.fetch(status, 'Bad request')
      end
    end

    # A callback halted the write (`throw :abort`). The reasons are the ones
    # the model added to its own errors, in words the app chose; database
    # errors never land there (they raise StatementInvalid and are mapped
    # above), so unlike an exception message this is safe to pass on.
    def refused_message(error, action)
      record = error.record
      verb = action == :destroy ? 'deleted' : 'saved'
      message = "#{record ? record.class.name : 'Record'} could not be #{verb}"
      reasons = record ? record.errors.full_messages : []
      reasons.any? ? "#{message}: #{reasons.join(', ')}" : message
    end

    def error_result(status, message)
      Result.new(
        status: status,
        headers: { 'content-type' => 'application/json; charset=utf-8' },
        body: JSON.generate(error: message)
      )
    end
  end
end
