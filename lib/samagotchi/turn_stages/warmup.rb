# frozen_string_literal: true

require_relative "../context_note"
require_relative "../log"
require_relative "../model_profile"
require_relative "../prompt_warmup"

module Samagotchi
  module TurnStages
    # The turn-end warm-up (PromptWarmup, cache.warmup): after a completed
    # turn, the next turn's prompt prefilled up to its user message while
    # the user reads. Called after Engine#complete_turn, so the context
    # judge's asks started in the turn run first: on a shared local host the
    # warm-up queues behind them. No state of its own: the PromptWarmup
    # keeps its pin and thread.
    class Warmup
      # @param prompt_warmup [PromptWarmup] the Engine's warm-up (the kernel asks it for a slot pin)
      # @param kernel [KernelLoop] the warm-up prompt, the last slot, warmed_up!
      # @param turn_state [TurnState] whether steers are carried to the next turn
      # @param model_settings [SessionModelSettings] the next turn's LLM context strategy
      # @param model [#call] the effective model now (Engine#effective_model)
      # @param system_prompt [#call] (model) the system prompt (Engine#system_prompt)
      # @param reminders_due [#call] whether a reminder is due (Engine#reminders_due?)
      # @param next_turn_waiting [#call] whether the next turn starts at once or none follows
      #   (Engine#next_turn_waiting, called)
      def initialize(prompt_warmup:, kernel:, turn_state:, model_settings:, model:, system_prompt:, reminders_due:,
                     next_turn_waiting:)
        @prompt_warmup = prompt_warmup
        @kernel = kernel
        @turn_state = turn_state
        @model_settings = model_settings
        @model = model
        @system_prompt = system_prompt
        @reminders_due = reminders_due
        @next_turn_waiting = next_turn_waiting
      end

      # After a completed turn, prefill the next turn's prompt up to its user
      # message while the user reads (PromptWarmup, cache.warmup). Only on a
      # local llama.cpp host on the native loop, and not when the next turn's
      # start differs anyway or starts at once: a reminder due, a continue
      # offer (the turn ran out of steps), a carried steer or queued input.
      # Never fails the turn.
      def after(turn, result)
        return if result.canceled? || result.resumable?

        model = @model.call
        client = model.client
        return unless target?(model, client)
        return if @reminders_due.call || @turn_state.carried_steers? || @next_turn_waiting.call

        messages = ContextNote.with_system_head(turn.session.messages.dup, { role: "system", content: @system_prompt.call(model) })
        # Under the next turn's strategy (a /model switch may have changed it);
        # the last turn's when it can't be resolved; the turn's settings
        # (TurnContext, set in Engine#generate) for the rest.
        settings = turn.context.settings
        prompt, images = @kernel.warmup_prompt(messages, llm_context: @model_settings.turn_llm_context || settings.llm_context,
                                                         vision: settings.vision)
        return unless prompt

        # The model name as the native run sent it (KernelLoop#run's
        # completion name: the default model for a blank one).
        started = @prompt_warmup.start(client: client, prompt: prompt, model: ModelProfile.required_model_name(settings.model_name),
                                       slot: @kernel.last_slot, images: images)
        @kernel.warmed_up! if started
      rescue StandardError => e
        Log.warn(:model, "warmup_skipped", error: e.class.name, msg: e.message.to_s[0, 200])
      end

      private

      # Never a paid or remote host (cache.warmup auto means local only), nor
      # the chat loop (Splash keeps its own cache; llama.cpp's chat path is
      # not measured), nor a client that can't warm up (a spec's stub).
      def target?(model, client)
        return false if model.chat? || model.entry.remote?
        return false unless client.respond_to?(:warm_up)

        PromptWarmup.enabled?
      end
    end
  end
end
