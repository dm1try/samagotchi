# frozen_string_literal: true

module Samagotchi
  # Formats a message list into a Gemma 4 prompt string.
  #
  # Gemma 4 control tokens:
  #   <|turn>             — beginning of a dialogue turn
  #   <end_of_turn>       — end of a dialogue turn
  #   roles: system | user | model
  #
  # Agentic token pairs (per Gemma 4 documentation):
  #   <|tool> / <tool|>               — defines a tool (used in system prompt)
  #   <|tool_call> / <tool_call|>     — model's request to invoke a tool
  #   <|tool_response> / <tool_response|> — harness-injected tool execution result
  #
  # Tool-response messages use role "tool_response" and are emitted as a
  # standalone <|tool_response>…<tool_response|> block between model turns,
  # NOT as a regular <|turn>…<end_of_turn> block.
  #
  # The formatted prompt always ends with <|turn>model\n to cue generation.
  module Prompt
    TURN_START = "<|turn>"
    TURN_END   = "<end_of_turn>"

    TOOL_RESPONSE_OPEN  = "<|tool_response>"
    TOOL_RESPONSE_CLOSE = "<tool_response|>"

    # @param messages [Array<Hash>] each element has :role and :content.
    #   Recognised roles: "system", "user", "model", "tool_response".
    # @return [String] formatted prompt ready for the /completion endpoint.
    def self.format(messages)
      parts = messages.map do |m|
        if m[:role] == "tool_response"
          "#{TOOL_RESPONSE_OPEN}\n#{m[:content]}#{TOOL_RESPONSE_CLOSE}\n"
        else
          "#{TURN_START}#{m[:role]}\n#{m[:content]}#{TURN_END}\n"
        end
      end
      parts << "#{TURN_START}model\n"
      parts.join
    end
  end
end
