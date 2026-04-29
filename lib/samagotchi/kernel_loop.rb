# frozen_string_literal: true

require_relative "prompt"
require_relative "client"
require_relative "tools/execute"
require_relative "tools/read"
require_relative "tools/write"

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
  # Native Gemma 4 syntax (emitted by the model naturally):
  #   <|tool_call>call:execute{command: "bundle exec rspec spec/"}<tool_call|>
  #   <|tool_call>call:read{path: "lib/samagotchi/prompt.rb"}<tool_call|>
  #   <|tool_call>call:write{path: "lib/foo.rb", content: "..."}<tool_call|>
  class KernelLoop
    TOOLS = [
      Tools::Execute,
      Tools::Read,
      Tools::Write
    ].freeze

    # ── XML format constants ───────────────────────────────────────────────────
    # Regex for the opening tag only — attributes are short, bounded, and safe.
    TOOL_OPEN_RE  = /<tool\s+([^>]{1,500})>/
    TOOL_CLOSE    = "</tool>"

    # ── Native Gemma 4 format constants ───────────────────────────────────────
    NATIVE_OPEN      = "<|tool_call>"
    NATIVE_CLOSE     = "<tool_call|>"
    NATIVE_CALL_RE   = /\Acall:([a-z_]{1,50})\{/

    # ── Gemma 4 thought-channel stripping ─────────────────────────────────────
    # Gemma 4 can emit <|channel>thought...reasoning...<channel|> blocks for
    # internal chain-of-thought. These tokens are used as string delimiters
    # (no regex) to avoid any backtracking risk on adversarial input.
    THOUGHT_OPEN  = "<|channel>thought"
    THOUGHT_CLOSE = "<channel|>"

    def initialize(client: nil)
      @client = client || Client.new
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
        conversation << { role: "model", content: response }

        calls = parse_tool_calls(response)
        break if calls.empty?

        results = calls.map { |c| dispatch(c) }.join("\n\n---\n\n")
        conversation << { role: "user", content: "Tool results:\n#{results}" }
      end

      conversation.last[:content]
    end

    private

    # Combines XML and native Gemma 4 tool-call parsers so the harness works
    # regardless of which format the model naturally emits.
    # Thought blocks are stripped first so that tool-call examples the model
    # writes in its internal reasoning are not inadvertently dispatched.
    def parse_tool_calls(text)
      cleaned = strip_thought_blocks(text)
      parse_xml_tool_calls(cleaned) + parse_native_tool_calls(cleaned)
    end

    # Remove <|channel>thought...<channel|> blocks from model output.
    # Uses String#index (no regex backtracking) to safely handle large inputs.
    def strip_thought_blocks(text)
      result = text
      while (open_pos = result.index(THOUGHT_OPEN))
        close_pos = result.index(THOUGHT_CLOSE, open_pos)
        break unless close_pos

        result = result[0...open_pos] + result[close_pos + THOUGHT_CLOSE.length..]
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

        content = text[start...close].strip
        results << { name: name, path: path, content: content } if name
        pos = close + TOOL_CLOSE.length
      end
      results
    end

    # ── Native Gemma 4 parser ─────────────────────────────────────────────────
    # Parse the model's natural output: <|tool_call>call:NAME{params}<tool_call|>
    # Uses String#index for the outer delimiters (no backtracking risk).
    def parse_native_tool_calls(text)
      results = []
      pos = 0
      while (open_pos = text.index(NATIVE_OPEN, pos))
        body_start = open_pos + NATIVE_OPEN.length
        close_pos  = text.index(NATIVE_CLOSE, body_start)
        break unless close_pos

        body = text[body_start...close_pos]
        if (m = NATIVE_CALL_RE.match(body))
          name       = m[1]
          params_raw = body[m.end(0)..]
          params_raw = params_raw[0..-2] if params_raw.end_with?("}")
          results << native_call(name, params_raw.strip)
        end
        pos = close_pos + NATIVE_CLOSE.length
      end
      results
    end

    # Map native {key: "value"} params to the internal call hash.
    # Uses well-known named params for each tool; falls back to params_raw if
    # no recognised param is present.
    def native_call(name, params_raw)
      params = extract_native_params(params_raw)

      case name
      when Tools::Execute::NAME
        # "command" is the canonical param; fall back to the raw string
        { name: name, content: params["command"] || params_raw, path: nil }
      when Tools::Read::NAME
        { name: name, content: params["path"] || params_raw, path: nil }
      when Tools::Write::NAME
        { name: name, content: params["content"] || "", path: params["path"] }
      else
        # For future/unknown tools, pass along whatever the model provided
        { name: name, content: params_raw, path: nil }
      end
    end

    # Extract key: "value" / key: 'value' pairs from a native params string.
    # Atomic groups (?>…) prevent ReDoS on adversarial inputs.
    # Both quote styles are always scanned; double-quoted values take precedence.
    def extract_native_params(params_raw)
      params = {}
      params_raw.scan(/(\w+):\s*"((?>[^"\\]|\\.)*)"/) do |k, v|
        params[k] = unescape_native_value(v)
      end
      params_raw.scan(/(\w+):\s*'((?>[^'\\]|\\.)*)'/) do |k, v|
        params[k] ||= unescape_native_value(v)
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

      result = if call[:name] == Tools::Write::NAME && call[:path]
                 tool.call(call[:content], path: call[:path])
               else
                 tool.call(call[:content])
               end

      "[#{call[:name]}]\n#{result}"
    rescue => e
      "[#{call[:name]}] Error: #{e.message}"
    end
  end
end
