require 'json'

module StandardMCP
  # What a client would be sent, without a client: the server instructions and
  # `tools/list` for a synthetic request that carries only the headers given.
  # Per-request ACLs and `allow_mcp` conditions see those headers and nothing
  # else (no session, no cookies unless one is passed), so a tool hidden behind
  # `current_user` shows up once an Authorization header resolves one.
  module Preview
    FORMATS = %w[json summary].freeze

    class << self
      # Prints to +io+ and returns { instructions:, tools: } (tools as the
      # Hashes `tools/list` carries).
      #
      # +headers+ is a Hash, or the text of `Name: value` pairs separated by
      # `;` or newlines (see parse_headers). +format+ is 'json' (the default) or
      # 'summary'. +tool+ is a tool name: only that tool is shown, and an
      # unknown one raises ArgumentError.
      def call(headers: {}, format: 'json', tool: nil, io: $stdout)
        format = (format.presence || 'json').to_s
        raise ArgumentError, "format must be one of #{FORMATS.join(', ')}, got #{format.inspect}" unless FORMATS.include?(format)

        headers = parse_headers(headers) unless headers.is_a?(Hash)
        request = request_for(headers)
        tools = Tools.for(request).map(&:to_h)
        instructions = Instructions.for(request)

        if tool.present?
          available = tools.map { |entry| entry[:name] }
          tools = tools.select { |entry| entry[:name] == tool.to_s }
          raise ArgumentError, "No tool named #{tool.inspect} for these headers (available: #{available.join(', ')})" if tools.empty?
        end

        if format == 'json'
          io.puts JSON.pretty_generate(tool.present? ? tools.first : { instructions: instructions, tools: tools })
        else
          summary(io, instructions, tools, tool.present?)
        end

        { instructions: instructions, tools: tools }
      end

      # { 'Authorization' => 'Bearer 1' } from "Authorization: Bearer 1; X-A: b".
      # A value that contains `;` has to be on a line of its own.
      def parse_headers(text)
        text.to_s.split(/[;\r\n]+/).each_with_object({}) do |pair, headers|
          next if pair.strip.empty?

          name, separator, value = pair.partition(':')
          raise ArgumentError, "Header #{pair.strip.inspect} is not in Name: value form" if separator.empty? || name.strip.empty?

          headers[name.strip] = value.strip
        end
      end

      private

      def request_for(headers)
        env = headers.each_with_object({}) do |(name, value), result|
          key = name.to_s.upcase.tr('-', '_')
          result[%w[CONTENT_TYPE CONTENT_LENGTH].include?(key) ? key : "HTTP_#{key}"] = value.to_s
        end

        ActionDispatch::Request.new(Rack::MockRequest.env_for('/mcp', env))
      end

      # name, size of the tool as sent (compact JSON characters) and the first
      # sentence of its description; then the totals.
      def summary(io, instructions, tools, single)
        width = tools.map { |entry| entry[:name].length }.max.to_i
        sizes = tools.map { |entry| JSON.generate(entry).length }

        tools.zip(sizes).each do |entry, size|
          io.puts "#{entry[:name].ljust(width)}  #{size.to_s.rjust(6)}  #{first_sentence(entry[:description])}"
        end

        io.puts
        io.puts "#{tools.size} tool#{'s' unless tools.size == 1}, #{sizes.sum} characters" \
          "#{" (instructions: #{instructions.to_s.length} characters)" unless single}"
      end

      def first_sentence(text)
        text = text.to_s.squish
        text[/\A.*?[.!?](?=\s|\z)/m] || text
      end
    end
  end
end
