# frozen_string_literal: true

require_relative "prompt"
require_relative "client"
require_relative "tools/execute"
require_relative "tools/read"
require_relative "tools/write"
require_relative "tools/memory_info"

module Samagotchi
  # The KernelLoop drives the model ↔ tool interaction cycle.
  #
  # Flow:
  #   1. Format the conversation into a Gemma 4 prompt and call llama.cpp.
  #   2. Parse the response for <tool …>…</tool> blocks.
  #   3. Dispatch each tool call, collect results.
  #   4. Append results as a user turn and repeat from step 1.
  #   5. Stop when the model emits no tool calls or max_iterations is reached.
  #
  # Tool call syntax the model should use:
  #   <tool name="execute">bundle exec rspec spec/</tool>
  #   <tool name="read">lib/samagotchi/prompt.rb</tool>
  #   <tool name="write" path="lib/samagotchi/tools/foo.rb">content</tool>
  #   <tool name="memory_info"></tool>
  class KernelLoop
    TOOLS = [
      Tools::Execute,
      Tools::Read,
      Tools::Write,
      Tools::MemoryInfo
    ].freeze

    # Regex for the opening tag only — attributes are short, bounded, and safe.
    TOOL_OPEN_RE  = /<tool\s+([^>]{1,500})>/
    TOOL_CLOSE    = "</tool>"

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

    # Parse tool calls without backtracking: locate opening tags with a bounded
    # regex, then use String#index to find the matching closing tag.
    def parse_tool_calls(text)
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
