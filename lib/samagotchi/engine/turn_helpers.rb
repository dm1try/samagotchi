# frozen_string_literal: true

module Samagotchi
  class Engine
    # What a turn's steps use before and around the model: its settings,
    # images and vision, the model ref and resumed run start it generates
    # with, the used memories it publishes, and the turn-end warm-up of the
    # next one. Writes @next_turn_waiting; reads @model_settings, @kernel,
    # @prompt_warmup, @thinking_notices, @turn_state and the turn's TurnContext.
    module TurnHelpersPart
      # The turn's settings for the kernel (LLM::TurnSettings): vision,
      # sampling and thinking, the thinking resolved before the hooks run.
      # The model name is added in #generate, after the hooks that may switch
      # the model.
      # One resolve for all of them: nothing runs between them that could
      # change what a resolve gives.
      def turn_settings(session)
        model = effective_model
        vision = turn_vision(session, model)
        sampling = model.sampling
        level = @model_settings.thinking_level(model)
        @thinking_notices.turn_started(level, model.target)
        LLM::TurnSettings.new(vision: vision, sampling: sampling, thinking: level,
                              reasoning_history: @model_settings.reasoning_history_level(model), model_name: nil,
                              window_setting: nil, llm_context: nil, price: nil)
      end
      private :turn_settings

      # @return [PromptWarmup] the turn-end warm-up (specs, measurements)
      attr_reader :prompt_warmup

      # A caller's check that the next turn starts at once (input queued for
      # it: a worker's inbox) or that none follows (a one-shot run): no
      # warm-up then. nil: neither.
      attr_accessor :next_turn_waiting

      # After a completed turn, prefill the next turn's prompt up to its user
      # message while the user reads (PromptWarmup, cache.warmup). Only on a
      # local llama.cpp host on the native loop, and not when the next turn's
      # start differs anyway or starts at once: a reminder due, a continue
      # offer (the turn ran out of steps), a carried steer or queued input.
      # Never fails the turn.
      def warm_up_next_turn(turn, result)
        return if result.canceled? || result.resumable?

        model = effective_model
        client = model.client
        return unless warmup_target?(model, client)
        return if reminders_due? || @turn_state.carried_steers? || @next_turn_waiting&.call

        messages = ContextNote.with_system_head(turn.session.messages.dup, { role: "system", content: system_prompt(model) })
        # Under the next turn's strategy (a /model switch may have changed it);
        # the last turn's when it can't be resolved; the turn's settings
        # (TurnContext, set in #generate) for the rest.
        settings = turn.context.settings
        prompt, images = @kernel.warmup_prompt(messages, llm_context: @model_settings.turn_llm_context || settings.llm_context,
                                                         vision: settings.vision)
        return unless prompt

        started = @prompt_warmup.start(client: client, prompt: prompt, model: settings.model_name,
                                       slot: @kernel.last_slot, images: images)
        @kernel.warmed_up! if started
      rescue StandardError => e
        Log.warn(:model, "warmup_skipped", error: e.class.name, msg: e.message.to_s[0, 200])
      end
      private :warm_up_next_turn

      # Never a paid or remote host (cache.warmup auto means local only), nor
      # the chat loop (Splash keeps its own cache; llama.cpp's chat path is
      # not measured), nor a client that can't warm up (a spec's stub).
      def warmup_target?(model, client)
        return false if model.chat? || model.entry.remote?
        return false unless client.respond_to?(:warm_up)

        PromptWarmup.enabled?
      end
      private :warmup_target?

      # The ref (host:model, as asked) a turn's generations ran on: the model
      # #generate resolved, after the before_turn hooks (which may switch it).
      # SessionMetrics keys its per-model segments on it. nil when it can't be
      # named (the turn's record then has none).
      def generation_model_ref(model)
        model.ref
      rescue StandardError => e
        Log.warn(:turn, "model_ref_failed", error: e.class.name, msg: e.message.to_s[0, 200])
        nil
      end
      private :generation_model_ref

      # A step-limit Continue's resume_from, when it is inside the messages the
      # run gets (a wrong one only drops reasoning: it is ignored, logged).
      # Entries before it never move between the turns (#turn_messages adds
      # at the tail, and the system head is replaced in place).
      def resumed_run_start(turn, run_start)
        start = turn.resume_from
        return nil if start.nil?
        return start if start.is_a?(Integer) && start.between?(0, run_start)

        Log.warn(:turn, "resume_start_invalid", resume_from: start, length: run_start)
        nil
      end
      private :resumed_run_start

      # The turn's LLM context strategy and where it came from, in the turn
      # log: when it runs a layer, or the session set it (none too).
      def log_llm_context(explained)
        return unless explained
        return if explained.resolved.active_layers.empty? && explained.strategy.source != :session

        summary = explained.summary
        Log.info(:turn, "llm_context", **summary.slice(:strategy, :strategy_source, :apply, :apply_source, :budget_tokens,
                                                       :budget_source).compact)
      end
      private :log_llm_context

      def publish_used_memories(session, on_event)
        # Persist deduped used memories onto the session for Web + reload.
        begin
          session.used_memory_names = used_memory_names
        rescue StandardError => e
          Log.warn(:memory, "used_memories_store_failed", error: e.class.name, msg: e.message.to_s[0, 200])
        end
        # Notify live observers of the updated memory list (so yellow bar refreshes
        # even without a tool_call event if the preload was the only addition).
        # Only emit when there is something to report to avoid noisy event_count drift.
        return unless used_memory_names.any?

        begin
          emit_event(on_event, { type: :used_memories_updated, used_memory_names: used_memory_names })
        rescue StandardError => e
          Log.warn(:memory, "used_memories_emit_failed", error: e.class.name, msg: e.message.to_s[0, 200])
        end
      end
      private :publish_used_memories

      # [refs, nil] for a turn's images, or [[], error] when one can't be used
      # (the turn then fails right after :turn_started).
      def turn_image_refs(session, images)
        return [[], nil] if Array(images).empty?

        [ImageStore.resolve_all(Session.session_dir(session.id, state_dir: session_state_dir), images), nil]
      rescue ImageStore::Error => e
        [[], e]
      end

      # The turn's VisionContext: the session's images folder, and whether the
      # effective model can see images, asked only when a request carries one.
      def turn_vision(session, model = effective_model)
        VisionContext.new(session_dir: Session.session_dir(session.id, state_dir: session_state_dir),
                          capability: -> { model.vision_support(profile) })
      end

      # A model known not to see images fails a turn with images up front.
      def refuse_images!(vision)
        return if vision.sendable?

        host = effective_model.host_name
        raise LLM::VisionUnsupported.new("#{host}: #{vision.refusal_reason}", host: host)
      end
    end
  end
end
