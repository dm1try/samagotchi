# frozen_string_literal: true

require "monitor"

module Samagotchi
  module Hooks
    # A thread-safe registry for named hook callbacks.
    #
    # Each hook is stored as a Proc that receives an event hash (passed by
    # reference — mutations on the hash survive). The registry supports
    # per-hook registration/unregistration, clearing all hooks, and
    # synchronous dispatch.
    #
    # Thread safety is achieved via Monitor.
    class Registry
      def initialize
        @mutex = Monitor.new
        @hooks = {} # name -> Array<Proc>
      end

      # Register a hook with the given name.
      # Multiple hooks can be registered under the same name; they fire in
      # registration order.
      # @param name [Symbol] hook event identifier
      # @param block [Proc] receives an event hash (mutated in place)
      # @return [void]
      def register(name, &block)
        raise ArgumentError, "hook name must be a Symbol" unless name.is_a?(Symbol)
        raise ArgumentError, "hook block is required" unless block_given?
        @mutex.synchronize { (@hooks[name] ||= []) << block }
      end

      # Unregister a hook by name.
      # @param name [Symbol]
      # @return [Boolean] true if it was removed, false if not found
      def unregister(name)
        @mutex.synchronize { !!@hooks.delete(name) }
      end

      # Remove all registered hooks.
      # @return [void]
      def clear_all
        @mutex.synchronize { @hooks.clear }
      end

      # Dispatch an event to all registered hooks under the given name.
      #
      # Each hook receives the *same* event hash by reference, so hooks can
      # mutate fields to affect downstream behavior. A hook that raises is
      # caught and ignored so that one misbehaving hook cannot break the
      # running turn.
      #
      # @param name [Symbol] the hook name to fire
      # @param event [Hash] the event payload (may be mutated by hooks)
      # @return [void]
      def fire(name, event)
        hooks = @mutex.synchronize { @hooks[name] }
        return unless hooks

        hooks.each do |hook_proc|
          begin
            hook_proc.call(event)
          rescue StandardError
            # A failing hook must not break the turn.
          end
        end
      end

      # @return [Integer] total number of registered hooks
      def size
        @mutex.synchronize { @hooks.values.sum(&:size) }
      end
    end
  end
end
