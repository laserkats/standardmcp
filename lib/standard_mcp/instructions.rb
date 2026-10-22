module StandardMCP
  # The server instructions sent to a client when it initializes: the
  # application context a model needs before it picks a tool. The default is
  # generated from the database, so it grows with the comments:
  #
  # - the database comment opens it;
  # - a "Resources" list has a line for each model this request may use (the
  #   same per-request hiding as the tools), carrying the table comment and the
  #   names of its tools;
  # - a short paragraph covers the conventions the tools share, so the tool
  #   descriptions needn't repeat them. Keys, operators and attributes are not
  #   listed: the describe tools return them, on request.
  #
  # `config.instructions` changes that: false sends none, a String or a callable
  # taking the request replaces the generated text, and a callable taking the
  # request and the generated text adds to it.
  #
  # Nothing is memoized: comments change with migrations and dev reloads.
  module Instructions
    # One model the request may use, with the actions it is allowed and the
    # names of their tools.
    Resource = Data.define(:name, :model, :comment, :actions, :tools)

    class << self
      # String, or nil when there is nothing to say (or `config.instructions`
      # is false). +request+ is an ActionDispatch::Request.
      def for(request)
        configured = StandardMCP.config.instructions
        return if configured == false

        extends = configured.respond_to?(:call) && extends?(configured)
        generated = generate(request) if extends

        text =
          if extends then configured.call(request, generated)
          elsif configured.respond_to?(:call) then configured.call(request)
          else configured
          end

        text.presence || (extends ? generated : generate(request))
      end

      # The generated text, ignoring `config.instructions`.
      def generate(request)
        resources = resources(request)
        sections = [
          database_comment,
          (resources_section(resources) if resources.any?),
          (conventions(resources) if resources.any?)
        ]
        sections.compact_blank.join("\n\n").presence
      end

      # The database comment, which StandardAPI adds to every adapter (nil
      # where the adapter has none).
      def database_comment
        connection = ActiveRecord::Base.connection
        connection.database_comment.presence if connection.respond_to?(:database_comment)
      end

      private

      # A callable that also wants the generated text: it takes two arguments
      # (`->(request, default) { ... }`), where `->(request) { ... }` replaces.
      def extends?(callable)
        arity = callable.respond_to?(:arity) ? callable.arity : callable.method(:call).arity
        arity == 2 || arity <= -2
      end

      def resources(request)
        Registry.allowed(request).filter_map do |klass, actions|
          next unless klass.model

          actions &= Tools::ACTIONS
          Resource.new(
            name: klass.controller_path,
            model: klass.model,
            comment: Description.table(klass.model),
            actions: actions,
            tools: Tools::ACTIONS.select { |action| actions.include?(action) }.map { |action| Tools.tool_name(klass, action) }
          )
        end
      end

      # "accounts: A customer organization. Tools: list_accounts, get_account."
      def resources_section(resources)
        lines = resources.map do |resource|
          comment = resource.comment&.squish
          comment += '.' if comment && !comment.match?(/[.!?]\z/)
          ["#{resource.name}:", comment, "Tools: #{resource.tools.join(', ')}."].compact.join(' ')
        end

        "Resources:\n#{lines.join("\n")}"
      end

      # The resource names of the describe tools are the listed ones with `/`
      # written as `_` (the segment the tool names use). Neither is required
      # before a call; they say what the keys, operators and attributes are.
      def describe_sentence(resources)
        name = resources.first.name.tr('/', '_')
        sentence = %(describe_query {"resource": "#{name}"} returns the keys, operators and associations of where, order ) +
          %(and include; describe_attributes {"resource": "#{name}"} returns a record's JSON Schema, with which attributes are read only or required. ) +
          'Pass them the where you will use, as some keys depend on it'
        sentence += ' (write a "/" in a resource name as "_")' if resources.any? { |resource| resource.name.include?('/') }
        "#{sentence}."
      end

      # Only what holds for every tool and isn't said in each of them.
      def conventions(resources)
        actions = resources.flat_map(&:actions)
        sentences = []
        sentences << 'list_* tools return one page; pass the result\'s next_offset as offset to get the next.' if actions.include?(:index)
        if (actions & %i[index calculate]).any?
          sentences << 'Filters (where) take operator objects such as {"size": {"gte": 1000}}.'
        end
        sentences << 'include embeds associations in the result.' if (actions & %i[index show create update]).any?
        sentences << describe_sentence(resources) if StandardMCP.config.describe_tools

        writer = resources.find { |resource| (resource.actions & %i[create update]).any? }
        if writer
          sentences << 'create_* and update_* take the record under its singular name, ' \
            "e.g. {\"#{writer.model.model_name.singular}\": {...}}."
        end
        sentences << 'update_* and delete_* take the record\'s id.' if (actions & %i[update destroy]).any?

        "Conventions: #{sentences.join(' ')}"
      end
    end
  end
end
