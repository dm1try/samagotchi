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
        @hooks = {} # name -> Array<Proc> (manual, turn-scoped hooks, run last)
        @persistent_hooks = {} # name -> Array<Proc> (config.yml hooks, survive clear_all)
        @bundle_hooks = {} # name -> Array<{bundle:, hook_name:, priority:, proc:}>
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

      # Register a process-scoped plain hook (config.yml). Unlike #register it
      # survives the per-turn #clear_all, so configured hooks fire on every
      # turn, not only the first. Fires after bundle hooks, before
      # turn-scoped ones.
      # @param name [Symbol] hook event identifier
      # @return [void]
      def register_persistent(name, &block)
        raise ArgumentError, "hook name must be a Symbol" unless name.is_a?(Symbol)
        raise ArgumentError, "hook block is required" unless block_given?
        @mutex.synchronize { (@persistent_hooks[name] ||= []) << block }
      end

      # Register a bundle-owned hook. Bundle hooks are ordered by
      # (priority, bundle_name, hook_name) and fire BEFORE any plain
      # (config.yml / manual) hooks registered via #register.
      #
      # @param bundle_name [String] owning bundle
      # @param event_name [Symbol] hook event identifier
      # @param hook_name [String] logical hook name (e.g. file basename)
      # @param priority [Integer] lower runs first
      # @return [void]
      def register_bundle(bundle_name, event_name, hook_name:, priority: 100, &block)
        raise ArgumentError, "hook block is required" unless block_given?
        @mutex.synchronize do
          (@bundle_hooks[event_name] ||= []) << {
            bundle: bundle_name,
            hook_name: hook_name,
            priority: priority,
            proc: block
          }
        end
      end

      # Unregister all hooks owned by a bundle.
      # @param bundle_name [String]
      # @param event_name [Symbol, nil] restrict to one event (nil = all events)
      # @return [Integer] number of hooks removed
      def unregister_bundle(bundle_name, event_name = nil)
        removed = 0
        @mutex.synchronize do
          if event_name
            arr = @bundle_hooks[event_name]
            return 0 unless arr
            before = arr.size
            @bundle_hooks[event_name] = arr.reject { |h| h[:bundle] == bundle_name }
            removed = before - @bundle_hooks[event_name].size
            @bundle_hooks.delete(event_name) if @bundle_hooks[event_name].empty?
          else
            @bundle_hooks.each do |_event, arr|
              before = arr.size
              arr.reject! { |h| h[:bundle] == bundle_name }
              removed += before - arr.size
            end
            @bundle_hooks.reject! { |_, arr| arr.empty? }
          end
        end
        removed
      end

      # Unregister a hook by name.
      # @param name [Symbol]
      # @return [Boolean] true if it was removed, false if not found
      def unregister(name)
        @mutex.synchronize do
          removed_plain = @hooks.delete(name)
          removed_persistent = @persistent_hooks.delete(name)
          !!(removed_plain || removed_persistent)
        end
      end

      # Remove all turn-scoped hooks (registered via #register).
      # Bundle hooks (#unregister_bundle) and config hooks (#register_persistent)
      # are process-scoped and survive the per-turn clear_all, so guardrails
      # and configured hooks apply to every turn.
      # @return [void]
      def clear_all
        @mutex.synchronize do
          @hooks.clear
        end
      end

      # Dispatch an event to all registered hooks under the given name.
      #
      # Each hook receives the *same* event hash by reference, so hooks can
      # mutate fields to affect downstream behavior. A hook that raises is
      # caught and ignored so that one misbehaving hook cannot break the
      # running turn.
      #
      # Ordering: bundle hooks (sorted by priority, then bundle, then hook
      # name) fire first; config hooks next; turn-scoped hooks last, each in
      # registration order.
      #
      # @param name [Symbol] the hook name to fire
      # @param event [Hash] the event payload (may be mutated by hooks)
      # @return [void]
      def fire(name, event)
        procs = ordered_procs(name)
        return if procs.empty?

        procs.each do |hook_proc|
          begin
            hook_proc.call(event)
          rescue StandardError
            # A failing hook must not break the turn.
          end
        end
      end

      # Like #fire, and yields the event after each hook (a raising one
      # too), so the caller can fold what that hook did before the next one
      # runs (the guardrail gate keeps a deny sticky this way).
      # @yieldparam event [Hash]
      # @return [void]
      def fire_each(name, event)
        ordered_procs(name).each do |hook_proc|
          begin
            hook_proc.call(event)
          rescue StandardError
            # A failing hook must not break the turn.
          end
          yield event
        end
      end

      # @return [Integer] total number of registered hooks (bundle + plain)
      def size
        @mutex.synchronize do
          @hooks.values.sum(&:size) + @persistent_hooks.values.sum(&:size) + @bundle_hooks.values.sum(&:size)
        end
      end

      private

      # Returns the ordered list of procs for an event: bundle hooks sorted by
      # (priority, bundle, hook_name), then config hooks, then turn-scoped
      # hooks, each in registration order.
      def ordered_procs(name)
        @mutex.synchronize do
          bundle_procs = (@bundle_hooks[name] || [])
            .sort_by { |h| [h[:priority].to_i, h[:bundle].to_s, h[:hook_name].to_s] }
            .map { |h| h[:proc] }
          bundle_procs + (@persistent_hooks[name] || []) + (@hooks[name] || [])
        end
      end
    end
  end
end
