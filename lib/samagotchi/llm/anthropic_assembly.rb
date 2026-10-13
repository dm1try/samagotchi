# frozen_string_literal: true

require_relative "openai_chat"
require_relative "usage"

module Samagotchi
  module LLM
    # A Messages response put together as ChatResponse: the content blocks
    # in order (kept as received, string keys: ChatResponse#provider_content,
    # which ChatLoop saves and sends back), the text and reasoning they
    # carry, the tool calls, the usage and the stop reason in the chat
    # loop's terms.
    #
    # Usage: Messages counts input_tokens without the cache, so the prompt
    # is input + cache reads + cache writes, in the OpenAI shape the rest of
    # chi reads (TokenUsage: prompt_tokens_details.cached_tokens /
    # cache_write_tokens). Every field is optional (Splash sends no cache
    # writes), and a later value wins per field.
    class AnthropicAssembly
      # stop_reason → ChatResponse#finish_reason (the chat loop's words);
      # pause_turn and anything else pass as they are.
      FINISH_REASONS = {
        "end_turn" => "stop", "stop_sequence" => "stop", "max_tokens" => "length",
        "model_context_window_exceeded" => "length", "tool_use" => "tool_calls", "refusal" => "refusal"
      }.freeze
      USAGE_KEYS = %w[input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens].freeze
      # Blocks whose text is the answer or the reasoning.
      THINKING = "thinking"
      TEXT = "text"

      def self.finish_reason(stop_reason) = stop_reason && FINISH_REASONS.fetch(stop_reason.to_s, stop_reason.to_s)

      # A non-streamed body (a `message` object).
      def self.from_message(body) = new.tap { |assembly| assembly.add_message(body) }

      def initialize
        @blocks = []
        @usage = {}
        @stop_reason = nil
        @model = nil
      end

      # A whole message: its model, usage, stop reason and blocks.
      def add_message(message)
        return unless message.is_a?(Hash)

        @model = served(message["model"]) || @model
        merge_usage(message["usage"])
        @stop_reason = message["stop_reason"] if message["stop_reason"]
        Array(message["content"]).each { |block| @blocks << block.dup if block.is_a?(Hash) }
      end

      # The usage so far as an OpenAI-shaped `usage` object, nil when the
      # server sent no counts.
      def usage_payload
        return nil if @usage.empty?

        read = @usage["cache_read_input_tokens"].to_i
        write = @usage["cache_creation_input_tokens"].to_i
        { "prompt_tokens" => @usage["input_tokens"].to_i + read + write, "completion_tokens" => @usage["output_tokens"].to_i,
          "prompt_tokens_details" => { "cached_tokens" => read, "cache_write_tokens" => write } }
      end

      def response
        blocks = content
        ChatResponse.new(text: joined(blocks, TEXT, "text"), reasoning: joined(blocks, THINKING, "thinking"),
                         tool_calls: tool_calls, usage: usage, finish_reason: self.class.finish_reason(@stop_reason),
                         model: @model, provider_content: blocks)
      end

      private

      def usage
        payload = usage_payload
        (payload && Usage.from_payload({ "usage" => payload })) || Usage.none
      end

      def merge_usage(usage)
        return unless usage.is_a?(Hash)

        USAGE_KEYS.each { |key| @usage[key] = usage[key] if usage[key].is_a?(Integer) }
      end

      # The blocks to keep and send back: an empty or blank text block is
      # no text (Splash opens one after a thinking cut by max_tokens, and
      # Messages refuses one sent back), and a tool_use's input is an object.
      def content
        @blocks.filter_map do |block|
          type = block["type"].to_s
          next if type == TEXT && block["text"].to_s.strip.empty?
          next block unless type == "tool_use"

          input = OpenAIChat.parse_arguments(block["input"])
          block.merge("input" => input.is_a?(Hash) ? input : {})
        end
      end

      def joined(blocks, type, key)
        blocks.select { |block| block["type"] == type }.map { |block| block[key].to_s }.join
      end

      # The calls with their arguments as OpenAIChat.parse_arguments reads
      # them: invalid JSON stays a String, so the tool reports it.
      def tool_calls
        @blocks.select { |block| block["type"] == "tool_use" }.map do |block|
          ToolCall.new(id: block["id"], name: block["name"].to_s, arguments: OpenAIChat.parse_arguments(block["input"]))
        end
      end

      def served(model) = model.is_a?(String) && !model.strip.empty? ? model : nil
    end
  end
end
