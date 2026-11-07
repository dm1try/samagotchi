# frozen_string_literal: true

module Samagotchi
  class Engine
    # Hooks and reminders: turn-scoped hooks (register, clear), the hook
    # runtime's notify/ask/stop (HookRoutes, forwarded), the copy of the
    # conversation a hook reads, and the due reminders. Reads @hooks,
    # @hook_routes, @reminder_queue, @reminder_store.
    module HooksPart
      # @return [Array<String>] reminder names queued for a synthetic REPL turn
      def due_reminder_names
        @reminder_queue.pending_names
      end

      # Queue reminder names for a synthetic REPL turn (IdleReminders callback).
      def note_due_reminders(names)
        @reminder_queue.note_pending(names)
      end

      def clear_due_reminder_names!
        @reminder_queue.clear_pending!
      end

      # ── Hooks API ──────────────────────────────────────────────────────────────

      # Register a hook callback for a named lifecycle event.
      #
      # Hooks are turn-scoped: they are automatically cleared after each
      # `run_turn` call so that a single turn's hooks do not leak into the next.
      #
      # A hook that raises tells the user once, as a bundle's does
      # (HookRoutes#plugin_hook_failed); the registry logs each failure and goes on.
      #
      # @param name [Symbol] one of the hook names (see Hooks module)
      # @param block [Proc] receives an event hash (may mutate in place)
      # @return [void]
      def register_hook(name, &block)
        return @hooks.register(name) unless block

        @hooks.register(name) do |event|
          yield(event)
        rescue StandardError => e
          @hook_routes.plugin_hook_failed("#{Hooks::Registry::TURN_HOOK_LABEL} (#{name})", "#{e.class}: #{e.message}")
          raise
        end
      end

      # Unregister a previously registered hook.
      # @param name [Symbol]
      # @return [Boolean] true if it was removed, false if not found
      def unregister_hook(name)
        @hooks.unregister(name)
      end

      # Clear all registered hooks. Called automatically at the end of each
      # `run_turn` to keep hooks turn-scoped.
      # @return [void]
      def clear_hooks
        @hooks.clear_all
      end

      # ── Reminders API ────────────────────────────────────────────────────────────
      #
      # Each turn injects the reminders due then (#turn_messages,
      # ReminderQueue#inject!). Between turns the idle tick (IdleReminders)
      # finds them due and its callback queues their names
      # (#note_due_reminders); the worker and the REPL run a reminder turn
      # (a continue turn) for them.

      # @return [Boolean] whether any reminder is due now (the store's view,
      #   which a turn would inject), regardless of the queued names
      def reminders_due?
        @reminder_queue.due?
      end

      # @return [ReminderStore] the reminder store for inspection
      attr_reader :reminder_store

      # The conversation as a hook may read it: a frozen array of copied
      # messages, so a hook cannot change what the turn sends or stores.
      def hook_messages(messages)
        AnswerDisplay.strip_all(messages).map(&:dup).freeze
      end
      private :hook_messages

      # ── The hook runtime (HookRoutes) ───────────────────────────────────────

      # What a hook (Hooks::Runtime) and a plugin (Plugin::Host) can do beyond
      # reading its event, routed to the UIs by HookRoutes; these forward.
      def hook_runtime = @hook_routes.runtime
      private :hook_runtime

      def hook_source(hook) = @hook_routes.source(hook)
      private :hook_source

      # One line to the user (:hook_notice), HookRoutes#notify.
      def hook_notify(text, level, hook, fallback_for: nil, extra: {})
        @hook_routes.notify(text, level, hook, fallback_for: fallback_for, extra: extra)
      end
      private :hook_notify

      def guardrail_notify(message) = @hook_routes.guardrail_notify(message)
      private :guardrail_notify

      # @param question [HookQuestion]
      # @return [Hash, nil] {selected:, freeform:, selected_indices:}
      def hook_ask_user(question) = @hook_routes.ask_user(question)
      private :hook_ask_user

      # @return [Boolean] true when a running turn was cancelled now
      def hook_stop_turn(reason, hook) = @hook_routes.stop_turn(reason, hook)
      private :hook_stop_turn

      # @return [Boolean] true when a streaming generation was cut now
      def hook_stop_generation(reason, hook) = @hook_routes.stop_generation(reason, hook)
      private :hook_stop_generation
    end
  end
end
