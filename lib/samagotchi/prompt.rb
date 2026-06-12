# frozen_string_literal: true

require_relative "prompt_literal_guard"

module Samagotchi
  # Formats a message list into a prompt string ready for the /completion endpoint.
  #
  # Supports multiple model profiles (Gemma 4, Qwen 3.6, etc.) with different
  # token formats, role prefixing strategies, and tool response handling.
  #
  # Gemma 4:
  #   - Turn markers: <|turn>ROLE\n...<end_of_turn>\n
  #   - Tool response: standalone <|tool_response>...<tool_response|>
  #   - Generation cue: <|turn>model\n
  #
  # Qwen 3.6:
  #   - Role framing: <|im_start|>ROLE\n...<|im_end|>
  #   - Tool response: wrapped in user message with <tool_response>...</tool_response>
  #   - Generation cue: <|im_start|>assistant\n
  module Prompt
    # @param messages [Array<Hash>] each element has :role and :content.
    #   Recognised roles: "system", "user", "model", "tool_response".
    # @param profile [ModelProfile] model token configuration
    # @return [String] formatted prompt ready for the /completion endpoint.
    def self.format(messages, profile: ModelProfile.default)
      if profile.uses_role_prefixes?
        format_with_prefixes(messages, profile)
      else
        format_with_turn_markers(messages, profile)
      end
    end

    private

    def self.format_with_turn_markers(messages, profile)
      # Gemma 4 style: <|turn>ROLE\n...<end_of_turn>\n
      parts = messages.map do |m|
        content = prompt_content_for(m, profile)
        if m[:role] == "tool_response"
          "#{profile.tool_response_open}\n#{content}#{profile.tool_response_close}\n"
        else
          "#{profile.turn_start}#{m[:role]}\n#{content}#{profile.turn_end}\n"
        end
      end
      parts << "#{profile.turn_start}model\n"
      parts.join
    end

    def self.format_with_prefixes(messages, profile)
      # Qwen 3.6 style: <|im_start|>ROLE\n...<|im_end|>
      parts = []

      messages.each do |m|
        content = prompt_content_for(m, profile)
        case m[:role]
        when "system"
          parts << "#{profile.system_prefix}#{content}<|im_end|>\n"
        when "user"
          parts << "#{profile.user_prefix}#{content}<|im_end|>\n"
        when "model"
          parts << "#{profile.model_prefix}#{content}<|im_end|>\n"
        when "tool_response"
          # Wrap tool response in user message for Qwen
          parts << "#{profile.user_prefix}#{profile.tool_response_open}\n#{content}#{profile.tool_response_close}\n<|im_end|>\n"
        end
      end

      # Cue generation as assistant
      parts << profile.assistant_prefix
      parts.join
    end

    def self.prompt_content_for(message, profile)
      return message[:content].to_s if message[:preserve_literals]

      PromptLiteralGuard.escape(message[:content], profile: profile, role: message[:role])
    end
  end
end
