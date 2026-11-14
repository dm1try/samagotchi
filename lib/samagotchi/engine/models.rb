# frozen_string_literal: true

require_relative "../config"
require_relative "../effective_model"
require_relative "../llm/backend"
require_relative "../llm/errors"
require_relative "../log"
require_relative "../model_notes"
require_relative "../model_profile"
require_relative "../prompt_note"
require_relative "../system_prompt"

module Samagotchi
  class Engine
    # The model: its names and refs, identity and notes, /model's switch (and
    # the context it shows after), the profile (ModelBinding's, forwarded) and
    # the loop it runs on. Writes @client, @default_model_name,
    # @last_context_status, @chat_backend; reads @model_binding, @host_registry,
    # @kernel, @metrics, @prompt_builder.
    module ModelsPart
      # The backend for the next turn: the loop the effective model's host speaks.
      def backend(model = effective_model)
        backend_for(model)
      end

      # The model as given (maybe an alias; HostRegistry#resolve applies it).
      def effective_model_name = @model_binding.choice.name

      # The model as typed at start or at the last /model.
      def typed_model_name = @model_binding.choice.typed

      # The resolved ref a session stores for the effective model (ModelRef#ref:
      # the alias applied, "host:id" when it names a host).
      def effective_model_ref
        model_ref_for(effective_model_name)
      end

      # The effective model as the system prompt names it (SystemPrompt::ModelIdentity):
      # the ref, its host, the overlay key and, for a local llama.cpp host
      # only, the model its /props names when that differs. Never a new
      # request: only the /props answer profile resolution already cached.
      def model_identity
        model = effective_model
        entry = model.entry
        host = entry && "host #{entry.name}, #{entry.url || "#{entry.host}:#{entry.port}"}"
        SystemPrompt::ModelIdentity.new(ref: model.ref, host: host, key: @model_binding.model_key,
                                        served: model.prompt_served, fallback_key: @model_binding.fallback_model_key)
      end

      # The model notes for the effective model (ModelNotes): matched on its
      # bare id and key, the session's mutes left out.
      # @return [Array<ModelNotes::Note>]
      def model_notes
        ModelNotes.for(name: guardrail_model_name, key: @model_binding.model_key, fallback_key: @model_binding.fallback_model_key,
                       muted: @muted_memory_names)
      end

      # The model notes the session's prompt carried at its last build
      # (Session#prompt_notes): a resumed session's or a woken worker's saved
      # ones until this process builds its prompt; a fresh session (no build
      # yet, no messages) has none saved, so the effective model's prompt
      # would load them: the notes #model_notes names, as without a session.
      # The three readers (/model, /stats, the web) share this.
      # @return [Array<PromptNote>]
      def prompt_notes
        return model_notes.map { |note| PromptNote.from_note(note) } unless @session

        saved = @session.prompt_notes
        return saved.dup if !@prompt_builder.prompt_notes.nil? || !saved.empty? || @session.messages.to_a.any?

        model_notes.map { |note| PromptNote.from_note(note) }
      rescue StandardError => e
        Log.warn(:model, "prompt_notes_failed", error: e.class.name, msg: e.message.to_s[0, 200])
        []
      end

      # Records +notes+ (ModelNotes::Note) on the session as the ones its
      # prompt carries; saved with it.
      def record_prompt_notes(notes)
        @session.prompt_notes = Array(notes).map { |note| PromptNote.from_note(note) } if @session && notes
      end
      private :record_prompt_notes

      # A failed turn's one line (the error's #summary). A host's failure
      # under an alias says what the alias became (HostRegistry#alias_note):
      # "host main" alone doesn't tell --model splash's user it was splash.
      # @return [String]
      def failure_summary(error)
        summary = error.respond_to?(:summary) ? error.summary : error.message
        return summary unless error.is_a?(LLM::ProviderError) && error.host

        note = @host_registry.alias_note(effective_model_name)
        note && note.end_with?("on host #{error.host}") ? "#{summary} (#{note})" : summary
      rescue StandardError => e
        EffectiveModel::Unresolved.fallback(:alias_note_failed, effective_model_name, e, summary)
      end

      # +name+'s resolved ref (ModelRef#ref).
      def model_ref_for(name)
        @host_registry.model_ref(name).ref
      end

      # The ref #switch_model! would switch +model_name+ to, checked the way it
      # checks one (UnknownHost, MissingModel), without switching.
      # @return [String]
      def model_switch_ref(model_name)
        model_ref_for(ModelProfile.check_host!(ModelProfile.required_model_name(model_name), hosts: @host_registry.entries))
      end

      # Writes the effective model to +session+: the resolved ref, and the
      # name as typed when that differs (model_typed: an alias, for the
      # models: lookup after a resume).
      def store_model!(session)
        ref = effective_model_ref
        session.model_name = ref
        typed = typed_model_name
        session.model_typed = typed.to_s == ref ? nil : typed
        session
      end

      # The effective model's key (ModelOverlay.key_for its bare name): memory
      # overlays, guardrail rules' models:.
      # @return [String, nil]
      def model_key = @model_binding.model_key

      # The prompt profile for the effective model (see #profile_resolution).
      # @return [ModelProfile]
      def profile = profile_resolution.profile

      # Which profile the effective model gets and where that came from,
      # kept with the model choice it was resolved for
      # (ModelBinding#profile_resolution).
      # @return [ModelProfile::Resolution]
      def profile_resolution = @model_binding.profile_resolution

      # The model id sent for +full_ref+ (its alias applied, the host prefix off).
      def bare_model_name(full_ref)
        @host_registry.bare_name(full_ref)
      end

      # The memory overlay keys follow the model sent (ModelBinding#sync_model_key!).
      def sync_model_key! = @model_binding.sync_model_key!
      private :sync_model_key!

      # The effective model's bare name for the guardrails' models: rules;
      # nil without a model name.
      def guardrail_model_name
        model = effective_model_name
        name = model && bare_model_name(model)
        name.to_s.strip.empty? ? nil : name
      end

      # Point the kernel (and a chat backend) at the effective model's host
      # (after /model, --model, resume).
      def sync_kernel_client!(model = effective_model)
        @client = model.client
        @kernel.client = model.client if @kernel.client != model.client
        backend_for(model)
      end

      # ── Model switching ────────────────────────────────────────────────────────

      # @param typed [String, nil] the name the model was typed as when
      #   +model_name+ is a stored ref (a resumed session's model_typed)
      # @return [String] the resolved ref the session stores (ModelRef#ref)
      def switch_model!(model_name, persist_default: false, typed: nil)
        # The alias is applied where the model is resolved (HostRegistry#resolve),
        # once; checked here: an unknown host, an alias naming another host.
        resolved = ModelProfile.check_host!(ModelProfile.required_model_name(model_name), hosts: @host_registry.entries)
        choice = ModelChoice.new(name: resolved, typed: typed.to_s.strip.empty? ? model_name : typed.to_s.strip)
        @model_binding.switch!(choice)
        sync_model_key!
        @prompt_builder.reset!
        # The notes the new model's prompt loads at its next build, so /model,
        # /stats and the web name them before the next turn does.
        record_prompt_notes(model_notes) if @session
        sync_kernel_client!
        @client.invalidate_context_window!
        @metrics.forget_model_reports!
        # The last turn's ctx % was the old model's window's
        # (#announce_switched_context! sends the new one's).
        @last_context_status = nil
        ref = effective_model_ref
        if persist_default
          ConfigFile.write_default_model!(ref)
          @default_model_name = ref
        end
        ref
      end

      # After /model: how full the context is on the new model's window,
      # before its first turn: the last turn's count (the old model's
      # tokenizer's, replaced at the next generation) against the new model's
      # window (EffectiveModel#context_window, ContextWindow.resolve: the
      # running server first, one /props GET that a remote chat host is
      # spared; else the host's cached model list; else the configured
      # window) and the
      # session's budget. Sent as a :context_status event (the web's ctx
      # meter, the attached TUI's status row) with context_window_tokens, and
      # kept for a client that joins later (#session_state_snapshot; the
      # window in the metrics' context too, which a page counts from). A window
      # that can't be resolved sends usage nil: the UIs clear the % until the
      # next generation. Nothing before the session's first counted turn.
      # +configured_only+: the configured window only, never asking a server
      # (EffectiveModel#configured_context_window): a loaded session's (#session=).
      # @return [Hash, nil] the event sent
      def announce_switched_context!(configured_only: false)
        used = @metrics.snapshot.dig(:context, :used_tokens)
        return nil unless used.is_a?(Integer)

        model = effective_model
        window = configured_only ? model.configured_context_window : current_context_window(model)
        display = window && saved_context_status({ used_tokens: used, window_tokens: window.tokens })
        @last_context_status = display&.dup
        @metrics.note_context_window(window.tokens, window.source) if window
        usage = display && { estimated_pct: display[:est_pct], estimated_used_tokens: used, window_tokens: window.tokens,
                             window_source: window.source.to_s, source: "switch" }
        event = { type: :context_status, usage: usage, bucket: display&.dig(:bucket),
                  context_window_tokens: window&.tokens, context_window_source: window&.source&.to_s }
        @session_observer.notify(event)
        event
      rescue StandardError => e
        Log.warn(:model, "switched_context_failed", error: e.class.name, msg: e.message.to_s[0, 200])
        nil
      end

      # Whether the last turn that named its model ran on another one than
      # the effective model; false before any (or when the ref can't be told).
      def model_switched_since_last_turn?
        last = @metrics.last_model_ref
        !last.nil? && last != effective_model_ref
      rescue StandardError => e
        Log.warn(:model, "switch_check_failed", error: e.class.name, msg: e.message.to_s[0, 200])
        false
      end
      private :model_switched_since_last_turn?

      private

      # Pick the loop for +model+ (EffectiveModel); the chat loop is pointed
      # at its host's adapter (one per host, kept for its cached model list)
      # and client (the window probe, the re-prefill's host).
      def backend_for(model)
        return @native_backend unless model.chat?

        @chat_backend_mutex.synchronize do
          @chat_backend ||= LLM::ChatLoop.new(kernel: @kernel, reprefill: @reprefill,
                                              stable_length: ->(text) { @prompt_builder.stable_length(text) })
          @chat_backend.adapter = @host_registry.adapter_for(model.entry)
          @chat_backend.client = model.client
          @chat_backend.session_id = session&.id
          @chat_backend
        end
      end

      # The window as +model+'s loop would see it (EffectiveModel#context_window).
      def current_context_window(model) = model.context_window

      # The effective model now, resolved on each call, never kept
      # (SessionModelSettings#effective_model). Raises as HostRegistry#resolve does.
      # @return [EffectiveModel]
      def effective_model(choice = @model_binding.choice) = @model_settings.effective_model(choice)

      # ── Prompt profile ─────────────────────────────────────────────────────────

      # The profile's resolve, keep, apply and retry are ModelBinding's
      # (#build_model_binding); these forward to it.
      def resolve_profile(choice) = @model_binding.resolve_profile(choice)
      def store_profile(choice, resolution) = @model_binding.store_profile(choice, resolution)
      def apply_profile(resolution) = @model_binding.apply_profile(resolution)
      def refresh_profile! = @model_binding.refresh_profile!
    end
  end
end
