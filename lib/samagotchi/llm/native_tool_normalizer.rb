# frozen_string_literal: true

require "json"
require_relative "../tools/builtin_calls"

module Samagotchi
  module LLM
    # Bridges a native tool call (an LLM::ToolCall from the chat adapter; any
    # object with #name and #arguments) into samagotchi's internal tool-call
    # shape: its arguments read as a Hash, then Tools::BuiltinCalls builds
    # the call, as it does for the Gemma and Qwen parsers.
    #
    # Unknown tool names pass through with their arguments on args:, so
    # `dispatch` renders its standard "unknown tool … available: …" error —
    # the loop feeds that back like any tool result.
    class NativeToolNormalizer
      class << self
        # Map a single native tool call (LLM::ToolCall) to the internal call hash.
        #
        # `call.arguments` is a parsed Hash (string keys). If it is nil or a bare
        # string we defensively coerce (string → JSON.parse when possible) so the
        # mapping never explodes on an odd wire shape.
        def normalize(call)
          return nil if call.nil?

          Tools::BuiltinCalls.build(call.name.to_s, args_for(call))
        end

        # Map an Array of tool calls to internal call hashes (nils dropped).
        def normalize_all(calls)
          Array(calls).map { |call| normalize(call) }.compact
        end

        private

        # args_for: arguments is normally a Hash. Defensively handle nil /
        # JSON-string / other shapes without raising.
        def args_for(call)
          raw = call.respond_to?(:arguments) ? call.arguments : nil
          case raw
          when Hash then raw
          when String
            raw.strip.empty? ? {} : safe_json_parse(raw)
          when nil
            {}
          else
            { "__raw__" => raw.to_s }
          end
        end

        def safe_json_parse(str)
          parsed = JSON.parse(str)
          parsed.is_a?(Hash) ? parsed : { "__raw__" => str }
        rescue JSON::ParserError
          { "__raw__" => str }
        end
      end
    end
  end
end
