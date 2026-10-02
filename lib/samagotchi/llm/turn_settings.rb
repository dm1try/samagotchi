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
    # window (ContextWindow.setting, nil for none). The Engine sets them
    # once per turn, in Engine#generate, after the model's host is synced.
    TurnSettings = Data.define(:vision, :sampling, :thinking, :model_name, :window_setting) do
      # No vision, no sampling, the default thinking, no model name.
      def self.none = new(vision: nil, sampling: {}.freeze, thinking: Thinking::DEFAULT, model_name: nil,
                          window_setting: nil)
    end
  end
end
