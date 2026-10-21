module StandardMCP
  module Schema
    # What a caller may query on a model, as StandardAPI will check it: the
    # ACL's `wheres` (keys, and optionally the operators allowed on each), read
    # the way StandardAPI's own check reads them. Shared by QueryDocument, which
    # describes it, and Where, which validates calls against it.
    module Query
      # How an association reads in the documents.
      KINDS = {
        belongs_to: 'belongs_to',
        has_many: 'has_many',
        has_one: 'has_one',
        has_and_belongs_to_many: 'habtm'
      }.freeze

      class << self
        # The ACL `wheres` for +model+, normalized by StandardAPI:
        # `{ 'key' => :all | ['eq', 'in', ...] }`, canonical operator names
        # (`neq` for not). Names an ACL `excludes` hides are dropped. A model
        # whose ACL has no `wheres` can't be filtered on.
        def permits(controller, model)
          hidden = Input.hidden(controller, model)
          permit = controller.send(:normalize_where_permit, controller.send(:wheres_for, model))
          permit.reject { |name, _| hidden.include?(name) }
        end

        # How a permitted key reads on +model+, the way StandardAPI's check
        # resolves it: :filter (a `filter_on` filter), :attribute (a column, or
        # a definition: +definitions+ is a Definitions::Result), :association
        # (with the reflection) or :other (permitted by name, e.g. a join table).
        def classify(model, definitions, key)
          return [:filter] if model.filters.key?(key)

          name = key.split('.').first
          return [:attribute] if model.columns_hash.key?(name) || definitions&.find(name)

          reflection = model.reflect_on_association(key)
          reflection ? [:association, reflection] : [:other]
        end

        # An association's entry in a document: its name, its kind (unless
        # +kind+ is false) and the resource that serves its model (+links+ maps
        # a model to a resource name); no columns of the associated model.
        # A polymorphic association has no model, so no resource.
        def association_entry(model, name, links, kind: true)
          reflection = model.reflect_on_association(name)
          return if reflection.nil?

          klass = Input.klass_for(reflection) unless reflection.polymorphic?
          entry = { 'name' => name.to_s }
          entry['kind'] = KINDS.fetch(reflection.macro, reflection.macro.to_s) if kind
          entry['resource'] = links[klass] if klass && links[klass]
          entry
        end

        # The operator names of a kind of value, narrowed to what the ACL's
        # list +permitted+ allows (:all keeps them all). The ACL names operators
        # canonically, so `not` is allowed by `neq`.
        def allowed_operators(controller, operators, permitted)
          return operators if permitted == :all || permitted.nil?

          operators.select { |operator| permitted.include?(controller.send(:canonical_operator, operator)) }
        end
      end
    end
  end
end
