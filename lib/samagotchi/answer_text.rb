# frozen_string_literal: true

require_relative "model_profile"
require_relative "output_formatter"
require_relative "tool_call_parser"

module Samagotchi
  # What the user saw of a model entry's text: the one rule for the continue
  # note's last answer (SessionChain.last_answer), a check's record of the
  # agent's own words (ObjectivesCheck) and a bundle's ctx.last_answer. A chat
  # entry's content is that already (its reasoning is the separate :thinking,
  # its calls :tool_calls); a native entry's is the raw response, with its
  # thoughts and call markup inline: both hosts' thoughts come out, a thought
  # cut off before it closed too, then the calls and the wire tokens.
  module AnswerText
    QWEN_THINK = %r{<think>.*?</think>}m
    # The template opened the block, so the text starts inside it.
    TEMPLATE_OPENED_THINK = %r{\A.*?</think>}m

    module_function

    # @param text [String, nil]
    # @return [String] "" when nothing was visible
    def visible(text)
      text = text.to_s.scrub
      template_opened = !text.include?("<think>")
      gemma = ToolCallParser::Gemma.new(ModelProfile.gemma4)
      text = gemma.strip_thought(text).gsub(QWEN_THINK, "")
      text = text.sub(TEMPLATE_OPENED_THINK, "") if template_opened
      text = ToolCallParser.strip_calls(gemma.strip_tool_calls(text), "<tool_call>", "</tool_call>")
      OutputFormatter.strip_markup(text) # drops a thought cut off before it closed
    end
  end
end
