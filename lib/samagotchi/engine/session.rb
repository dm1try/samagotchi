# frozen_string_literal: true

module Samagotchi
  class Engine
    # The bound session and its prompt: #session= (its recap, metrics and
    # memories), its state dir, the relay's view, and the system prompt with
    # the memory names it holds. Writes @session, @session_state_dir,
    # @running_turn_messages; reads @prompt_builder, @metrics, @used_memories,
    # @question_desk, @state_dir.
    module SessionPart
      # @return [Array<String>] deduped used memory names (thread-safe copy)
      def used_memory_names
        @used_memories.names
      end

      # @return [Array<String>] the memories hidden from this session (normalized names)
      def muted_memory_names
        @muted_memory_names.dup
      end

      # @return [Array<String>] the names the session preloads (config baseline
      #   + --memory, minus mutes), known before the prompt is built, unlike
      #   #activated_memory_names
      def preloaded_memory_names
        @prompt_builder.preloaded_memory_names
      end

      # Where the approval store lives: beside Session's state dir
      # ($XDG_STATE_HOME/samagotchi/guardrails/). A Worker with its own state
      # dir passes it.
      # Where sessions live (a session's images/ are under it); a worker sets
      # its own.
      attr_writer :session_state_dir

      # The metrics load the session's saved records from its state dir, once.
      def bind_metrics(session)
        return unless session&.id

        @metrics.state_dir = session_state_dir
        @metrics.session_id = session.id
      end

      def session_state_dir = @session_state_dir || Session.default_state_dir

      # The running turn's metrics so far, saved as a turn a worker died in
      # would leave them (SessionMetrics#persist's running_turn): a worker's
      # turn checkpoint (TurnCheckpoint) calls it when it writes.
      # @return [Boolean] whether they were saved
      def checkpoint_metrics = @metrics.persist(state_dir: session_state_dir, running_turn: true)

      # What a Bridge adds to a plugin's ctx.messages while a turn runs (the
      # turn so far, as messages); nil without a Bridge (the REPL).
      attr_writer :running_turn_messages

      # The system prompt for a target's loop (default: the effective model's):
      # the chat loop's leaves out the raw-prompt tool text, since its tools go
      # as schemas. Built once per loop (and again after a model switch) so the
      # prompt prefix, and the server's KV cache for it, stay stable.
      # @param model [EffectiveModel, nil]
      # @return [String]
      # The native prompt depends on the thinking level too (Gemma's token):
      # a level change builds it again. A build that
      # misses the cache names the model and the level through its own
      # lambdas (#model_identity, #turn_thinking), which resolve again.
      def system_prompt(model = nil)
        model ||= effective_model
        chat = model.chat?
        level = chat ? nil : @model_settings.thinking_level(model)
        prompt = @prompt_builder.build(chat: chat, thinking: level, layers: model.llm_context_layers(@model_settings.llm_context_session_args))
        # The memory indexes this prompt holds: /stats, the snapshot, analytics.json.
        @metrics.memory_index = @prompt_builder.memory_index
        # The model notes it carries: the session records them (/stats, /model, the web).
        record_prompt_notes(@prompt_builder.prompt_notes)
        prompt
      end

      # The base prompt (specs, plugins' declarations).
      def assist_system_prompt(chat: false)
        @prompt_builder.base(chat: chat)
      end

      # The --memory names activated while building the prompt; the TerminalUI
      # mirrors them into its status line.
      def activated_memory_names
        @prompt_builder.activated_memory_names
      end

      # @return [Session] current session (Engine owns create/resume)
      attr_reader :session

      # This worker's relays of its delegates' approvals (memory only).
      # @return [RelayDesk]
      attr_reader :relay_desk

      # The relay's view of this Engine, or nil when it can't host a relay: a
      # worker's Engine only (its Bridge is what a child verifies against;
      # --non-interactive has no one to ask), never with a REPL's sync
      # handler (no wait loop, no watch).
      # @return [RelayPeer, nil]
      def relay_peer
        return nil unless interface == :worker && !@question_desk.sync_handler?

        RelayPeer.new(self)
      end

      # @return [String] the state dir holding this Engine's sessions
      def peer_state_dir = @state_dir

      # Set the current session outside a turn (the REPL does, before its first
      # turn, so the messages API and recap see it)
      def session=(session)
        @session = session
        # One session per REPL/worker process: its records carry this sid.
        Log.session_id = session.id if session&.id
        # Its own recap values (chi --set recap.enabled=false) rebuild the job.
        rebuild_recap!
        # A woken worker's /stats and status line count the turns before it.
        bind_metrics(session)
        @used_memories.absorb(session)
        # Loaded on another model than its last turn ran on (a --resume'd
        # REPL's --model, a worker woken after a /model with no turn since):
        # the saved ctx % was that model's window's. Drop it and count it as
        # /model does, on a configured window only: this runs before a
        # worker's Bridge serves, so no /props GET or model list here (a slow
        # or hung host would hold up the worker's start). No configured
        # window: no % (ctx ?) until the first generation reports one.
        return unless model_switched_since_last_turn?

        @metrics.forget_model_reports!
        announce_switched_context!(configured_only: true)
      end
    end
  end
end
