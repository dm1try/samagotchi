# frozen_string_literal: true

require_relative "../thinking"

module Samagotchi
  module LLM
    # A turn's settings on the kernel, read by both loops (KernelLoop,
    # ChatLoop) and ToolRunner: the turn's VisionContext (nil sends no
    # images, placeholders instead), its request parameters
    # (SamplingSettings.for; empty sends none), its thinking level
    # (Thinking.resolve), the bare model id the turn runs on (every debug
    # dump is tagged with it) and the model's or host's configured context
    # window (ContextWindow.setting, nil for none) and LLM context strategy
    # (LLMContextStrategy.resolve, nil for none), and its price on its host
    # (hosts.<name>.models.<id>.price, a ModelPrice; nil for none), what
    # SessionMetrics estimates an unreported cost from. The Engine sets them once
    # per turn, in Engine#generate, after the model's host is synced.
    TurnSettings = Data.define(:vision, :sampling, :thinking, :model_name, :window_setting, :llm_context, :price) do
      # No vision, no sampling, the default thinking, no model name.
      def self.none = new(vision: nil, sampling: {}.freeze, thinking: Thinking::DEFAULT, model_name: nil,
                          window_setting: nil, llm_context: nil, price: nil)
    end
  end
end
