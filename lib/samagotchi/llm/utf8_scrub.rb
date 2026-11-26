# frozen_string_literal: true

module Samagotchi
  module LLM
    # Conversation content (system prompt + tool responses + model output)
    # can contain invalid UTF-8, e.g. a shell/file op writes a garbled
    # multibyte sequence (a truncated em-dash, a stray replacement byte).
    # `JSON#to_json` raises `JSON::GeneratorError` on such input, which would
    # abort the whole turn, so a request body is scrubbed first: only
    # offending bytes are replaced with "?", every valid UTF-8 string passes
    # through untouched. A binary string is read as UTF-8 first (JSON raises
    # on its high bytes too); other encodings are left alone because
    # `#to_json` converts them without raising.
    module Utf8Scrub
      module_function

      # +obj+ with every String in it (Array elements, Hash keys and
      # values, at any depth) scrubbed; anything else as is.
      def call(obj)
        case obj
        when String
          text = obj.encoding == Encoding::BINARY ? obj.dup.force_encoding(Encoding::UTF_8) : obj
          text.encoding == Encoding::UTF_8 && !text.valid_encoding? ? text.scrub("?") : text
        when Array
          obj.map { |element| call(element) }
        when Hash
          obj.each_with_object({}) { |(key, value), memo| memo[call(key)] = call(value) }
        else
          obj
        end
      end

      # +messages+ (a conversation's entries) as a request builds on them:
      # each entry holding a String #call would change (BINARY with high
      # bytes, invalid UTF-8) replaced by its scrubbed copy, before any
      # UTF-8 regex reads it (Steer.wire_text's forged-frame quoting raises
      # on a BINARY string). The same Array when no entry needs it, and the
      # saved entries are never changed: same bytes in, same text out, so a
      # request's prefix (and its prompt cache) is what it was.
      # @param messages [Array<Hash>]
      # @return [Array<Hash>]
      def messages(messages)
        return messages unless messages.any? { |entry| raw?(entry) }

        messages.map { |entry| raw?(entry) ? call(entry) : entry }
      end

      # Whether #call would change a String in +obj+ (at any depth).
      def raw?(obj)
        case obj
        when String
          obj.encoding == Encoding::BINARY ? !obj.ascii_only? : obj.encoding == Encoding::UTF_8 && !obj.valid_encoding?
        when Array then obj.any? { |element| raw?(element) }
        when Hash then obj.any? { |key, value| raw?(key) || raw?(value) }
        else false
        end
      end
    end
  end
end
