require 'json_schemer'

module StandardMCP
  module Schema
    # The record a write tool sends, as StandardAPI will accept it: the
    # attributes the ACL permits (`model_attributes`), typed from the columns,
    # plus the associations the ACL lets a request write through (`nested`).
    #
    # StandardAPI's write_schema derives the same from the definitions and
    # validators, for describe_attributes to show; this one checks the call, so
    # only what is safe to enforce before saving is kept:
    #
    # - unconditional validators only (no `if:`/`unless:`, and `on:` must match
    #   the action), so a rule that depends on the record never rejects a call;
    # - `required` on create follows the view (a permitted NOT NULL column, or
    #   a presence validator) minus columns that have a default;
    # - ids, timestamps, columns the database fills in and (on update)
    #   `attr_readonly` columns are not writable, and columns an ACL
    #   `excludes` hides don't exist.
    #
    # The ACL is asked without a record, as when StandardAPI renders its
    # schema, so an `attributes(record)` that varies per record can still drop
    # a key this accepts (see IgnoredAttributes).
    module Attributes
      NUMBERS = %i[integer bigint float decimal].freeze
      STRINGS = %i[string text citext].freeze
      JSON_TYPES = %i[json jsonb].freeze

      # What ECMA 262 doesn't match the way Ruby does: inline flags, named
      # groups, lookbehind, POSIX brackets, `{,n}` and any escape beyond the
      # plain ones (\A and \z are translated).
      UNSAFE_PATTERN = /
        \(\?[^:=!]
        | \[:
        | \{,
        | \\[^dDwWsSbB.\-+*?^$()\[\]{}|\/@Az]
      /x

      class << self
        # Names the ACL permits for +model+ (a String per attribute; entries
        # such as `{ tags: [] }` count by key). Pass +record+ for an ACL that
        # decides per record.
        def permitted(controller, model, record = nil)
          return [] unless controller.respond_to?(:model_attributes)

          Array.wrap(controller.model_attributes(model, record)).flatten
            .flat_map { |entry| entry.is_a?(Hash) ? entry.keys : entry }
            .map(&:to_s).uniq
        end

        # The reflections of +model+ a request may write through (the ACL's
        # `nested`).
        def nested(controller, model)
          return [] unless controller.respond_to?(:model_name)

          method = "nested_#{controller.model_name(model)}_attributes"
          return [] unless controller.respond_to?(method, true)

          Array(controller.send(method)).filter_map { |name| model.reflect_on_association(name) }
        end

        # Every key StandardAPI takes for +model+: permitted attributes and
        # what the nested associations add (the association, its `<name>_ids`
        # and the foreign key of a belongs_to).
        def accepted(controller, model, record = nil)
          keys = permitted(controller, model, record)

          nested(controller, model).each do |reflection|
            keys << reflection.name.to_s
            keys << "#{reflection.name.to_s.singularize}_ids" if reflection.collection?
            next unless reflection.belongs_to?

            keys << reflection.foreign_key.to_s
            keys << reflection.foreign_type.to_s if reflection.polymorphic?
          end

          keys.uniq
        end

        # Attributes a create has to send: permitted, writable and NOT NULL or
        # presence-validated, without a default.
        def required(controller, model)
          hidden = Input.hidden(controller, model)
          belongs = required_foreign_keys(model)

          permitted(controller, model).filter_map do |name|
            column = model.columns_hash[name]
            name if column && !hidden.include?(name) && writable?(model, column, :create) && required?(model, column, belongs)
          end
        end

        # Object schema of the record. +action+ is :create, :update or, for a
        # record inside another, :nested (an id picks an existing one and every
        # attribute is optional). +visited+ holds the models on the path, which
        # stops a cycle of associations from recursing forever.
        def schema(controller, model, action, visited = [model])
          hidden = Input.hidden(controller, model)
          belongs = required_foreign_keys(model)
          properties = {}
          required = []

          if action == :nested
            properties['id'] = Input.id_schema(model).merge('description' => 'Existing record to update; omit to create one.')
          end

          permitted(controller, model).each do |name|
            next if hidden.include?(name)

            column = model.columns_hash[name]
            if column.nil?
              properties[name] = virtual_schema(model, name)
            elsif writable?(model, column, action)
              properties[name] = column_schema(model, column, action)
              required << name if action == :create && required?(model, column, belongs)
            end
          end

          nested(controller, model).each do |reflection|
            next if hidden.include?(reflection.name.to_s)

            nested_schemas(controller, model, reflection, visited).each { |name, sub| properties[name] ||= sub }
          end

          schema = { 'type' => 'object', 'properties' => properties, 'additionalProperties' => false }
          schema['required'] = required if required.any?
          schema['minProperties'] = 1 if action == :update
          schema
        end

        # Why +record+ (the attributes of a create or update, String-keyed)
        # can't be saved, as messages for the agent; empty when it can. The
        # shallow tool schema leaves the record loose, so this holds it to the
        # typed schema a call at a time: a key the ACL doesn't permit, a value of
        # the wrong type or outside an enum, a missing required attribute.
        # Without it a bad enum value or a nested record that isn't an object
        # would be a server error, and a wrong number a silent 0.
        def errors(controller, action, record)
          return [] unless record.is_a?(Hash)

          messages = JSONSchemer.schema(schema(controller, controller.class.model, action)).validate(record).map { |error| error['error'] }.uniq
          call = Description.describe_call(controller, 'describe_attributes')
          messages[-1] = "#{messages.last}. Writable and required attributes: #{call}." if messages.any? && call
          messages
        end

        # "name (string): Marketing name.", for each attribute a nested record
        # may carry; the shallow schema's stand-in for typing them.
        def lines(controller, model)
          hidden = Input.hidden(controller, model)

          permitted(controller, model).filter_map do |name|
            next if hidden.include?(name)

            column = model.columns_hash[name]
            next if column && !writable?(model, column, :nested)

            line = column ? "#{name} (#{Input.column_label(model, column)})" : name
            comment = Description.column(model, name)&.delete_suffix('.')
            comment ? "#{line}: #{comment}" : line
          end
        end

        private

        # --- columns

        def writable?(model, column, action)
          return false if column.name == model.primary_key.to_s
          return false if column.auto_populated? || column.try(:virtual?)
          return false if timestamps(model).include?(column.name)

          action == :create || model.readonly_attributes.exclude?(column.name)
        end

        def timestamps(model)
          model.respond_to?(:all_timestamp_attributes_in_model, true) ? model.send(:all_timestamp_attributes_in_model) : []
        end

        def required?(model, column, belongs)
          return false unless model.column_defaults[column.name].nil?

          column.null == false || belongs.include?(column.name) || presence?(validators(model, column.name, :create))
        end

        # Foreign keys of a belongs_to that is validated present (what
        # `belongs_to` does unless it is optional).
        def required_foreign_keys(model)
          model.reflect_on_all_associations(:belongs_to).filter_map do |reflection|
            reflection.foreign_key.to_s if presence?(validators(model, reflection.name, :create))
          end
        end

        def presence?(validators)
          validators.any?(ActiveModel::Validations::PresenceValidator)
        end

        # The validators that hold whatever the record: not conditional, and
        # for this action (a nested record may be new or existing, so only
        # those without `on:`).
        def validators(model, name, action)
          context = action == :nested ? nil : action

          model.validators_on(name.to_sym).select do |validator|
            options = validator.options
            next false if options[:if] || options[:unless]

            on = Array(options[:on])
            on.empty? || on.include?(context)
          end
        end

        def column_schema(model, column, action)
          validators = validators(model, column.name, action)
          # A presence validator rejects null, so the schema needn't offer it.
          nullable = column.null && !presence?(validators)
          value = Input.value_schema(column)
          # Like the output schemas: json columns hold any JSON value.
          value = value.except('type') if JSON_TYPES.include?(column.type)

          schema = {}
          comment = Description.column(model, column.name)
          schema['description'] = comment if comment

          constraints, notes = constraints(model, column, validators)
          schema['description'] = [schema['description'], *notes].compact.join(' ') if notes.any?
          item = value.merge(constraints)

          if column.array
            schema['type'] = nullable ? %w[array null] : 'array'
            schema['items'] = item
          else
            item = Input.nullable(item) if nullable
            item['enum'] = item['enum'] + [nil] if nullable && item['enum']
            schema.merge!(item)
          end
          schema
        end

        # [keywords, notes]: the validator rules that can be stated as JSON
        # Schema, and sentences for those that can't.
        def constraints(model, column, validators)
          keywords = {}
          notes = []
          # Validators of an array column judge the array, not its items.
          return [keywords, notes] if column.array

          values = Input.allowed_values(model, column)
          keywords['enum'] = values if values
          keywords['maxLength'] = column.limit if column.limit && STRINGS.include?(column.type)

          validators.each do |validator|
            options = validator.options

            case validator
            when ActiveModel::Validations::NumericalityValidator
              numericality(keywords, options) if NUMBERS.include?(column.type)
            when ActiveModel::Validations::LengthValidator
              length(keywords, options) if STRINGS.include?(column.type) && !options[:allow_blank]
            when ActiveModel::Validations::FormatValidator
              pattern(keywords, notes, options) if STRINGS.include?(column.type) && !options[:allow_blank]
            end
          end

          [keywords, notes]
        end

        def numericality(keywords, options)
          { greater_than: 'exclusiveMinimum', less_than: 'exclusiveMaximum',
            greater_than_or_equal_to: 'minimum', less_than_or_equal_to: 'maximum' }.each do |option, keyword|
            keywords[keyword] = options[option] if options[option].is_a?(Numeric)
          end
        end

        def length(keywords, options)
          minimum = options[:minimum] || options[:is]
          maximum = options[:maximum] || options[:is]
          keywords['minLength'] = minimum if minimum.is_a?(Integer)
          keywords['maxLength'] = [keywords['maxLength'], maximum].compact.min if maximum.is_a?(Integer)
        end

        def pattern(keywords, notes, options)
          regexp = options[:with]
          return unless regexp.is_a?(Regexp) && !options[:multiline]

          if (translated = ecma(regexp))
            keywords['pattern'] = translated
          else
            notes << "Must match /#{regexp.source}/."
          end
        end

        # +regexp+ as an ECMA 262 pattern, or nil when it can't be translated
        # without risking a different match (which would reject valid input).
        def ecma(regexp)
          return unless regexp.options.zero?

          source = regexp.source
          return if source.match?(UNSAFE_PATTERN)

          source.gsub('\A', '^').gsub('\z', '$')
        end

        # An attribute that isn't a column (a virtual attribute, a password).
        def virtual_schema(model, name)
          type = model.type_for_attribute(name).type
          type ? Input.scalar_schema(type).transform_keys(&:to_s) : {}
        end

        # --- nested associations

        # The properties StandardAPI reads for a nested association: the
        # association itself, `<name>_ids` for a collection and the foreign
        # key of a belongs_to (which it takes though the ACL needn't list it).
        def nested_schemas(controller, model, reflection, visited)
          name = reflection.name.to_s
          klass = Input.klass_for(reflection) unless reflection.polymorphic?
          schemas = {}

          if reflection.belongs_to?
            [reflection.foreign_key, (reflection.foreign_type if reflection.polymorphic?)].compact.each do |key|
              column = model.columns_hash[key.to_s]
              schemas[column.name] = column_schema(model, column, :nested) if column
            end
          end
          return schemas unless klass

          schemas[name] = association_schema(controller, model, reflection, klass, visited)
          if reflection.collection?
            schemas["#{name.singularize}_ids"] = {
              'type' => 'array',
              'items' => Input.id_schema(klass).slice('type', 'format'),
              'description' => "IDs of existing #{klass.model_name.human.pluralize.downcase} to link, replacing the set."
            }
          end
          schemas
        end

        # Typed in deep mode; in shallow mode a loose object whose description
        # lists the attributes, which is a fraction of the tokens.
        def association_schema(controller, model, reflection, klass, visited)
          deep = StandardMCP.config.deep_input_schema? && visited.exclude?(klass)
          object = deep ? schema(controller, klass, :nested, visited + [klass]) : { 'type' => 'object' }

          rule = if reflection.collection?
            'Replaces the whole set: an object with an id updates that record, one without creates one, ' \
              'and records left out are removed.'
          else
            'An object with an id updates that record, one without creates one.'
          end
          description = [Input.association_description(model, reflection), rule].compact.join(' ')
          unless deep
            attributes = lines(controller, klass)
            attributes += nested(controller, klass).map { |nested| "#{nested.name} (nested)" }
            description += " Attributes: id, #{attributes.join('; ')}." if attributes.any?
          end

          if reflection.collection?
            { 'type' => 'array', 'items' => object, 'description' => description }
          else
            { 'description' => description }.merge(Input.nullable(object))
          end
        end
      end
    end
  end
end
