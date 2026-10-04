# frozen_string_literal: true

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
    module PromptCache
      CONTROL = { type: "ephemeral" }.freeze

      module_function

      # Whether +model+ (the bare id a host is asked for) names a Claude model.
      def claude?(model) = model.to_s.match?(/claude/i)

      # +messages+ (wire messages: symbol keys, content a String or an Array
      # of parts) with the breakpoints set when +model+ is a Claude model;
      # the given messages as they are otherwise. The marked messages and
      # parts are copies: the caller's are never changed.
      # @return [Array<Hash>]
      def mark(messages, model:)
        return messages unless claude?(model)

        indexes = [system_index(messages), last_index(messages)].compact.uniq
        return messages if indexes.empty?

        messages.each_with_index.map { |message, index| indexes.include?(index) ? marked(message) : message }
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

      # A String becomes one text part; an Array gets the mark on its last
      # text part (the last part when none is text).
      def marked(message)
        content = message[:content]
        return message.merge(content: [{ type: "text", text: content, cache_control: CONTROL }]) if content.is_a?(String)

        target = content.rindex { |part| part.is_a?(Hash) && (part[:type] || part["type"]).to_s == "text" } ||
                 content.rindex { |part| part.is_a?(Hash) }
        part = content[target]
        key = part.key?("type") ? "cache_control" : :cache_control
        parts = content.dup
        parts[target] = part.merge(key => CONTROL)
        message.merge(content: parts)
      end

      def control?(part) = part.key?(:cache_control) || part.key?("cache_control")

      private_class_method :system_index, :last_index, :content?, :marked, :control?
    end
  end
end
