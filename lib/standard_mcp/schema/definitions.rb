module StandardMCP
  module Schema
    # The attribute definitions of a model for one where, from StandardAPI's
    # `schemas_for(model)` (which runs the ACL's `schemas` hook), in the shape
    # the describe_query document and the where validation read: String-keyed
    # Hashes, hidden attributes dropped.
    #
    # An app makes a definition depend on the where by reading `params[:where]`
    # in the ACL's `schemas` hook. `schemas_for` is asked on a controller bound
    # to a request whose params hold the where, so the hook sees what a
    # dispatched call would. A definition that carries `only_in` or `types` (the
    # groups of records that have the attribute, or its type in each) keeps
    # them; describe_query copies them onto the key.
    #
    # Nothing is memoized: every call builds a new controller (`schemas_for`
    # memoizes per instance), so one where's definitions can't reach another's.
    # Build once per describe or validation call and pass the Result around.
    module Definitions
      # +entries+ is an Array of String-keyed Hashes.
      Result = Data.define(:entries) do
        def names
          entries.map { |entry| entry['name'] }
        end

        def find(name)
          entries.find { |entry| entry['name'] == name.to_s }
        end
      end

      class << self
        # +controller+ is an instance from Registry.controller_for; only its
        # class and request are used. +where+ is String-keyed, nil for none (an
        # Array alternating filters with "AND"/"OR" is passed as given).
        def for(controller, model, where)
          params = { 'where' => where }.compact
          bound = Registry.controller_for(controller.class, controller.request, params: params)
          hidden = Input.hidden(controller, model)

          Result.new(entries: normalize(bound.schemas_for(model), hidden))
        end

        # "integer", or "string[]" for an array: how a definition's type reads
        # in the documents. nil for a definition with no type.
        def type_label(definition)
          type = definition['type']
          return if type.nil?

          definition['array'] ? "#{type}[]" : type.to_s
        end

        private

        def normalize(list, hidden)
          Array(list).filter_map do |definition|
            entry = definition.to_h.transform_keys(&:to_s)
            entry['name'] = entry['name'].to_s
            entry['type'] = entry['type'].to_s if entry['type']
            entry if entry['name'].present? && hidden.exclude?(entry['name'])
          end
        end
      end
    end
  end
end
