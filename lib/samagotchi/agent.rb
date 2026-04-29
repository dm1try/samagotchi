# frozen_string_literal: true

require_relative "kernel_loop"

module Samagotchi
  # Agent encapsulates the two operating modes of the harness.
  #
  # assist mode  — interactive REPL: user types, model responds, tools execute inline.
  # evolve mode  — autonomous: model reads its own source, extends itself, validates with rspec.
  class Agent
    SYSTEM_ASSIST = <<~SYS
      You are a Ruby code assistant. You have access to the following tools:

      <|tool>declaration:execute{"description":"Run any shell command and see its stdout, stderr, and exit code","parameters":{"command":{"type":"string","description":"The shell command to run"}}}<tool|>
      <|tool>declaration:read{"description":"Read a file from disk","parameters":{"path":{"type":"string","description":"Path to the file"}}}<tool|>
      <|tool>declaration:write{"description":"Write content to a file (parent directories are created automatically)","parameters":{"path":{"type":"string","description":"Destination file path"},"content":{"type":"string","description":"Content to write to the file"}}}<tool|>
      <|tool>declaration:edit{"description":"Replace an exact block of text in an existing file; the old block must appear exactly once","parameters":{"path":{"type":"string","description":"File path"},"old_text":{"type":"string","description":"Exact text to replace"},"new_text":{"type":"string","description":"Replacement text"}}}<tool|>

      To call a tool, emit: <|tool_call>call:NAME{param: "value"}<tool_call|>
      You may make multiple tool calls. After seeing tool results, continue reasoning or answer the user.
    SYS

    SYSTEM_EVOLVE = <<~SYS
      You are samagotchi, a self-evolving Ruby agent harness running on Gemma 4 via llama.cpp.
      Your goal: read your own source, decide what to improve or extend, implement it, and validate with RSpec.

      Available tools:

      <|tool>declaration:execute{"description":"Run ruby, bundle exec rspec, or any shell command","parameters":{"command":{"type":"string","description":"Shell command to run"}}}<tool|>
      <|tool>declaration:read{"description":"Read a source file from disk","parameters":{"path":{"type":"string","description":"Path to the file"}}}<tool|>
      <|tool>declaration:write{"description":"Write or overwrite a file (parent directories created automatically)","parameters":{"path":{"type":"string","description":"Destination file path"},"content":{"type":"string","description":"File content"}}}<tool|>
      <|tool>declaration:edit{"description":"Replace an exact block of text in an existing file","parameters":{"path":{"type":"string","description":"File path"},"old_text":{"type":"string","description":"Exact text to replace"},"new_text":{"type":"string","description":"Replacement text"}}}<tool|>

      To call a tool, emit: <|tool_call>call:NAME{param: "value"}<tool_call|>
      Prefer edit over write when changing a small section of a large file.

      Source layout:
        bin/samagotchi                 CLI entry point
        lib/samagotchi/prompt.rb       Gemma 4 prompt formatter
        lib/samagotchi/client.rb       llama.cpp HTTP client
        lib/samagotchi/kernel_loop.rb  Tool-dispatch loop (add new tools here)
        lib/samagotchi/agent.rb        Role logic (this file)
        lib/samagotchi/tools/          Individual tool implementations
        spec/                          RSpec test suite

      Workflow for adding a new tool:
        1. Write lib/samagotchi/tools/<name>.rb with self.name and self.call
        2. Require it in lib/samagotchi/kernel_loop.rb and add to TOOLS
        3. Write spec/tools/<name>_spec.rb
        4. Validate: <|tool_call>call:execute{command: "bundle exec rspec spec/tools/<name>_spec.rb --no-color"}<tool_call|>

      Begin by reading your source files and deciding what to add or improve.
    SYS

    def initialize(mode:, prompt: nil, client: nil, verbose: false)
      @mode   = mode.to_sym
      @prompt = prompt
      @kernel = KernelLoop.new(client: client, verbose: verbose)
    end

    def run
      return prompt_mode if @prompt

      case @mode
      when :assist then assist_loop
      when :evolve then evolve_loop
      else raise ArgumentError, "Unknown mode '#{@mode}'. Use: assist, evolve"
      end
    end

    private

    def prompt_mode
      messages = [
        { role: "system", content: SYSTEM_ASSIST },
        { role: "user",   content: @prompt }
      ]
      $stdout.puts @kernel.run(messages)
    end

    def assist_loop
      $stdout.puts banner("assist")
      messages = [{ role: "system", content: SYSTEM_ASSIST }]

      loop do
        $stdout.print "\nyou> "
        $stdout.flush
        input = $stdin.gets&.strip
        break if input.nil?
        next  if input.empty?

        messages << { role: "user", content: input }
        response = @kernel.run(messages)
        $stdout.puts "\nmodel> #{response}"
        messages << { role: "model", content: response }
      end

      $stdout.puts "\nbye."
    end

    def evolve_loop
      $stdout.puts banner("evolve")
      messages = [
        { role: "system", content: SYSTEM_EVOLVE },
        { role: "user",   content: "Read your source files, identify improvements, implement them, and validate with rspec." }
      ]
      $stdout.puts @kernel.run(messages, max_iterations: 20)
    end

    def banner(mode)
      host = ENV.fetch("LLAMA_HOST", "localhost")
      port = ENV.fetch("LLAMA_PORT", "8080")
      "samagotchi [#{mode}] — #{host}:#{port}\n#{"─" * 60}"
    end
  end
end
