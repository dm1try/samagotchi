# frozen_string_literal: true

require_relative "model_profile"
require_relative "tools/execute"
require_relative "tools/read"
require_relative "tools/write"
require_relative "tools/memory"
require_relative "tools/edit"
require_relative "tools/task_create"
require_relative "tools/task_get"
require_relative "tools/task_list"
require_relative "tools/task_stop"
require_relative "tools/task_wait"
require_relative "tools/web_fetch"
require_relative "tools/register_reminder"
require_relative "tools/cancel_reminder"
require_relative "tools/list_reminders"
require_relative "tools/ask_user_question"

module Samagotchi
  # Per-profile strategy for parsing raw model output into internal tool
  # calls ({name:, content:, path:, scope:, ...}) and stripping per-profile
  # thought blocks. KernelLoop delegates here so it no longer carries dual
  # Gemma/Qwen parse code paths; the ModelProfile remains the source of truth
  # for call/thought delimiter tokens.
  class ToolCallParser
    # @param profile [ModelProfile]
    # @return [Gemma, Qwen]
    def self.for_profile(profile)
      profile.name == "qwen36" ? Qwen.new(profile) : Gemma.new(profile)
    end

    # ── Gemma 4 ────────────────────────────────────────────────────────────
    # Tool calls:  <|tool_call>call:NAME{params}<tool_call|>
    # Thoughts:    <|think|>CONTENT (ends at next real <| token) and
    #              <|channel>thought......<channel|>
    class Gemma
      TOOL_CALL_BODY_RE   = /\Acall:([a-z_]{1,50})\{/
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
      # Uses String#index for outer delimiters (no backtracking risk).
      def parse(text)
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
            results << native_call(name, params_raw.strip)
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

      # Map native {key: "value"} params to the internal call hash.
      # Uses well-known named params for each tool; falls back to params_raw if
      # no recognised param is present.
      #
      # The model sometimes omits quotes and/or the space after the colon, e.g.
      #   {command:ruby -e 'puts 1'}  instead of  {command: "ruby -e 'puts 1'"}
      # In that case extract_native_params finds nothing and params_raw still
      # contains the "key:" prefix. strip_param_prefix removes it so the actual
      # command/path value is passed to the tool rather than the raw fragment.
      #
      # Gemma 4 may also use its <|"|> string delimiter token instead of plain
      # quotes. strip_gemma_delimiters is applied to all fallback values so that
      # <|"|>value<|"|> is cleaned to just "value" before being dispatched.
      def native_call(name, params_raw)
        params = extract_native_params(params_raw)

        case name
        when Tools::Execute::NAME
          content = params["command"] ||
                    strip_param_prefix(params_raw, "command") ||
                    params_raw
          { name: name, content: strip_gemma_delimiters(content), path: nil, scope: nil }
        when Tools::Read::NAME
          content = params["path"] ||
                    strip_param_prefix(params_raw, "path") ||
                    params_raw
          {
            name: name,
            content: strip_gemma_delimiters(content),
            path: nil,
            scope: nil,
            start_line: params["start_line"],
            end_line: params["end_line"]
          }
        when Tools::Write::NAME
          { name: name, content: params["content"] || "", path: params["path"], scope: nil }
        when Tools::MemoryRead::NAME
          content = params["name"] ||
                    strip_param_prefix(params_raw, "name") ||
                    params_raw
          { name: name, content: strip_gemma_delimiters(content), path: nil, scope: params["scope"] }
        when Tools::MemoryWrite::NAME
          # The declaration uses "name" (required) and "scope" (required).
          entry_name = params["name"] || ""
          { name: name, content: params["content"] || "", path: entry_name, scope: params["scope"], description: params["description"] ? strip_gemma_delimiters(params["description"]) : nil }
        when Tools::Edit::NAME
          old_text = params["old_text"] || params["old"] || ""
          new_text = params["new_text"] || params["new"] || ""
          content  = "<old>#{old_text}</old><new>#{new_text}</new>"
          {
            name: name,
            content: content,
            path: params["path"],
            scope: nil,
            start_line: params["start_line"],
            end_line: params["end_line"]
          }
        when Tools::TaskCreate::NAME
          command = params["command"] ||
                    strip_param_prefix(params_raw, "command") ||
                    params_raw
          {
            name: name,
            content: strip_gemma_delimiters(command),
            path: nil,
            scope: nil,
            cwd: params["cwd"],
            env: params["env"]
          }
        when Tools::TaskGet::NAME, Tools::TaskStop::NAME
          task_id = params["id"] ||
                    params["task_id"] ||
                    strip_param_prefix(params_raw, "id") ||
                    strip_param_prefix(params_raw, "task_id") ||
                    params_raw
          {
            name: name,
            content: strip_gemma_delimiters(task_id),
            path: nil,
            scope: nil
          }
        when Tools::TaskWait::NAME
          task_id = params["id"] ||
                    params["task_id"] ||
                    strip_param_prefix(params_raw, "id") ||
                    strip_param_prefix(params_raw, "task_id") ||
                    params_raw
          {
            name: name,
            content: strip_gemma_delimiters(task_id),
            path: nil,
            scope: nil,
            timeout: params["timeout"],
            tail_lines: params["tail_lines"],
            done_pattern: params["done_pattern"]
          }
        when Tools::TaskList::NAME
          { name: name, content: "", path: nil, scope: nil }
        when Tools::WebFetch::NAME
          content = params["url"] ||
                    strip_param_prefix(params_raw, "url") ||
                    params_raw
          { name: name, content: strip_gemma_delimiters(content), path: nil, scope: nil }
        when Tools::RegisterReminder::NAME
          content = params["name"] || strip_param_prefix(params_raw, "name") || params_raw
          {
            name: name,
            content: strip_gemma_delimiters(content),
            path: nil,
            scope: nil,
            description: params["description"] || "",
            interval_minutes: params["interval_minutes"] || "1"
          }
        when Tools::CancelReminder::NAME
          content = params["name"] || strip_param_prefix(params_raw, "name") || params_raw
          { name: name, content: strip_gemma_delimiters(content), path: nil, scope: nil }
        when Tools::ListReminders::NAME
          { name: name, content: "", path: nil, scope: nil }
        when Tools::AskUserQuestion::NAME
          { name: name, content: params["question"] ? strip_gemma_delimiters(params["question"]) : strip_gemma_delimiters(params_raw),
            path: nil, scope: nil,
            question: params["question"] ? strip_gemma_delimiters(params["question"]) : strip_gemma_delimiters(params_raw),
            options: parse_ask_options(params, params_raw),
            header: params["header"] ? strip_gemma_delimiters(params["header"]) : nil,
            multi_select: params["multi_select"],
            allow_freeform: params["allow_freeform"] }
        else
          # For future/unknown tools, pass along whatever the model provided
          { name: name, content: strip_gemma_delimiters(params_raw), path: nil, scope: nil }
        end
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
            results << qwen_call_to_internal(name, params)
          end
          pos = close_pos + tool_close.length
        end

        results
      end

      def strip_thought(text)
        # Remove all complete <think>...</think> blocks (including any leading/trailing whitespace)
        result = text.gsub(/<think>.*?<\/think>/m, '')
        # Remove any stray opening tags
        result = result.gsub(/<think>.*?(?=\n|$)/m, '')
        # Remove any orphaned closing tags (and preceding whitespace on same line if it's all whitespace)
        result = result.gsub(/^\s*<\/think>\s*\n?/m, '')
        # Clean up any extra blank lines that may have been left behind
        result.gsub(/\n\n+/, "\n")
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

      def qwen_call_to_internal(name, params)
        case name
        when Tools::Execute::NAME
          { name: name, content: qwen_param_value(params, "command"), path: nil, scope: nil }
        when Tools::Read::NAME
          {
            name: name,
            content: qwen_param_value(params, "path"),
            path: nil,
            scope: nil,
            start_line: qwen_param_value(params, "start_line"),
            end_line: qwen_param_value(params, "end_line")
          }
        when Tools::Write::NAME
          content = qwen_param_value(params, "content", "text", strip: false)
          { name: name, content: content, path: qwen_param_value(params, "path"), scope: nil }
        when Tools::MemoryRead::NAME
          memory_name = qwen_param_value(params, "name")
          { name: name, content: memory_name, path: nil, scope: qwen_param_value(params, "scope") }
        when Tools::MemoryWrite::NAME
          entry_name = qwen_param_value(params, "name")
          content = qwen_param_value(params, "content", "text", "body", "value", strip: false)
          { name: name, content: content, path: entry_name, scope: qwen_param_value(params, "scope"), description: qwen_param_value(params, "description") }
        when Tools::Edit::NAME
          old_text = qwen_param_value(params, "old_text", "old", strip: false)
          new_text = qwen_param_value(params, "new_text", "new", strip: false)
          content  = "<old>#{old_text}</old><new>#{new_text}</new>"
          {
            name: name,
            content: content,
            path: qwen_param_value(params, "path"),
            scope: nil,
            start_line: qwen_param_value(params, "start_line"),
            end_line: qwen_param_value(params, "end_line")
          }
        when Tools::TaskCreate::NAME
          {
            name: name,
            content: qwen_param_value(params, "command"),
            path: nil,
            scope: nil,
            cwd: qwen_param_value(params, "cwd"),
            env: qwen_param_value(params, "env", strip: false)
          }
        when Tools::TaskGet::NAME, Tools::TaskStop::NAME
          {
            name: name,
            content: qwen_param_value(params, "id", "task_id"),
            path: nil,
            scope: nil
          }
        when Tools::TaskWait::NAME
          {
            name: name,
            content: qwen_param_value(params, "id", "task_id"),
            path: nil,
            scope: nil,
            timeout: qwen_param_value(params, "timeout"),
            tail_lines: qwen_param_value(params, "tail_lines"),
            done_pattern: qwen_param_value(params, "done_pattern")
          }
        when Tools::TaskList::NAME
          { name: name, content: "", path: nil, scope: nil }
        when Tools::WebFetch::NAME
          { name: name, content: qwen_param_value(params, "url"), path: nil, scope: nil }
        when Tools::RegisterReminder::NAME
          {
            name: name,
            content: qwen_param_value(params, "name"),
            path: nil,
            scope: nil,
            description: qwen_param_value(params, "description"),
            interval_minutes: qwen_param_value(params, "interval_minutes")
          }
        when Tools::CancelReminder::NAME
          { name: name, content: qwen_param_value(params, "name"), path: nil, scope: nil }
        when Tools::ListReminders::NAME
           { name: name, content: "", path: nil, scope: nil }
        when Tools::AskUserQuestion::NAME
           opts_raw = qwen_param_value(params, "options", strip: false)
           opts = qwen_ask_options(opts_raw)
           {
             name: name,
             content: qwen_param_value(params, "question"),
             path: nil, scope: nil,
             question: qwen_param_value(params, "question"),
             options: opts,
             header: qwen_param_value(params, "header"),
             multi_select: qwen_param_value(params, "multi_select"),
             allow_freeform: qwen_param_value(params, "allow_freeform")
           }
        else
           { name: name, content: params.to_s, path: nil, scope: nil }
        end
      end

       def qwen_param_value(params, *keys, strip: true)
        value = keys.lazy.map { |key| params[key] }.find { |candidate| !candidate.nil? }
        return "" if value.nil?

        strip ? value.to_s.strip : value.to_s
      end

      def qwen_ask_options(raw)
        norm = Samagotchi::Tools::AskUserQuestion.normalize_options_lenient(raw)
        norm.empty? ? nil : norm
      end
    end
  end
end
