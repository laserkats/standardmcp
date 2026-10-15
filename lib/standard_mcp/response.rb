require 'json'

module StandardMCP
  # Turns what a dispatched StandardAPI action rendered into an
  # MCP::Tool::Response.
  #
  # MCP requires `structuredContent` to be a JSON object, but StandardAPI
  # renders bare arrays (index, calculate) and bare records, so successes are
  # wrapped under a key. Failures a model can act on (validation errors, a bad
  # param, a missing record) become `isError` tool results; anything else is a
  # server problem and raises.
  module Response
    # Past this many characters a 5xx body is cut so it can't leak far.
    SNIPPET_LENGTH = 200

    # Wrapper key for each action's rendered JSON.
    KEYS = {
      index: :records,
      show: :record,
      create: :record,
      update: :record,
      calculate: :result
    }.freeze

    class << self
      # `result` responds to #status, #headers, #body and #json (see
      # Dispatcher::Result). `extra` is merged into a successful result's
      # structured content, e.g. pagination for index.
      def from(result, action:, extra: nil)
        action = action.respond_to?(:to_sym) ? action.to_sym : action
        unless Controller::ACTIONS.include?(action)
          raise ArgumentError, "Unknown action #{action.inspect}. Valid actions: #{Controller::ACTIONS.map(&:inspect).join(', ')}"
        end

        status = result.status
        case status
        when 200..299 then success(result, action, extra)
        when 400..499 then failure(result, status)
        else raise DispatchError, "Unexpected response (status #{status}): #{snippet(result.body)}"
        end
      end

      # A tool-level error the model can read and correct.
      def error(message, errors: nil)
        structured = { error: message }
        structured[:errors] = errors if errors
        build(structured, error: true)
      end

      def not_allowed(action)
        error("Action #{action} is not allowed")
      end

      private

      def success(result, action, extra)
        structured =
          if action == :destroy
            destroyed(result)
          else
            { KEYS.fetch(action) => payload(result, action) }
          end
        structured = structured.merge(extra) if extra
        build(structured)
      end

      def destroyed(result)
        structured = { success: true }
        header = result.headers.find { |k, _| k.to_s.casecmp?('Affected-Rows') }&.last
        rows = Integer(header.to_s, exception: false)
        # Omitted rather than null so an integer schema still validates.
        structured[:affected_rows] = rows if rows
        structured
      end

      def payload(result, action)
        json = result.json
        # calculate renders an array, or a hash when grouped.
        expected = case action
        when :index then [Array]
        when :calculate then [Array, Hash]
        else [Hash]
        end
        return json if expected.any? { |klass| json.is_a?(klass) }

        raise DispatchError, "Unexpected #{action} body (status #{result.status}): #{snippet(result.body)}"
      end

      def failure(result, status)
        json = result.json

        case status
        when 400, 422 then invalid(result, json)
        when 401 then error('Unauthorized')
        when 403 then error(detail(json) ? "Forbidden: #{detail(json)}" : 'Forbidden')
        when 404 then error(detail(json) || 'Not found')
        else error("Request failed with status #{status}")
        end
      end

      # Validation errors arrive as a record carrying an `errors` hash;
      # ParameterMissing and UnpermittedParameters arrive as plain text.
      def invalid(result, json)
        errors = json['errors'] if json.is_a?(Hash)

        if errors.is_a?(Hash) && errors.any?
          error(flatten(errors), errors: errors)
        elsif errors.is_a?(Array) && errors.any?
          error(errors.join(', '), errors: errors)
        elsif detail(json)
          error(detail(json))
        elsif json.nil? && !result.body.to_s.strip.empty?
          error(result.body.strip)
        else
          error("Request failed with status #{result.status}")
        end
      end

      # {'name' => ["can't be blank"]} => "name can't be blank"
      def flatten(errors)
        errors.flat_map do |attribute, messages|
          Array(messages).map { |m| attribute.to_s == 'base' ? m.to_s : "#{attribute} #{m}" }
        end.join(', ')
      end

      def detail(json)
        message = json['error'] if json.is_a?(Hash)
        message if message.is_a?(String) && !message.empty?
      end

      def snippet(body)
        body = body.to_s
        body.length > SNIPPET_LENGTH ? "#{body[0, SNIPPET_LENGTH]}..." : body
      end

      # Compact JSON in `content` keeps token use down; clients that ignore
      # structuredContent still get the same data.
      def build(structured, error: false)
        MCP::Tool::Response.new(
          [{ type: 'text', text: JSON.generate(structured) }],
          error: error,
          structured_content: structured
        )
      end
    end
  end
end
