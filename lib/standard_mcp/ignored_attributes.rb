module StandardMCP
  # Which submitted attributes StandardAPI silently drops.
  #
  # `permit` ignores a key the ACL doesn't allow for the record, so a call can
  # succeed without saving everything it sent. The input schema already
  # rejects keys no record may set (it is built from the ACL without a record),
  # which leaves what only a record can tell: a per-record `attributes(record)`,
  # and the attributes of nested records, which the shallow schema doesn't
  # check. The answer is advisory, so a failure to work it out yields nothing
  # rather than failing the write.
  module IgnoredAttributes
    # Depth of nested records inspected, in step with how far a request can nest.
    MAX_DEPTH = 5

    class << self
      # Paths of the keys in +submitted+ (String-keyed) that +controller+'s ACL
      # won't take for +model+, e.g. ["secret", "photos.internal_path"]. +record+
      # is what the ACL is asked about: the record being updated or a new one for
      # a create; nil asks as the schema does. Nested records are always judged
      # as new ones: finding an existing one would repeat StandardAPI's masked
      # lookup for every nested id.
      def for(controller, model, record, submitted)
        return [] unless submitted.is_a?(Hash)

        dropped(controller, model, record, submitted, nil, 0).uniq
      rescue StandardError
        []
      end

      private

      def dropped(controller, model, record, submitted, prefix, depth)
        accepted = Schema::Attributes.accepted(controller, model, record)
        accepted << 'id' if prefix
        paths = submitted.keys.map(&:to_s).reject { |key| accepted.include?(key) }.map { |key| [prefix, key].compact.join('.') }
        return paths if depth >= MAX_DEPTH

        Schema::Attributes.nested(controller, model).each do |reflection|
          klass = Schema::Input.klass_for(reflection) unless reflection.polymorphic?
          value = submitted[reflection.name.to_s]
          next unless klass

          path = [prefix, reflection.name].compact.join('.')
          Array.wrap(value).each do |item|
            next unless item.is_a?(Hash)

            paths.concat(dropped(controller, klass, klass.new, item, path, depth + 1))
          end
        end

        paths
      end
    end
  end
end
