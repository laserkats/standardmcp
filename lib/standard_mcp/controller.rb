require 'active_support/concern'
require 'active_support/core_ext/class/attribute'

module StandardMCP
  module Controller
    extend ActiveSupport::Concern

    # The StandardAPI actions that become MCP tools.
    ACTIONS = %i[index show create update destroy calculate].freeze

    # One `allow_mcp` call. `only` is nil when every action is a candidate.
    Rule = Data.define(:only, :except, :if, :unless) do
      # Actions this rule names, before intersecting with the controller's
      # real actions.
      def actions
        (only || ACTIONS) - except
      end

      def passes?(controller)
        self.if.all? { |c| Rule.evaluate(c, controller) } &&
          self.unless.none? { |c| Rule.evaluate(c, controller) }
      end

      def self.evaluate(condition, controller)
        case condition
        when Symbol then controller.send(condition)
        when Proc
          condition.arity == 0 ? controller.instance_exec(&condition) : condition.call(controller)
        end
      end
    end

    included do
      class_attribute :mcp_rules, instance_writer: false, default: [].freeze
    end

    class_methods do
      # Opt this controller's actions in as MCP tools. Options follow
      # `before_action`; conditions are evaluated per request so a tool can be
      # hidden from some callers. May be called more than once: an action is
      # exposed when any rule covers it and that rule's conditions pass.
      def allow_mcp(only: nil, except: nil, if: nil, unless: nil)
        unless ancestors.include?(StandardAPI::Controller)
          raise ArgumentError, "#{name || self} must include StandardAPI::Controller to use allow_mcp"
        end
        raise ArgumentError, 'allow_mcp accepts only: or except:, not both' if only && except

        rule = Rule.new(
          only: only && normalize_mcp_actions(only, :only).freeze,
          except: normalize_mcp_actions(except, :except).freeze,
          if: normalize_mcp_conditions(binding.local_variable_get(:if), :if).freeze,
          unless: normalize_mcp_conditions(binding.local_variable_get(:unless), :unless).freeze
        )
        self.mcp_rules = (mcp_rules + [rule]).freeze
        rule
      end

      # Actions exposed by some rule, ignoring conditions. Static, so it is
      # safe to use when building tools at boot.
      def mcp_actions
        available = action_methods
        covered = mcp_rules.flat_map(&:actions)
        ACTIONS.select { |a| covered.include?(a) && available.include?(a.to_s) }
      end

      def mcp_enabled?
        mcp_actions.any?
      end

      private

      def normalize_mcp_actions(actions, option)
        actions = Array(actions).map { |a| a.respond_to?(:to_sym) ? a.to_sym : a }
        unknown = actions - ACTIONS
        if unknown.any?
          raise ArgumentError, "Unknown MCP action(s) in #{option}: #{unknown.map(&:inspect).join(', ')}. " \
            "Valid actions: #{ACTIONS.map(&:inspect).join(', ')}"
        end
        actions.uniq
      end

      def normalize_mcp_conditions(conditions, option)
        Array(conditions).flatten.each do |c|
          next if c.is_a?(Symbol) || c.is_a?(Proc)
          raise ArgumentError, "#{option}: conditions must be a Symbol or Proc, got #{c.inspect}"
        end
      end
    end

    # Actions exposed for the current request: those whose covering rule's
    # conditions pass on this instance.
    def mcp_actions_allowed
      candidates = self.class.mcp_actions
      candidates.select do |action|
        self.class.mcp_rules.any? { |r| r.actions.include?(action) && r.passes?(self) }
      end
    end
  end
end
