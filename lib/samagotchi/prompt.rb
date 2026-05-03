# frozen_string_literal: true

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
        if m[:role] == "tool_response"
          "#{profile.tool_response_open}\n#{m[:content]}#{profile.tool_response_close}\n"
        else
          "#{profile.turn_start}#{m[:role]}\n#{m[:content]}#{profile.turn_end}\n"
        end
      end
      parts << "#{profile.turn_start}model\n"
      parts.join
    end

    def self.format_with_prefixes(messages, profile)
      # Qwen 3.6 style: <|im_start|>ROLE\n...<|im_end|>
      parts = []
      
      messages.each do |m|
        case m[:role]
        when "system"
          parts << "#{profile.system_prefix}#{m[:content]}<|im_end|>\n"
        when "user"
          parts << "#{profile.user_prefix}#{m[:content]}<|im_end|>\n"
        when "model"
          parts << "#{profile.model_prefix}#{m[:content]}<|im_end|>\n"
        when "tool_response"
          # Wrap tool response in user message for Qwen
          parts << "#{profile.user_prefix}#{profile.tool_response_open}\n#{m[:content]}#{profile.tool_response_close}\n<|im_end|>\n"
        end
      end
      
      # Cue generation as assistant
      parts << profile.assistant_prefix
      parts.join
    end
  end
end
