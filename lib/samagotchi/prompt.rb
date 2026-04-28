# frozen_string_literal: true

module Samagotchi
  # Formats a message list into a Gemma 4 prompt string.
  #
  # Gemma 4 control tokens:
  #   <|turn|>   — beginning of a dialogue turn
  #   <end_of_turn> — end of a dialogue turn
  #   roles: system | user | model
  #
  # The formatted prompt always ends with <|turn|>model\n to cue generation.
  module Prompt
    TURN_START = "<|turn|>"
    TURN_END   = "<end_of_turn>"

    # @param messages [Array<Hash>] each element has :role ("system"|"user"|"model")
    #   and :content (String).
    # @return [String] formatted prompt ready for the /completion endpoint.
    def self.format(messages)
      parts = messages.map { |m| "#{TURN_START}#{m[:role]}\n#{m[:content]}#{TURN_END}\n" }
      parts << "#{TURN_START}model\n"
      parts.join
    end
  end
end
