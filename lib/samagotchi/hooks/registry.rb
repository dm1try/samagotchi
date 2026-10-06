# frozen_string_literal: true

require "monitor"
require_relative "../log"

module Samagotchi
  module Hooks
    # A hook plugin instance: a class whose initialize takes an argument
    # gets its settings (one positional Hash with string keys), any other
    # is built bare. `initialize(**kw)` is not told apart (arity -1 too)
    # and not supported.
    # @param klass [Class]
    # @param settings [Hash]
    def self.build_plugin(klass, settings)
      takes_settings = klass.instance_method(:initialize).arity != 0
      if takes_settings
        klass.new(settings.is_a?(Hash) ? settings : {})
      else
        klass.new
      end
    end

    # A stream hook (:generation_progress) fires ~once a second: a broken
    # one logs its failure once a minute, not on every fire.
    FAILED_STREAM_HOOK_LOG_SECONDS = 60

    # One hook's failure-log gate: called on each failure, it says whether
    # to log this one (a :generation_progress hook's at most once a
    # minute, any other hook's every time).
    # @param event [Symbol, String] the hook's event
    # @return [Proc] -> Boolean
    def self.failure_log_gate(event)
      quiet_for = event.to_s == "generation_progress" ? FAILED_STREAM_HOOK_LOG_SECONDS : 0
      logged_at = nil
      lambda do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        next false if logged_at && now - logged_at < quiet_for

        logged_at = now
        true
      end
    end

    # A hook file's class: the PascalCase of its basename (my_hook.rb →
    # MyHook), looked up in +namespace+ (a bundle's module; Object for a
    # config hook).
    # @return [Class]
    def self.class_for(file, namespace = Object)
      namespace.const_get(File.basename(file.to_s, ".rb").split("_").map(&:capitalize).join, false)
    end

    # A hook's block wrapped in its error policy: what a loader registers.
    # When the block raises,
    #   :deny  denies the call (event[:guardrail], the Gate's Verdict),
    #          whatever was raised: a fail-closed before_tool_call guardrail.
    #          The Gate folds the verdict into event[:blocked] and
    #          event[:block_reason] for the hooks after it.
    #   :log   warns (a stream hook at most once a minute, failure_log_gate)
    #   :skip  is silent
    # :log and :skip rescue StandardError and ScriptError.
    # @param label [String] the hook, for the deny reason and the warning
    # @param event [Symbol] the hook's event
    # @param log [Array(Symbol, String)] the warning's tag and record name
    # @param echo [Boolean] the warning also goes to stderr
    # @param fields [Hash] more fields for the warning's record
    def self.wrap(label:, event:, policy:, log: [:hooks, "hook_failed"], echo: true, fields: {}, &block)
      log_failure = failure_log_gate(event)
      lambda do |payload|
        yield(payload)
      rescue Exception => e # rubocop:disable Lint/RescueException -- :deny fails closed on anything
        raise unless policy == :deny || e.is_a?(StandardError) || e.is_a?(ScriptError)

        failed = "#{e.class}: #{e.message}"
        if policy == :deny
          payload[:guardrail]&.deny!("#{label} raised #{failed}", rule: "guardrail-load", source: "core", decided_by: "core") if payload.is_a?(Hash)
        elsif policy == :log && log_failure.call
          text = "#{label} failed: #{failed}"
          Log.warn(log[0], log[1], echo: echo ? "[samagotchi:hooks] #{text}" : nil, hook: label, event: event.to_s,
                                   error: e.class.name, msg: text, **fields)
        end
      end
    end

    # What a hook can do beyond reading its event: the Engine's
    # callables, each given the hook's label. +notify+ takes
    # (text:, level:, hook:, and fallback_for: when the hook gave one: what
    # the line stands in for, Engine#hook_notify) and shows one line to the
    # user; +ask_user+ takes (question:, options:, header:, allow_freeform:, hook:) and
    # returns the answer hash or nil; +stop_turn+ takes (reason:, hook:) and
    # cancels the running turn (true when it did); +steer+ takes (text:,
    # hook:) and puts the text into the running turn (Engine#steer, true
    # when queued); +stop_generation+ takes (reason:, hook:) and cuts the
    # streaming generation while the turn goes on (true when it did). A
    # registry without one gives hooks no-op helpers.
    Runtime = Struct.new(:notify, :ask_user, :stop_turn, :steer, :stop_generation, keyword_init: true)

    # A thread-safe registry for named hook callbacks.
    #
    # Each hook is stored as a Proc that receives an event hash (passed by
    # reference — mutations on the hash survive). The registry supports
    # per-hook registration/unregistration, clearing all hooks, and
    # synchronous dispatch.
    #
    # Every fire puts the hook runtime on the event: +event[:hook]+ (the
    # label of the proc about to run: "<file> (bundle <name>)", a config
    # hook's label, or "turn hook"), and the helpers +event[:notify]+,
    # +event[:ask_user]+, +event[:stop_turn]+, +event[:steer]+ and
    # +event[:stop_generation]+ (see #fire). Keys the fire
    # site put on the event are never overwritten.
    #
    # Thread safety is achieved via Monitor.
    class Registry
      TURN_HOOK_LABEL = "turn hook"
      CONFIG_HOOK_LABEL = "config hook"
      # Events after which there is no turn left to stop.
      TURN_OVER_EVENTS = %i[after_turn session_end].freeze

      # @return [Runtime, nil] what the helpers call (the Engine sets it)
      attr_accessor :runtime

      def initialize
        @mutex = Monitor.new
        @hooks = {} # name -> Array<Proc> (manual, turn-scoped hooks, run last)
        @persistent_hooks = {} # name -> Array<{label:, proc:}> (config.yml hooks, survive clear_all)
        @bundle_hooks = {} # name -> Array<{bundle:, hook_name:, priority:, proc:}>
        @runtime = nil
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
      # @param label [String, nil] what event[:hook] names the hook by
      #   (the loader passes the file); default "config hook"
      # @return [void]
      def register_persistent(name, label: nil, &block)
        raise ArgumentError, "hook name must be a Symbol" unless name.is_a?(Symbol)
        raise ArgumentError, "hook block is required" unless block_given?

        label = label.to_s.strip
        label = CONFIG_HOOK_LABEL if label.empty?
        @mutex.synchronize { (@persistent_hooks[name] ||= []) << { label: label, proc: block } }
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
      # All procs get the same hash, so event[:hook] is set before each one;
      # the helpers are set once per fire and read event[:hook] when called:
      #   event[:notify].call(text, level: :info, fallback_for: nil)   one line
      #     to the user; fallback_for: :display marks a line that stands in
      #     for the answer's display (event[:present]), which a UI that
      #     renders the display's links leaves out (Engine#hook_notify)
      #   event[:ask_user].call(question:, options:, header: nil, allow_freeform: false)
      #     -> {selected:, freeform:, selected_indices:} or nil (no one to
      #     ask, cancelled, bad options)
      #   event[:stop_turn].call(reason) -> true when the turn was cancelled;
      #     in a before_tool_call event it also denies the call; from
      #     after_turn / session_end it does nothing (false)
      #   event[:steer].call(text) -> true when the text was queued for the
      #     running turn's next boundary (its own user message, source: the
      #     hook's bundle); from after_turn / session_end false
      # and after_turn's fire site adds one more (AnswerDisplay):
      #   event[:present].call { |text| new_text } -> the answer's display
      #     text after the call (chained in hook order), nil without an answer
      #
      # @param name [Symbol] the hook name to fire
      # @param event [Hash] the event payload (may be mutated by hooks)
      # @return [void]
      def fire(name, event)
        procs = ordered_procs(name)
        return if procs.empty?

        with_runtime(event)
        procs.each do |label, hook_proc|
          event[:hook] = label if event.is_a?(Hash)
          begin
            hook_proc.call(event)
          rescue StandardError => e
            # A failing hook must not break the turn.
            Log.exception(:hooks, "hook_failed", e, echo: "[samagotchi:hooks] #{label} failed: #{e.class}: #{e.message}",
                                                hook: label, event: name.to_s)
          end
        end
      end

      # Whether a #fire of +name+ would call any hook.
      # @param name [Symbol]
      # @return [Boolean]
      def any?(name)
        !ordered_procs(name).empty?
      end

      # Like #fire, and yields the event after each hook (a raising one
      # too), so the caller can fold what that hook did before the next one
      # runs (the guardrail gate keeps a deny sticky this way).
      # @yieldparam event [Hash]
      # @return [void]
      def fire_each(name, event)
        procs = ordered_procs(name)
        return if procs.empty?

        with_runtime(event)
        procs.each do |label, hook_proc|
          event[:hook] = label if event.is_a?(Hash)
          begin
            hook_proc.call(event)
          rescue StandardError => e
            # A failing hook must not break the turn.
            Log.exception(:hooks, "hook_failed", e, echo: "[samagotchi:hooks] #{label} failed: #{e.class}: #{e.message}",
                                                hook: label, event: name.to_s)
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

      # Returns the ordered [label, proc] pairs for an event: bundle hooks
      # sorted by (priority, bundle, hook_name), then config hooks, then
      # turn-scoped hooks, each in registration order.
      def ordered_procs(name)
        @mutex.synchronize do
          bundle_procs = (@bundle_hooks[name] || [])
            .sort_by { |h| [h[:priority].to_i, h[:bundle].to_s, h[:hook_name].to_s] }
            .map { |h| ["#{h[:hook_name]} (bundle #{h[:bundle]})", h[:proc]] }
          config_procs = (@persistent_hooks[name] || []).map { |h| [h[:label], h[:proc]] }
          turn_procs = (@hooks[name] || []).map { |hook_proc| [TURN_HOOK_LABEL, hook_proc] }
          bundle_procs + config_procs + turn_procs
        end
      end

      # The helpers, once per fire; a fire site's own keys stay.
      def with_runtime(event)
        return unless event.is_a?(Hash)

        event[:notify] ||= lambda { |text, level: :info, fallback_for: nil|
          notice = { text: text.to_s, level: level, hook: event[:hook] }
          notice[:fallback_for] = fallback_for unless fallback_for.nil?
          @runtime&.notify&.call(**notice)
          nil
        }
        event[:ask_user] ||= lambda { |question:, options:, header: nil, allow_freeform: false|
          @runtime&.ask_user&.call(question: question, options: options, header: header,
                                   allow_freeform: allow_freeform, hook: event[:hook])
        }
        event[:stop_turn] ||= lambda { |reason|
          next false if TURN_OVER_EVENTS.include?(event[:type])

          if event[:type] == :before_tool_call && event[:guardrail].respond_to?(:deny!)
            event[:guardrail].deny!("the turn was stopped by #{event[:hook]}: #{reason}")
          end
          @runtime&.stop_turn&.call(reason: reason.to_s, hook: event[:hook]) ? true : false
        }
        event[:steer] ||= lambda { |text|
          next false if TURN_OVER_EVENTS.include?(event[:type])

          @runtime&.steer&.call(text: text.to_s, hook: event[:hook]) ? true : false
        }
        event[:stop_generation] ||= lambda { |reason|
          next false if TURN_OVER_EVENTS.include?(event[:type])

          @runtime&.stop_generation&.call(reason: reason.to_s, hook: event[:hook]) ? true : false
        }
      end
    end
  end
end
