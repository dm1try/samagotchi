# frozen_string_literal: true

require "json"

module Samagotchi
  module Tools
    # Structured user qualification tool.
    #
    # The model invokes this via tool_call when it needs a structured choice from the user
    # instead of a free-form numbered list in plain text. The harness intercepts the call,
    # renders a UI-agnostic question (TUI prompt / WEB buttons / future UIs via the same
    # Engine event), blocks until the user answers, and returns the normalized selection
    # as the tool_response. No direct terminal/web coupling lives here — callers provide
    # the blocking handler via Engine (or fallback to a plain error).
    #
    # Single tool covers single + multi + freeform via flags: multi_select, allow_freeform.
    class AskUserQuestion
      NAME        = "ask_user_question"

      def self.name        = NAME

      # The tool result for a wrong number of options (the kernel's, and the
      # Engine's for more than 8).
      def self.options_count_error(count)
        "Error: ask_user_question requires 2-8 options (got #{count}). Provide e.g. options=[\"Cats\",\"Dogs\"]"
      end

      # Normalize options param: accept Array or JSON string; strip, reject empty.
      # Dumb-model tolerant: handles JSON arrays, quoted CSV, bracket noise, single strings.
      def self.normalize_options(raw)
        arr = extract_options_array(raw)
        return nil unless arr

        cleaned = arr.map { |v| sanitize_option(v) }.reject { |v| v.nil? || v.empty? }
        # Strict: 2-8, but lenient wrapper allows 1 for dumb-model salvage — keeps strict nil here
        return nil unless cleaned.size.between?(2, 8)

        cleaned
      end

      def self.extract_options_array(raw)
        case raw
        when Array
          raw.dup
        when String
          s = raw.to_s.strip
          return nil if s.empty?

          # 1) Try JSON parse (most common: '["a","b"]')
          begin
            parsed = JSON.parse(s)
            return parsed.dup if parsed.is_a?(Array)
            # If parsed is a String like "a, b", fall through to split
            if parsed.is_a?(String)
              s = parsed
            end
          rescue JSON::ParserError
            nil
          end

          # 2) If it looks like a JSON array but JSON parse failed due to single quotes or trailing commas, extract quoted strings
          if s.strip.start_with?("[") && s.strip.end_with?("]")
            quoted = s.scan(/"((?:[^"\\]|\\.)*)"/).flatten
            unless quoted.empty?
              # Unescape and strip
              unescaped = quoted.map { |v| v.gsub('\\"', '"').gsub("\\\\", "\\").strip }
              # Filter out pure bracket noise
              filtered = unescaped.reject { |v| v.empty? || v.match?(/\A[\[\],\s]+\z/) }
              return filtered unless filtered.empty?
            end
            # Also try single-quote variant
            quoted2 = s.scan(/'((?:[^'\\]|\\.)*)'/).flatten
            unless quoted2.empty?
              unescaped2 = quoted2.map { |v| v.gsub("\\'", "'").gsub("\\\\", "\\").strip }
              filtered2 = unescaped2.reject { |v| v.empty? || v.match?(/\A[\[\],\s]+\z/) }
              return filtered2 unless filtered2.empty?
            end
          end

          # 3) Fallback: remove outer brackets then split on comma/semicolon/newline, respecting quotes
          t = s.strip
          t = t.sub(/\A\s*\[/, "").sub(/\]\s*\z/, "")
          # Split on comma/semicolon/newline not inside quotes (simple)
          parts = t.split(/[,;\n]+/).map(&:strip)
          # Strip surrounding quotes from each part
          parts.map { |p| p.gsub(/\A["'\s]+|["'\s]+\z/, "").strip }
        else
          return nil
        end
      end

      def self.sanitize_option(v)
        s = v.to_s.strip
        return nil if s.empty?

        # Remove surrounding quotes/brackets that dumb models include
        s = s.gsub(/\A["'\s\[\]]+|["'\s\[\]]+\z/, "").strip
        # Drop wire control tokens (<|...|> and stray <| / |> fragments) that
        # can bleed into labels when the model wraps options in tool_call markup.
        s = s.gsub(/<\|[^|]*\|>/, "").gsub(/<\||\|>/, "")
        # Unescape inner
        s = s.gsub('\\"', '"').gsub("\\'", "'").gsub("\\\\", "\\")
        s = s.strip
        return nil if s.empty?
        return nil if s.match?(/\A[\[\],\s]+\z/)
        return nil if s == "]" || s == "["

        s
      end

      # Public tolerant wrapper used by Engine/KernelLoop/Normalizer (no size check, always returns array)
      def self.normalize_options_lenient(raw)
        arr = extract_options_array(raw)
        return [] unless arr

        arr.map { |v| sanitize_option(v) }.reject { |v| v.nil? || v.empty? }
      end
    end
  end
end
