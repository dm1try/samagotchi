# frozen_string_literal: true

require_relative "../config"
require_relative "../log"

module Samagotchi
  module LLM
    # Prompt-cache breakpoints for Claude models behind an OpenAI-compatible
    # host (OpenRouter, a gateway). Anthropic caches a prompt only up to a
    # content part marked with cache_control, in the order tools → system →
    # messages, so two marks cover a chat request:
    # - the first system message (with it, the tool list), and
    # - the last non-system message with content, so the next request (the
    #   same prefix plus new messages) reads everything up to it.
    # Mid and tail system messages (reminders, turn notes) never take the
    # second mark. Other models' messages pass through untouched.
    #
    # A system message whose `cache_split:` says where its stable part ends
    # (ChatLoop, from SystemPrompt#stable_length) goes as two text parts:
    # the stable part with the mark, the per-session tail (model, location,
    # session) without, so a new session reads the stable part from the
    # cache. `cache_split:` never goes on the wire (#without_split).
    #
    # cache.ttl: 1h marks the breakpoints with `ttl: "1h"` (#control), so a
    # cache outlives a long reading gap; 5m, the default, sends Anthropic's
    # default (no ttl).
    module PromptCache
      CONTROL = { type: "ephemeral" }.freeze
      CONTROL_1H = { type: "ephemeral", ttl: "1h" }.freeze
      TTLS = %w[5m 1h].freeze

      module_function

      # The cache_control a breakpoint carries under cache.ttl (an unknown
      # value warns once and is 5m).
      def control
        value = Config.get("cache.ttl").to_s.strip.downcase
        return CONTROL_1H if value == "1h"

        unless value.empty? || value == "5m" || @warned_ttl
          @warned_ttl = true
          Log.warn(:config, "invalid_value", echo: "Warning: invalid value for cache.ttl: #{value.inspect} (allowed: 5m, 1h) — using 5m",
                                             key: "cache.ttl")
        end
        CONTROL
      rescue StandardError
        CONTROL
      end

      # Whether +model+ (the bare id a host is asked for) names a Claude model.
      def claude?(model) = model.to_s.match?(/claude/i)

      # +messages+ (wire messages: symbol keys, content a String or an Array
      # of parts) with the breakpoints set when +model+ is a Claude model;
      # the given messages as they are otherwise (#without_split). The marked
      # messages and parts are copies: the caller's are never changed.
      # @return [Array<Hash>]
      def mark(messages, model:)
        return without_split(messages) unless claude?(model)

        indexes = [system_index(messages), last_index(messages)].compact.uniq
        breakpoint = control
        messages.each_with_index.map do |message, index|
          next marked(message.except(:cache_split), breakpoint, split: message[:cache_split]) if indexes.include?(index)

          message.key?(:cache_split) ? message.except(:cache_split) : message
        end
      end

      # +messages+ without the `cache_split:` hints, for a request that sets
      # no breakpoints.
      # @return [Array<Hash>]
      def without_split(messages)
        return messages unless messages.any? { |message| message.key?(:cache_split) }

        messages.map { |message| message.except(:cache_split) }
      end

      # Whether any message in +messages+ carries a breakpoint.
      def marked?(messages)
        Array(messages).any? do |message|
          content = message[:content]
          content.is_a?(Array) && content.any? { |part| part.is_a?(Hash) && control?(part) }
        end
      end

      def system_index(messages)
        index = messages.index { |message| message[:role].to_s == "system" }
        index if index && content?(messages[index][:content])
      end

      # The last message that isn't a system message and has content (an
      # assistant tool_calls message has nil or "").
      def last_index(messages)
        messages.rindex { |message| message[:role].to_s != "system" && content?(message[:content]) }
      end

      def content?(content)
        case content
        when String then !content.empty?
        when Array then content.any?(Hash)
        else false
        end
      end

      # A String becomes one text part (two at +split+, the mark on the
      # first); an Array gets the mark on its last text part (the last part
      # when none is text).
      def marked(message, breakpoint, split: nil)
        content = message[:content]
        if content.is_a?(String)
          if split.is_a?(Integer) && split.positive? && split < content.length
            return message.merge(content: [{ type: "text", text: content[0, split], cache_control: breakpoint },
                                           { type: "text", text: content[split..] }])
          end

          return message.merge(content: [{ type: "text", text: content, cache_control: breakpoint }])
        end

        target = content.rindex { |part| part.is_a?(Hash) && (part[:type] || part["type"]).to_s == "text" } ||
                 content.rindex { |part| part.is_a?(Hash) }
        part = content[target]
        key = part.key?("type") ? "cache_control" : :cache_control
        parts = content.dup
        parts[target] = part.merge(key => breakpoint)
        message.merge(content: parts)
      end

      def control?(part) = part.key?(:cache_control) || part.key?("cache_control")

      private_class_method :system_index, :last_index, :content?, :marked, :control?
    end
  end
end
