# frozen_string_literal: true

require_relative "openai_chat"
require_relative "usage"

module Samagotchi
  module LLM
    # A Messages response put together as ChatResponse, from a whole body
    # (.from_message) or a stream's events (#add, by content-block index):
    # the content blocks
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
        # A streamed block by its index, and a tool_use's input JSON so far.
        @by_index = {}
        @json = {}
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

      # One streamed event: message_start (served model, usage),
      # content_block_start (text / thinking / redacted_thinking / tool_use),
      # content_block_delta (text_delta, thinking_delta, signature_delta,
      # input_json_delta), content_block_stop, message_delta (stop reason,
      # usage); ping, message_stop and anything else change nothing.
      # @return [Array(String, String)] the event's text and reasoning
      def add(event)
        case event["type"]
        when "message_start" then start_message(event["message"])
        when "content_block_start" then start_block(event["index"], event["content_block"])
        when "content_block_delta" then add_delta(@by_index[event["index"]], event["index"], event["delta"])
        when "message_delta"
          @stop_reason = event.dig("delta", "stop_reason") || @stop_reason if event["delta"].is_a?(Hash)
          merge_usage(event["usage"])
          ["", ""]
        else ["", ""]
        end
      end

      # Whether a streamed +event+ shows something (a block started, a delta):
      # what the first-token limit waits for.
      def self.shows?(event) = %w[content_block_start content_block_delta].include?(event["type"])

      # Whether a streamed +event+ carries part of a tool call.
      def self.tool_call_delta?(event)
        case event["type"]
        when "content_block_start" then event.dig("content_block", "type") == "tool_use"
        when "content_block_delta" then event.dig("delta", "type") == "input_json_delta"
        else false
        end
      end

      # +event+ as on_delta passes it on: one that carries usage gets the
      # usage so far in the OpenAI shape as its `usage` (SessionMetrics,
      # ContextStatus and ctx.js read that).
      def with_usage(event)
        return event unless %w[message_start message_delta].include?(event["type"]) && (payload = usage_payload)

        event.merge("usage" => payload)
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

      def start_message(message)
        return ["", ""] unless message.is_a?(Hash)

        @model = served(message["model"]) || @model
        merge_usage(message["usage"])
        ["", ""]
      end

      def start_block(index, block)
        return ["", ""] unless block.is_a?(Hash)

        block = block.dup
        @blocks << block
        @by_index[index] = block
        case block["type"]
        when TEXT then [block["text"].to_s, ""]
        when THINKING then ["", block["thinking"].to_s]
        else ["", ""]
        end
      end

      def add_delta(block, index, delta)
        return ["", ""] unless block && delta.is_a?(Hash)

        case delta["type"]
        when "text_delta"
          block["text"] = block["text"].to_s + delta["text"].to_s
          [delta["text"].to_s, ""]
        when "thinking_delta"
          block["thinking"] = block["thinking"].to_s + delta["thinking"].to_s
          ["", delta["thinking"].to_s]
        when "signature_delta"
          block["signature"] = block["signature"].to_s + delta["signature"].to_s
          ["", ""]
        when "input_json_delta"
          (@json[index] ||= +"") << delta["partial_json"].to_s
          block["input"] = @json[index]
          ["", ""]
        else ["", ""]
        end
      end

      def merge_usage(usage)
        return unless usage.is_a?(Hash)

        USAGE_KEYS.each { |key| @usage[key] = usage[key] if usage[key].is_a?(Integer) }
      end

      # The blocks to keep and send back: an empty or blank text block is
      # no text (Splash opens one after a thinking cut by max_tokens, and
      # Messages refuses one sent back), a tool_use's input is an object,
      # and a thinking block has a signature, "" when it came without one
      # (a sent-back thinking block needs the key; Splash sends "", a
      # provider may send none).
      def content
        @blocks.filter_map do |block|
          type = block["type"].to_s
          next if type == TEXT && block["text"].to_s.strip.empty?
          next block.merge("signature" => "") if type == THINKING && !block.key?("signature")
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
