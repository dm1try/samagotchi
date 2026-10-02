# frozen_string_literal: true

require_relative "model_profile"

module Samagotchi
  # Escapes literal control-token text when arbitrary source/output is embedded
  # inside prompts, then restores those placeholders when model text is used.
  module PromptLiteralGuard
    GEMMA_TOKEN_PAIRS = [
      ["[[SAMAGOTCHI_LITERAL_TURN_START]]", "<|turn>"],
      ["[[SAMAGOTCHI_LITERAL_TURN_END]]", "<end_of_turn>"],
      ["[[SAMAGOTCHI_LITERAL_TOOL_CALL_OPEN]]", "<|tool_call>"],
      ["[[SAMAGOTCHI_LITERAL_TOOL_CALL_CLOSE]]", "<tool_call|>"],
      ["[[SAMAGOTCHI_LITERAL_TOOL_RESPONSE_OPEN]]", "<|tool_response>"],
      ["[[SAMAGOTCHI_LITERAL_TOOL_RESPONSE_CLOSE]]", "<tool_response|>"],
      ["[[SAMAGOTCHI_LITERAL_GEMMA_STRING_DELIM]]", '<|"|>'],
      ["[[SAMAGOTCHI_LITERAL_THINK_OPEN]]", "<|think|>"],
      ["[[SAMAGOTCHI_LITERAL_THOUGHT_CHANNEL_OPEN]]", ModelProfile::GEMMA_THOUGHT_CHANNEL_OPEN],
      ["[[SAMAGOTCHI_LITERAL_THOUGHT_CHANNEL_CLOSE]]", ModelProfile::GEMMA_THOUGHT_CHANNEL_CLOSE]
    ].freeze

    QWEN_TOKEN_PAIRS = [
      ["[[SAMAGOTCHI_LITERAL_IM_START]]", "<|im_start|>"],
      ["[[SAMAGOTCHI_LITERAL_IM_END]]", "<|im_end|>"],
      ["[[SAMAGOTCHI_LITERAL_TOOL_CALL_OPEN]]", "<tool_call>"],
      ["[[SAMAGOTCHI_LITERAL_TOOL_CALL_CLOSE]]", "</tool_call>"],
      ["[[SAMAGOTCHI_LITERAL_TOOL_RESPONSE_OPEN]]", "<tool_response>"],
      ["[[SAMAGOTCHI_LITERAL_TOOL_RESPONSE_CLOSE]]", "</tool_response>"],
      ["[[SAMAGOTCHI_LITERAL_THINK_OPEN]]", "<think>"],
      ["[[SAMAGOTCHI_LITERAL_THINK_CLOSE]]", "</think>"],
      ["[[SAMAGOTCHI_LITERAL_VISION_START]]", "<|vision_start|>"],
      ["[[SAMAGOTCHI_LITERAL_VISION_END]]", "<|vision_end|>"]
    ].freeze

    def self.escape(text, profile:, role: nil)
      value = text.to_s
      return value if value.empty? || !escapable_role?(role)

      token_pairs_for(profile).reduce(value) do |memo, (placeholder, token)|
        memo.gsub(token, placeholder)
      end
    end

    def self.restore(text, profile:)
      value = text.to_s
      return value if value.empty?

      token_pairs_for(profile).reduce(value) do |memo, (placeholder, token)|
        memo.gsub(placeholder, token)
      end
    end

    def self.restore_call(call, profile:)
      call.each_with_object({}) do |(key, value), restored|
        restored[key] = value.is_a?(String) ? restore(value, profile: profile) : value
      end
    end

    def self.token_pairs_for(profile)
      case profile.name
      when "qwen36"
        QWEN_TOKEN_PAIRS
      else
        GEMMA_TOKEN_PAIRS
      end
    end

    def self.escapable_role?(role)
      %w[user tool_response].include?(role.to_s)
    end
  end
end
