# frozen_string_literal: true

module Samagotchi
  class Engine
    # The tool guardrails (GuardrailWiring, forwarded): who answers an
    # approval, the rules and approvals, their state dir, and the load
    # warnings the first turn announces. Writes @state_dir,
    # @guardrail_failures_announced; reads @guardrail_wiring,
    # @guardrail_failures, @plugin_failures, @hook_routes.
    module GuardrailsPart
      # ── Guardrails ─────────────────────────────────────────────────────────────

      # Who can answer an approval: :worker or :non_interactive (the
      # default, so a bare Engine denies instead of waiting for nobody). Set
      # by the host (TerminalUI, Worker).
      def interface
        @guardrail_wiring.interface
      end

      def interface=(value)
        @guardrail_wiring.interface = value
      end

      def guardrail_state_dir=(state_dir)
        # Also where list_sessions and send_note look for other sessions.
        @state_dir = state_dir
        @guardrail_wiring.state_dir = state_dir
      end

      # The YAML rules, read again when a file changed (GuardrailWiring#rules).
      # @return [Guardrails::Rules]
      def guardrail_rules
        @guardrail_wiring.rules
      end

      # @return [Guardrails::LoadFailures]
      attr_reader :guardrail_failures

      # @return [Guardrails::Approvals]
      def guardrail_approvals
        @guardrail_wiring.approvals
      end

      # @return [Guardrails::LoadFailures] the plugins that failed to load
      attr_reader :plugin_failures

      # Once per Engine, on its first turn: what failed to load, so every UI
      # (the attached TUI, the web, a one-shot's stderr) shows it: the guardrails, then the plugins
      # (label: "plugins"; the UIs say guardrails without one), an orphaned
      # project memory folder (label: "memory"), then the notices and cards plugins showed as they loaded.
      def announce_guardrail_failures(on_event)
        return if @guardrail_failures_announced

        @guardrail_failures_announced = true
        message = @guardrail_failures.message
        emit_event(on_event, { type: :guardrail_warning, message: message }) if message
        plugins = @plugin_failures.message
        emit_event(on_event, { type: :guardrail_warning, message: plugins, label: "plugins" }) if plugins
        memory = MemoryOrphans.message
        emit_event(on_event, { type: :guardrail_warning, message: memory, label: "memory" }) if memory
        @extension_load.held_events.each { |event| emit_event(on_event, event) }
      end
      private :announce_guardrail_failures

      # The warning the first turn announced (nil before it, or with nothing
      # failed), for a UI that joins later (Bridge#snapshot).
      def guardrail_warning
        @guardrail_failures.message if @guardrail_failures_announced
      end

      # The plugins' load warning the first turn announced, likewise, and what
      # their failed chi.on handlers told (HookRoutes#plugin_hook_failed).
      def plugin_warning
        loaded = @plugin_failures.message if @guardrail_failures_announced
        [loaded, @hook_routes.hook_failures_message].compact.join("; ").then { |text| text unless text.empty? }
      end

      # Ask the user to approve a call the gate voted `ask` on
      # (GuardrailWiring#request_approval), for the running turn (its
      # author), else the last one. The gate's own asks come with their
      # call's TurnContext instead.
      # @param verdict [Guardrails::Verdict]
      # @return [Guardrails::Verdict]
      def request_approval(verdict)
        @guardrail_wiring.request_approval(verdict, turn_context || last_turn_context)
      end
    end
  end
end
