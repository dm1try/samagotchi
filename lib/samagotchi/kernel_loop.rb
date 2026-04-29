# frozen_string_literal: true

require_relative "prompt"
require_relative "client"
require_relative "tools/execute"
require_relative "tools/read"
require_relative "tools/write"
require_relative "tools/edit"

module Samagotchi
  # The KernelLoop drives the model ↔ tool interaction cycle.
  #
  # Flow:
  #   1. Format the conversation into a Gemma 4 prompt and call llama.cpp.
  #   2. Parse the response for tool-call blocks (XML or native Gemma 4 format).
  #   3. Dispatch each tool call, collect results.
  #   4. Append results as a user turn and repeat from step 1.
  #   5. Stop when the model emits no tool calls or max_iterations is reached.
  #
  # XML syntax (harness-defined, accepted for completeness):
  #   <tool name="execute">bundle exec rspec spec/</tool>
  #   <tool name="read">lib/samagotchi/prompt.rb</tool>
  #   <tool name="write" path="lib/samagotchi/tools/foo.rb">content</tool>
  #
  # Native Gemma 4 syntax (canonical, per documentation):
  #   <|tool>declaration:execute{command: "bundle exec rspec spec/"}
  #   <|tool>declaration:read{path: "lib/samagotchi/prompt.rb"}
  #   <|tool>declaration:write{path: "lib/foo.rb", content: "..."}
  #
  # Legacy native syntax (still accepted for backward compatibility):
  #   <|tool_call>call:execute{command: "bundle exec rspec spec/"}<tool_call|>
  #   <|tool_call>call:read{path: "lib/samagotchi/prompt.rb"}<tool_call|>
  #   <|tool_call>call:write{path: "lib/foo.rb", content: "..."}<tool_call|>
  class KernelLoop
    TOOLS = [
      Tools::Execute,
      Tools::Read,
      Tools::Write,
      Tools::Edit
    ].freeze

    # ── XML format constants ───────────────────────────────────────────────────
    # Regex for the opening tag only — attributes are short, bounded, and safe.
    TOOL_OPEN_RE  = /<tool\s+([^>]{1,500})>/
    TOOL_CLOSE    = "</tool>"

    # ── Native Gemma 4 format constants (canonical) ───────────────────────────
    # <|tool>declaration:NAME{params}  — body runs to next <| token, \n, or EOS
    NATIVE_OPEN      = "<|tool>"
    NATIVE_CALL_RE   = /\Adeclaration:([a-z_]{1,50})\{/

    # ── Native Gemma 4 format constants (legacy fallback) ─────────────────────
    # Older model checkpoints emit <|tool_call>call:NAME{params}<tool_call|>.
    NATIVE_OPEN_LEGACY     = "<|tool_call>"
    NATIVE_CLOSE_LEGACY    = "<tool_call|>"
    NATIVE_CALL_RE_LEGACY  = /\Acall:([a-z_]{1,50})\{/

    # ── Gemma 4 string delimiter ──────────────────────────────────────────────
    # Gemma 4 uses <|"|> as a delimiter token for all string values in its
    # structured data blocks (function calls, responses, etc.).  The harness
    # must NOT mistake the <| in this token for a real control-token boundary,
    # and must strip/translate these delimiters when extracting parameter values.
    GEMMA_STRING_DELIM = '<|"|>'

    # ── Gemma 4 thought-channel stripping (canonical) ─────────────────────────
    # <|think|> opens a private reasoning block; it ends at the next <| control
    # token (that is not the Gemma string delimiter) or end of string.  Both
    # delimiters are used as plain strings (no regex) to avoid any backtracking
    # risk on adversarial input.
    THOUGHT_OPEN        = "<|think|>"
    CONTROL_TOKEN_START = "<|"

    # ── Gemma 4 thought-channel stripping (legacy fallback) ───────────────────
    # Older model checkpoints emit <|channel>thought...<channel|> blocks.
    THOUGHT_OPEN_LEGACY  = "<|channel>thought"
    THOUGHT_CLOSE_LEGACY = "<channel|>"

    def initialize(client: nil, verbose: false)
      @client  = client || Client.new
      @verbose = verbose
    end

    # Run the conversation loop and return the final model response text.
    #
    # @param messages       [Array<Hash>] conversation so far ({role:, content:})
    # @param max_iterations [Integer]    safety cap on tool-call rounds
    # @return [String] last model response (after all tool calls are resolved)
    def run(messages, max_iterations: 10)
      conversation = messages.dup

      max_iterations.times do
        prompt   = Prompt.format(conversation)
        response = @client.complete(prompt)
        verbose_log("── LLM response ──\n#{response}\n──────────────────")
        conversation << { role: "model", content: response }

        calls = parse_tool_calls(response)
        break if calls.empty?

        results = calls.map { |c| dispatch(c) }.join("\n\n---\n\n")
        conversation << { role: "user", content: "Tool results:\n#{results}" }
      end

      strip_thought_blocks(conversation.last[:content])
    end

    private

    def verbose_log(message)
      return unless @verbose

      $stderr.puts "\n[verbose] #{message}"
    end

    # Combines XML and native Gemma 4 tool-call parsers so the harness works
    # regardless of which format the model naturally emits.
    # Thought blocks (<|think|> canonical or <|channel>thought legacy) are
    # stripped first so that tool-call examples written in internal reasoning
    # are not inadvertently dispatched.
    def parse_tool_calls(text)
      cleaned = strip_thought_blocks(text)
      parse_xml_tool_calls(cleaned) + parse_native_tool_calls(cleaned)
    end

    # Remove thought blocks from model output. Two formats are handled:
    #   Canonical: <|think|>CONTENT — ends at the next real <| control token
    #              (skipping any <|"|> Gemma string-delimiter tokens) or EOS.
    #   Legacy:    <|channel>thought...CONTENT...<channel|>
    # Uses String#index (no regex backtracking) to safely handle large inputs.
    def strip_thought_blocks(text)
      result = text

      # Canonical format: strip from <|think|> to the next real <| (exclusive) or EOS
      while (open_pos = result.index(THOUGHT_OPEN))
        body_start = open_pos + THOUGHT_OPEN.length
        close_pos  = next_real_control_token(result, body_start)
        result = if close_pos
                   result[0...open_pos] + result[close_pos..]
                 else
                   result[0...open_pos]
                 end
      end

      # Legacy format: strip from <|channel>thought to end of <channel|>.
      # If there is no closing tag the entire remainder is the thought block;
      # strip to EOS (mirrors the canonical <|think|> behaviour above).
      while (open_pos = result.index(THOUGHT_OPEN_LEGACY))
        close_pos = result.index(THOUGHT_CLOSE_LEGACY, open_pos)
        result = if close_pos
                   result[0...open_pos] + result[close_pos + THOUGHT_CLOSE_LEGACY.length..]
                 else
                   result[0...open_pos]
                 end
      end

      result
    end

    # ── XML parser ────────────────────────────────────────────────────────────
    # Parse XML-style tool calls without backtracking: locate opening tags with
    # a bounded regex, then use String#index to find the matching closing tag.
    def parse_xml_tool_calls(text)
      results = []
      pos = 0
      while (m = TOOL_OPEN_RE.match(text, pos))
        attrs   = m[1]
        name    = attrs[/name="([^"]{1,100})"/, 1]
        path    = attrs[/path="([^"]{1,500})"/, 1]
        start   = m.end(0)
        close   = text.index(TOOL_CLOSE, start)
        break unless close

        content = strip_gemma_delimiters(text[start...close].strip)
        results << { name: name, path: path, content: content } if name
        pos = close + TOOL_CLOSE.length
      end
      results
    end

    # ── Native Gemma 4 parser ─────────────────────────────────────────────────
    # Parse the model's natural output. Two formats are supported:
    #   Canonical: <|tool>declaration:NAME{params}
    #              Body runs to the next <| control token, newline, or EOS.
    #   Legacy:    <|tool_call>call:NAME{params}<tool_call|>
    # Uses String#index for outer delimiters (no backtracking risk).
    def parse_native_tool_calls(text)
      results = []

      # Canonical format
      pos = 0
      while (open_pos = text.index(NATIVE_OPEN, pos))
        body_start = open_pos + NATIVE_OPEN.length
        close_pos  = native_call_end(text, body_start)
        body = text[body_start...close_pos]
        if (m = NATIVE_CALL_RE.match(body))
          name       = m[1]
          params_raw = body[m.end(0)..]
          params_raw = params_raw[0..-2] if params_raw.end_with?("}")
          results << native_call(name, params_raw.strip)
        end
        pos = close_pos
      end

      # Legacy format
      pos = 0
      while (open_pos = text.index(NATIVE_OPEN_LEGACY, pos))
        body_start = open_pos + NATIVE_OPEN_LEGACY.length
        close_pos  = text.index(NATIVE_CLOSE_LEGACY, body_start)
        break unless close_pos

        body = text[body_start...close_pos]
        if (m = NATIVE_CALL_RE_LEGACY.match(body))
          name       = m[1]
          params_raw = body[m.end(0)..]
          params_raw = params_raw[0..-2] if params_raw.end_with?("}")
          results << native_call(name, params_raw.strip)
        end
        pos = close_pos + NATIVE_CLOSE_LEGACY.length
      end

      results
    end

    # Find the end position of a canonical <|tool> call body starting at +start+.
    # The body is terminated by a newline, the next real <| control token (i.e.
    # NOT the Gemma string delimiter <|"|>), or EOS.
    def native_call_end(text, start)
      nl_pos    = text.index("\n", start)
      token_pos = next_real_control_token(text, start)
      [nl_pos, token_pos].compact.min || text.length
    end

    # Scan forward from +start+ for the next <| sequence that is NOT the Gemma
    # string delimiter <|"|>.  Returns the position of that <| or nil if none.
    def next_real_control_token(text, start)
      pos = start
      while (p = text.index(CONTROL_TOKEN_START, pos))
        # Skip over a <|"|> token entirely
        if text[p, GEMMA_STRING_DELIM.length] == GEMMA_STRING_DELIM
          pos = p + GEMMA_STRING_DELIM.length
        else
          return p
        end
      end
      nil
    end

    # Strip all occurrences of the Gemma string-delimiter token from +str+.
    # Used to clean up bare values that use <|"|> as quoting.
    def strip_gemma_delimiters(str)
      str.gsub(GEMMA_STRING_DELIM, "")
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
        { name: name, content: strip_gemma_delimiters(content), path: nil }
      when Tools::Read::NAME
        content = params["path"] ||
                  strip_param_prefix(params_raw, "path") ||
                  params_raw
        { name: name, content: strip_gemma_delimiters(content), path: nil }
      when Tools::Write::NAME
        { name: name, content: params["content"] || "", path: params["path"] }
      when Tools::Edit::NAME
        old_text = params["old_text"] || params["old"] || ""
        new_text = params["new_text"] || params["new"] || ""
        content  = "<old>#{old_text}</old><new>#{new_text}</new>"
        { name: name, content: content, path: params["path"] }
      else
        # For future/unknown tools, pass along whatever the model provided
        { name: name, content: strip_gemma_delimiters(params_raw), path: nil }
      end
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
      # Gemma 4 string delimiter: key:<|"|>value<|"|>
      # Use plain String#index to avoid any regex backtracking risk on the
      # value content (mirrors the approach used for control-token scanning).
      search_pos = 0
      while (delim_pos = params_raw.index(GEMMA_STRING_DELIM, search_pos))
        val_start = delim_pos + GEMMA_STRING_DELIM.length
        close_pos = params_raw.index(GEMMA_STRING_DELIM, val_start)
        break unless close_pos

        # Extract the key name by scanning backwards: strip trailing whitespace,
        # expect a colon, then extract trailing word characters — all without
        # a backtracking regex so there is no polynomial-ReDoS risk.
        prefix = params_raw[0...delim_pos].rstrip
        unless prefix.end_with?(":")
          search_pos = close_pos + GEMMA_STRING_DELIM.length
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
        search_pos = close_pos + GEMMA_STRING_DELIM.length
      end
      params
    end

    def unescape_native_value(s)
      s.gsub('\\"', '"').gsub("\\'", "'").gsub("\\n", "\n").gsub("\\\\", "\\")
    end

    def dispatch(call)
      tool = TOOLS.find { |t| t.name == call[:name] }
      unless tool
        available = TOOLS.map(&:name).join(", ")
        return "Error: unknown tool '#{call[:name]}'. Available: #{available}"
      end

      verbose_log("── tool call: #{call[:name]} ──\n#{call[:path] ? "path: #{call[:path]}\n" : ""}#{call[:content]}\n──────────────────")

      result = if (call[:name] == Tools::Write::NAME || call[:name] == Tools::Edit::NAME) && call[:path]
                 tool.call(call[:content], path: call[:path])
               else
                 tool.call(call[:content])
               end

      verbose_log("── tool result: #{call[:name]} ──\n#{result}\n──────────────────")
      "[#{call[:name]}]\n#{result}"
    rescue => e
      verbose_log("── tool error: #{call[:name]} ──\n#{e.message}\n──────────────────")
      "[#{call[:name]}] Error: #{e.message}"
    end
  end
end
