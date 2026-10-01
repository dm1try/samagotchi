# frozen_string_literal: true

require_relative "model_profile"
require_relative "tools/args"
require_relative "tools/ask_user_question"
require_relative "tools/builtin_calls"

module Samagotchi
  # Per-profile strategy for reading tool calls out of raw model output and
  # stripping per-profile thought blocks. #read gives each call as
  # {name:, args:, raw:} (its wire format read, nothing more); #parse builds
  # them into internal calls with Tools::BuiltinCalls, as the chat path
  # does. The ModelProfile remains the source of truth for call/thought
  # delimiter tokens.
  class ToolCallParser
    # @param profile [ModelProfile]
    # @return [Gemma, Qwen]
    def self.for_profile(profile)
      profile.name == "qwen36" ? Qwen.new(profile) : Gemma.new(profile)
    end

    # +text+ without its tool-call blocks (+open+ … +close+); a block the model
    # never closed runs to the end. Surrounding whitespace is trimmed.
    def self.strip_calls(text, open, close)
      result = text.to_s
      while (open_pos = result.index(open))
        close_pos = result.index(close, open_pos + open.length)
        result = result[0...open_pos] + (close_pos ? result[close_pos + close.length..] : "")
      end
      result.strip
    end

    # ── Gemma 4 ────────────────────────────────────────────────────────────
    # Tool calls:  <|tool_call>call:NAME{params}<tool_call|>
    # Thoughts:    <|think|>CONTENT (ends at next real <| token) and
    #              <|channel>thought......<channel|>
    class Gemma
      # Digits after the first character: plugin tools may have them
      # (Plugin::Api::TOOL_NAME).
      TOOL_CALL_BODY_RE   = /\Acall:([a-z_][a-z0-9_]{0,49})\{/
      THOUGHT_CHANNEL_OPEN  = "<|channel>thought"
      THOUGHT_CHANNEL_CLOSE = "<channel|>"
      CONTROL_TOKEN_START = "<|"

      def initialize(profile)
        @tool_call_open  = profile.tool_call_open
        @tool_call_close = profile.tool_call_close
        @thought_open    = profile.thought_open
        @string_delim    = profile.string_delim
      end

      # Parse canonical Gemma 4 tool calls:
      #   <|tool_call>call:NAME{params}<tool_call|>
      def parse(text)
        read(text).map { |call| Tools::BuiltinCalls.build(call[:name], call[:args], raw: call[:raw]) }
      end

      # Each tool call as {name:, args:, raw:}, unbuilt.
      # Uses String#index for outer delimiters (no backtracking risk).
      def read(text)
        results = []

        pos = 0
        while (open_pos = text.index(@tool_call_open, pos))
          body_start = open_pos + @tool_call_open.length
          close_pos  = text.index(@tool_call_close, body_start)
          break unless close_pos

          body = text[body_start...close_pos]
          if (m = TOOL_CALL_BODY_RE.match(body))
            name       = m[1]
            params_raw = body[m.end(0)..]
            params_raw = params_raw[0..-2] if params_raw.end_with?("}")
            results << read_call(name, params_raw.strip)
          end
          pos = close_pos + @tool_call_close.length
        end

        results
      end

      # Remove Gemma 4 thought blocks from text.
      # <|think|>CONTENT — ends at the next real <| control token
      # (skipping any <|"|> Gemma string-delimiter tokens) or EOS.
      # <|channel>thought......</channel|> — channel format blocks
      def strip_thought(text)
        result = text

        # Canonical format: strip from <|think|> to the next real <| (exclusive) or EOS
        while (open_pos = result.index(@thought_open))
          body_start = open_pos + @thought_open.length
          close_pos  = next_real_control_token(result, body_start)
          result = if close_pos
                     result[0...open_pos] + result[close_pos..]
                   else
                     result[0...open_pos]
                   end
        end

        # Emitted thought-channel format: strip from <|channel>thought to the
        # corresponding closing tag, or EOS if the close is missing.
        while (open_pos = result.index(THOUGHT_CHANNEL_OPEN))
          close_pos = result.index(THOUGHT_CHANNEL_CLOSE, open_pos)
          result = if close_pos
                     result[0...open_pos] + result[close_pos + THOUGHT_CHANNEL_CLOSE.length..]
                   else
                     result[0...open_pos]
                   end
        end

        result
      end

      def strip_tool_calls(text)
        ToolCallParser.strip_calls(text, @tool_call_open, @tool_call_close)
      end

      # Gemma has no unterminated-tool-call recovery flow.
      def parse_with_recovery(response, _partial_fragment = nil)
        [parse(response.to_s), nil]
      end

      private

      # Scan forward from +start+ for the next <| sequence that is NOT the Gemma
      # string delimiter <|"|>.  Returns the position of that <| or nil if none.
      def next_real_control_token(text, start)
        pos = start
        while (p = text.index(CONTROL_TOKEN_START, pos))
          # Skip over a <|"|> token entirely
          if text[p, @string_delim.length] == @string_delim
            pos = p + @string_delim.length
          else
            return p
          end
        end
        nil
      end

      # Strip all occurrences of the Gemma string-delimiter token from +str+.
      # Used to clean up bare values that use <|"|> as quoting.
      def strip_gemma_delimiters(str)
        str.gsub(@string_delim, "")
      end

      # One call's {key: "value"} params as args (string keys).
      #
      # A built-in's params come from the flat scan (extract_native_params):
      # strings, quotes unescaped its own way. A tool that isn't built in
      # gets its body read as values (Tools::Args.parse_gemma: numbers,
      # booleans, lists, objects), the flat scan when that fails, and the
      # raw text as content for the unknown-tool error.
      #
      # The model sometimes omits quotes and/or the space after the colon, e.g.
      #   {command:ruby -e 'puts 1'}  instead of  {command: "ruby -e 'puts 1'"}
      # In that case extract_native_params finds nothing; the main argument
      # (BuiltinCalls row's fallback) is then the body after a "key:" prefix,
      # or the whole body.
      #
      # Gemma 4 may also use its <|"|> string delimiter token instead of plain
      # quotes; it is stripped from every value but file text, old/new, env
      # and options.
      def read_call(name, params_raw)
        row = Tools::BuiltinCalls.row(name)
        unless row
          args = Tools::Args.parse_gemma(params_raw, @string_delim) || extract_native_params(params_raw)
          return { name: name, args: args, raw: strip_gemma_delimiters(params_raw) }
        end

        params = extract_native_params(params_raw)
        args = params.to_h do |key, value|
          [key, value.is_a?(String) && !row.verbatim_key?(key) ? strip_gemma_delimiters(value) : value]
        end
        fill_main_argument(row, args, params_raw)
        args["options"] = parse_ask_options(params, params_raw) if row.options
        { name: name, args: args, raw: params_raw }
      end

      # The row's main argument from a body the scan didn't find it in.
      def fill_main_argument(row, args, params_raw)
        return unless row.fallback
        return if row.fallback_keys.any? { |key| args.key?(key) }

        value = row.fallback_keys.lazy.map { |key| strip_param_prefix(params_raw, key) }.find(&:itself) unless row.fallback == :raw
        value ||= params_raw unless row.fallback == :prefix
        args[row.fallback_key || row.content_keys.first] = strip_gemma_delimiters(value) if value
      end

      def parse_ask_options(params, params_raw)
        raw = params["options"]
        # Use tolerant normalizer for String and Array; handles dumb-model noise like ["\"Cats\""] or "]"
        if raw.is_a?(String) || raw.is_a?(Array)
          norm = Samagotchi::Tools::AskUserQuestion.normalize_options_lenient(raw)
          return norm unless norm.empty?
        end

        # Fallback: extract array-like syntax from raw string e.g. options:["a","b"]
        if params_raw.include?("options")
          # Try to find a JSON array substring first
          if (m = params_raw.match(/options:\s*(\[[^\]]*\])/))
            norm = Samagotchi::Tools::AskUserQuestion.normalize_options_lenient(m[1])
            return norm unless norm.empty?
          end
          if (m = params_raw.match(/options:\s*\[([^\]]*)\]/))
            inner = m[1]
            norm = Samagotchi::Tools::AskUserQuestion.normalize_options_lenient(inner)
            return norm unless norm.empty?
          end
          # also try Gemma delimiter array
          arr = []
          pos = 0
          while (s = params_raw.index(@string_delim, pos))
            e = params_raw.index(@string_delim, s + @string_delim.length)
            break unless e

            arr << params_raw[s + @string_delim.length...e]
            pos = e + @string_delim.length
          end
          unless arr.empty?
            norm = Samagotchi::Tools::AskUserQuestion.normalize_options_lenient(arr)
            return norm unless norm.empty?
          end
        end
        nil
      end

      # Strip a known "key:" or "key: " prefix from a raw params string.
      # Returns the remainder of the string, or nil if the prefix is absent.
      # Handles both {command:value} (no space) and {command: value} (space).
      def strip_param_prefix(params_raw, key)
        return nil unless params_raw.start_with?("#{key}:")

        params_raw.sub(/\A#{Regexp.escape(key)}:\s*/, "")
      end

      # Extract key: "value" / key: 'value' / key:<|"|>value<|"|> pairs from a
      # native params string.
      # Atomic groups (?>…) prevent ReDoS on adversarial inputs.
      # Both quote styles and the Gemma 4 delimiter are always scanned;
      # double-quoted values take precedence.
      def extract_native_params(params_raw)
        params = {}
        params_raw.scan(/(\w+):\s*"((?>[^"\\]|\\.)*)"/) do |k, v|
          params[k] = unescape_native_value(v)
        end
        params_raw.scan(/(\w+):\s*'((?>[^'\\]|\\.)*)'/) do |k, v|
          params[k] ||= unescape_native_value(v)
        end
        params_raw.scan(/(\w+):\s*(-?\d+)/) do |k, v|
          params[k] ||= v
        end
        # Unquoted boolean values: key:true or key:false
        params_raw.scan(/(\w+):\s*(true|false)\b/) do |k, v|
          params[k] ||= v
        end
        # Gemma 4 string delimiter: key:<|"|>value<|"|>
        # Use plain String#index to avoid any regex backtracking risk on the
        # value content (mirrors the approach used for control-token scanning).
        search_pos = 0
        while (delim_pos = params_raw.index(@string_delim, search_pos))
          val_start = delim_pos + @string_delim.length
          close_pos = params_raw.index(@string_delim, val_start)
          break unless close_pos

          # Extract the key name by scanning backwards: strip trailing whitespace,
          # expect a colon, then extract trailing word characters — all without
          # a backtracking regex so there is no polynomial-ReDoS risk.
          prefix = params_raw[0...delim_pos].rstrip
          unless prefix.end_with?(":")
            search_pos = close_pos + @string_delim.length
            next
          end

          key_part = prefix[0...-1].rstrip
          k_end    = key_part.length
          k_start  = k_end
          # Check each character directly (no regex) — no backtracking risk.
          while k_start > 0
            c = key_part[k_start - 1]
            break unless (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") ||
                         (c >= "0" && c <= "9") || c == "_"

            k_start -= 1
          end
          if k_start < k_end
            k = key_part[k_start...k_end]
            params[k] ||= params_raw[val_start...close_pos]
          end
          search_pos = close_pos + @string_delim.length
        end
        params
      end

      def unescape_native_value(s)
        s.gsub('\\"', '"').gsub("\\'", "'").gsub("\\n", "\n").gsub("\\\\", "\\")
      end
    end

    # ── Qwen 3.6 ────────────────────────────────────────────────────────────
    # Per-profile strategy for Qwen 3.6 (function/parameter XML blocks and literal
    # think tokens). Method bodies are ported verbatim from KernelLoop.
    class Qwen
      def initialize(profile)
        @profile = profile
      end

      def parse(text)
        read(text).map { |call| Tools::BuiltinCalls.build(call[:name], call[:args], raw: call[:raw]) }
      end

      # Each <tool_call> block as {name:, args:, raw:}: its <parameter=…>
      # (or <arg_key>/<arg_value>) text by lowercased key, unbuilt.
      def read(text)
        results = []

        pos = 0
        tool_open = "<tool_call>"
        tool_close = "</tool_call>"

        while (open_pos = text.index(tool_open, pos))
          body_start = open_pos + tool_open.length
          close_pos  = text.index(tool_close, body_start)
          break unless close_pos

          body = text[body_start...close_pos]
          if (name = qwen_function_name(body))
            params = qwen_params(body)
            results << { name: name, args: params, raw: params.to_s }
          end
          pos = close_pos + tool_close.length
        end

        results
      end

      def strip_thought(text)
        # Remove all complete <think>...</think> blocks with the newlines after them
        result = text.gsub(/<think>.*?<\/think>\n*/m, '')
        # Remove any stray opening tags
        result = result.gsub(/<think>.*?(?=\n|$)/m, '')
        # Remove any orphaned closing tags (and the whitespace around them)
        # The answer's own blank lines stay: they are its markdown paragraphs
        # and lists (a chat host's answer is saved as stripped here).
        result.gsub(/^\s*<\/think>\s*/m, '')
      end

      def strip_tool_calls(text)
        ToolCallParser.strip_calls(text, "<tool_call>", "</tool_call>")
      end

      def parse_with_recovery(response, partial_fragment)
        # If the previous turn opened a tool-call block the model never closed,
        # prepend that fragment to this response before parsing. Returns
        # [calls, fragment_or_nil]; a non-nil fragment signals an incomplete call.
        input = partial_fragment ? (partial_fragment + response.to_s) : response.to_s
        [parse(input), qwen_unterminated_tool_call_fragment(input)]
      end

      private

      def qwen_function_name(body)
        match = body.match(/<function=([a-z0-9_]+)(?:>|(?=<)|$)/i)
        match && match[1].to_s.downcase
      end

      def qwen_params(body)
        params = {}

        body.scan(/<parameter=(\w+)>(.*?)<\/parameter>/m) do |key, value|
          params[key.to_s.downcase] = trim_tag_newline(value)
        end

        body.scan(/<arg_key>(.*?)<\/arg_key>\s*<arg_value>(.*?)<\/arg_value>/m) do |key, value|
          params[key.to_s.downcase.strip] = trim_tag_newline(value)
        end

        params
      end

      def trim_tag_newline(value)
        value.sub(/\A\r?\n/, "").sub(/\r?\n\z/, "")
      end

      def qwen_unterminated_tool_call_fragment(text)
        open_tag = "<tool_call>"
        close_tag = "</tool_call>"
        pos = 0

        while (open_pos = text.index(open_tag, pos))
          body_start = open_pos + open_tag.length
          close_pos = text.index(close_tag, body_start)
          return text[open_pos..] unless close_pos

          pos = close_pos + close_tag.length
        end

        nil
      end
    end
  end
end
