# frozen_string_literal: true

require_relative "../image_store"
require_relative "../llm/errors"
require_relative "../llm/turn_settings"
require_relative "../log"
require_relative "../session"
require_relative "../turn_stages/warmup"
require_relative "../vision_context"

module Samagotchi
  class Engine
    # What a turn's steps use before and around the model: its settings,
    # images and vision, the model ref and resumed run start it generates
    # with, the used memories it publishes, and the turn-end warm-up of the
    # next one (TurnStages::Warmup, built here). Writes @next_turn_waiting;
    # reads @model_settings, @kernel, @prompt_warmup, @thinking_notices,
    # @turn_state, @reminder_queue, @turn_warmup.
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

      # The turn-end warm-up's stage (TurnStages::Warmup).
      attr_reader :turn_warmup
      private :turn_warmup

      # The stage over the kernel and the Engine's PromptWarmup (built in
      # #initialize, once the kernel and the reminder queue are). Its one
      # callable is the system prompt, built late (side effects); the
      # host's probe goes with each call (#next_turn_waiting, set after).
      def build_turn_warmup
        TurnStages::Warmup.new(prompt_warmup: @prompt_warmup, kernel: @kernel, turn_state: @turn_state,
                               model_settings: @model_settings, reminder_queue: @reminder_queue,
                               system_prompt: ->(model) { system_prompt(model) })
      end
      private :build_turn_warmup

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
