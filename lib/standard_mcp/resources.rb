require 'json'

module StandardMCP
  # The MCP resource templates for one request, built like the tools (per
  # request, closing over it) so what a caller sees depends on the caller:
  #
  # - `standardmcp://schema/{resource}`: what a controller's model offers this
  #   caller, as `{ "query": ..., "attributes": ... }`: the documents the
  #   `describe_query` and `describe_attributes` tools return for no where
  #   (Schema::QueryDocument, and the `read` and `write` JSON Schemas of
  #   StandardAPI's `read_schema` and `write_schema` actions, `write` only for
  #   a caller who may create or update), which the shallow tool schemas leave
  #   out. `resource` is the controller path with `/` written as `_`
  #   (`admin_accounts`), the segment the tool names use, so it needs no `/`
  #   (a `{var}` of the mcp gem matches one path segment, and nothing is
  #   percent-decoded).
  # - `standardmcp://<resource>/{id}`, for every controller that allows `show`
  #   to the caller: a record as JSON, so a client can attach it as context. It
  #   dispatches `show` through Dispatcher, so allow_mcp, the ACL, excludes and
  #   `mask_for` apply as they do for `get_*`. No `include`: the gem matches
  #   only plain `{var}` expressions, not RFC 6570 query ones (`{?include}`).
  #
  # A controller is readable when the caller has any allowed MCP action on it.
  # Anything else, a masked or missing record and an unknown URI alike, is the
  # same "Resource not found" error, so neither a hidden controller nor a
  # masked row is revealed. (The mcp gem answers it with -32602 Invalid Params
  # and the URI in `data`, per SEP-2164, not the older -32002.)
  #
  # `schema` and `records` share a URI shape (`schema/{x}`), so a controller
  # whose resource name is `schema` that allows show can't have both:
  # `Resources.for` raises, like duplicate tool names do. The URIs stay short
  # that way, at the price of a rename or `config.resources = [:schema]` for
  # an app with such a controller.
  module Resources
    MIME_TYPE = 'application/json'.freeze

    # One controller the request may use: its resource name, class and allowed
    # actions.
    Entry = Data.define(:name, :klass, :actions)

    class << self
      # Array of MCP::ResourceTemplate subclasses for +request+ (an
      # ActionDispatch::Request), per `config.resources`.
      #
      # +only_uri+ is a URI being read: just the template it can match is
      # built, followed by one that answers "Resource not found" for any URI,
      # so the mcp gem raises where it would otherwise return nothing. Listing
      # needs none of the schema rendering either way, which happens when a
      # template is read.
      def for(request, only_uri: nil)
        config = StandardMCP.config
        target = split(only_uri, config.resource_scheme) if only_uri
        templates = []

        if config.resources.any? && (only_uri.nil? || target)
          entries = entries(Registry.allowed(request))
          schema = config.resources.include?(:schema)
          records = config.resources.include?(:records)
          collisions(entries) if schema && records

          templates << schema_template(request, entries) if schema && (target.nil? || target.first == 'schema')
          if records
            entries.each do |entry|
              next unless entry.actions.include?(:show) && (target.nil? || target.first == entry.name)

              templates << record_template(request, entry)
            end
          end
        end

        templates << not_found_template(only_uri) if only_uri
        templates
      end

      # The tool-name segment of a controller: `accounts`, `admin_accounts`.
      def resource_name(klass)
        klass.controller_path.tr('/', '_')
      end

      # The Entry of each controller +allowed+ (Registry.allowed) has a model
      # for, which Tools.for insists on.
      def entries(allowed)
        entries = allowed.filter_map do |klass, actions|
          Entry.new(name: resource_name(klass), klass: klass, actions: actions) if klass.model
        end

        duplicates = entries.group_by(&:name).select { |_, group| group.size > 1 }.keys
        raise Error, "Duplicate MCP resource names: #{duplicates.join(', ')}" if duplicates.any?

        entries
      end

      # { model => resource name } for the models +entries+ serve, to say which
      # resource describes an association.
      def links(entries)
        entries.each_with_object({}) { |entry, result| result[entry.klass.model] ||= entry.name }
      end

      # The query document of resource +name+ for +request+ (a Hash), or nil
      # when the caller has no allowed action on that controller (or none
      # exists). +entries+ is `entries(Registry.allowed(request))`. +where+ is
      # the where the keys depend on; the definitions are asked for it once. A
      # where that doesn't hold up raises Schema::Where::Invalid.
      def document(request, entries, name, where: nil)
        entry = entries.find { |candidate| candidate.name == name }
        return unless entry

        controller = Registry.controller_for(entry.klass, request)
        definitions = Schema::Where.checked_definitions(controller, where)
        Schema::QueryDocument.for(controller, name: entry.name, actions: entry.actions, links: links(entries),
          where: where, definitions: definitions)
      end

      # The attributes of resource +name+ as `{ read:, write: }`, the JSON
      # Schemas StandardAPI's `read_schema` and `write_schema` actions render
      # for +where+, unchanged, as a Response (an error result when an action
      # answers 4xx; a 5xx raises). `write` is left out when the caller may
      # neither create nor update. nil when the caller has no allowed action on
      # that controller (or none exists). The actions run in-process like a
      # tool call, so the callbacks and the ACL's `schemas` hook (which reads
      # `params[:where]`) run too. A where that doesn't hold up raises
      # Schema::Where::Invalid.
      def attributes(request, entries, name, where = nil)
        entry = entries.find { |candidate| candidate.name == name }
        return unless entry

        errors = Schema::Where.errors(Registry.controller_for(entry.klass, request), where)
        raise Schema::Where::Invalid, errors if errors.any?

        dispatcher = Dispatcher.new(request)
        params = { 'where' => where }.compact
        schemas = {}
        actions = { read: :read_schema }
        actions[:write] = :write_schema if dispatcher.allowed?(entry.klass, :write_schema)

        actions.each do |key, action|
          response = Response.from(dispatcher.call(entry.klass, action, params), action: action)
          return response if response.error?

          schemas[key] = response.structured_content
        end
        Response.document(schemas)
      rescue ActionNotAllowed
        nil
      end

      # Runs one schema read (public: the template body is a block evaluated
      # on the template class, which can't reach private methods here).
      def read_schema(request, entries, name, uri)
        query = document(request, entries, name) or raise not_found(uri)
        response = attributes(request, entries, name) or raise not_found(uri)
        raise invalid(response.structured_content[:error]) if response.error?

        text(uri, { 'query' => query, 'attributes' => response.structured_content })      end

      # Runs one record read. +id+ is the URI's id, as given.
      def read_record(request, entry, id, uri)
        result = Dispatcher.new(request).call(entry.klass, :show, 'id' => id)
        # Raises (an internal error) for a 5xx, which isn't the caller's to fix.
        response = Response.from(result, action: :show)

        if response.error?
          # A 403 is a hidden record as much as a 404 is.
          raise not_found(uri) if [403, 404].include?(result.status)

          raise invalid(response.structured_content[:error])
        end

        text(uri, response.structured_content[:record])
      rescue ActionNotAllowed
        raise not_found(uri)
      end

      def not_found(uri)
        MCP::Server::ResourceNotFoundError.new(uri)
      end

      def uri_for(name)
        "#{StandardMCP.config.resource_scheme}://#{name}"
      end

      private

      # [first, second] of "scheme://first/second", or nil for any other URI.
      def split(uri, scheme)
        return unless uri.is_a?(String)

        prefix = "#{scheme}://"
        return unless uri.start_with?(prefix)

        parts = uri.delete_prefix(prefix).split('/', -1)
        parts if parts.size == 2 && parts.none?(&:empty?)
      end

      def collisions(entries)
        clash = entries.find { |entry| entry.name == 'schema' && entry.actions.include?(:show) }
        return unless clash

        raise Error, "#{clash.klass.name} has the resource name 'schema', which collides with " \
          "#{uri_for('schema')}/{resource}; rename the controller or set config.resources = [:schema]"
      end

      def schema_template(request, entries)
        base = uri_for('schema')
        names = entries.map(&:name)

        MCP::ResourceTemplate.define(
          uri_template: "#{base}/{resource}",
          name: 'schema',
          title: 'Resource schema',
          description: 'What a resource offers: "query" has the keys and operators of where, the order keys and the ' \
            'associations to include; "attributes" has the JSON Schema of a record ("read") and, for callers who ' \
            "may write, of the params of create and update (\"write\"). Resources: #{names.join(', ')}.",
          mime_type: MIME_TYPE
        ) do |resource:, server_context: nil|
          Resources.read_schema(request, entries, resource, "#{base}/#{resource}")
        end
      end

      def record_template(request, entry)
        model = entry.klass.model
        base = uri_for(entry.name)

        MCP::ResourceTemplate.define(
          uri_template: "#{base}/{id}",
          name: entry.name.singularize,
          title: entry.klass.controller_path.tr('/', ' ').humanize.singularize,
          description: [Description.table(model), "One #{model.model_name.human.downcase} by id, as JSON."].compact.join(' '),
          mime_type: MIME_TYPE
        ) do |id:, server_context: nil|
          Resources.read_record(request, entry, id, "#{base}/#{id}")
        end
      end

      # Matches every URI and refuses it. The mcp gem picks the first template
      # that matches, so this goes last.
      def not_found_template(uri)
        Class.new(MCP::ResourceTemplate) do
          define_singleton_method(:match_uri) { |_| {} }
          define_singleton_method(:contents) { |server_context: nil, **| raise Resources.not_found(uri) }
        end
      end

      def text(uri, json)
        MCP::Resource::TextContents.new(uri: uri, mime_type: MIME_TYPE, text: JSON.generate(json))
      end

      # A request the caller can fix, with the message Response gave it.
      def invalid(message)
        MCP::Server::RequestHandlerError.new(
          message,
          nil,
          error_type: :invalid_params,
          error_code: ::JsonRpcHandler::ErrorCode::INVALID_PARAMS
        )
      end
    end
  end
end
