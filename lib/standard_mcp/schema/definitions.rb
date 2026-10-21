module StandardMCP
  module Schema
    # The attribute definitions of a model for one where, from the controller's
    # `model_attribute_definitions(model, where)` (see StandardMCP::Controller),
    # in the shape the describe documents and the validation read: String-keyed
    # Hashes, hidden attributes dropped.
    #
    # The hook may return one Array, or a Hash of labelled Arrays when the where
    # spans several groups. Groups are merged into one entry per name, in
    # first-seen order:
    #
    # - a name missing from some groups gets `only_in`, the labels that have it;
    # - a name whose type (array flag included) differs between groups loses its
    #   `type` and gets `types`, a label => type map;
    # - every other field comes from the first group that has the name.
    #
    # Nothing is memoized: build once per describe or validation call and pass
    # the Result around, so the hook runs once per (controller, model, where).
    module Definitions
      # +entries+ is an Array of String-keyed Hashes; +groups+ the labels, or nil
      # when the hook returned a plain Array.
      Result = Data.define(:entries, :groups) do
        def grouped?
          !groups.nil?
        end

        def names
          entries.map { |entry| entry['name'] }
        end

        def find(name)
          entries.find { |entry| entry['name'] == name.to_s }
        end
      end

      class << self
        def for(controller, model, where)
          raw = controller.model_attribute_definitions(model, where)
          hidden = Input.hidden(controller, model)

          if raw.is_a?(Hash)
            groups = raw.each_with_object({}) { |(label, list), result| result[label.to_s] = normalize(list, hidden) }
            Result.new(entries: merge(groups), groups: groups.keys)
          else
            Result.new(entries: normalize(raw, hidden), groups: nil)
          end
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

        def merge(groups)
          names = groups.values.flat_map { |list| list.map { |entry| entry['name'] } }.uniq

          names.map do |name|
            found = groups.map { |label, list| [label, list.find { |entry| entry['name'] == name }] }.reject { |_, entry| entry.nil? }
            merged = found.first.last.dup
            merged['only_in'] = found.map(&:first) if found.size < groups.size

            types = found.to_h { |label, entry| [label, type_label(entry)] }
            if types.values.uniq.size > 1
              merged.delete('type')
              merged.delete('array')
              merged['types'] = types
            end

            merged
          end
        end
      end
    end
  end
end
