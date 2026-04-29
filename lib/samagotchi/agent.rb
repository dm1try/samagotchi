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

        <tool name="execute">shell command</tool>
            Run any shell command and see its stdout/stderr/exit code.
            Examples:
              <tool name="execute">ruby -e 'puts 2 + 2'</tool>
              <tool name="execute">bundle exec rspec spec/ --no-color</tool>
              <tool name="execute">bundle exec rspec spec/some_spec.rb --no-color</tool>

        <tool name="read">path/to/file</tool>
            Read a file from disk.

        <tool name="write" path="path/to/file">content</tool>
            Write content to a file (parent directories created automatically).

      You may use multiple tools in one response. After seeing tool results, continue reasoning or answer the user.
    SYS

    SYSTEM_EVOLVE = <<~SYS
      You are samagotchi, a self-evolving Ruby agent harness running on Gemma 4 via llama.cpp.
      Your goal: read your own source, decide what to improve or extend, implement it, and validate with RSpec.

      Available tools:
        <tool name="execute">shell command</tool>       — run ruby, bundle exec rspec, or any shell command
        <tool name="read">path/to/file</tool>           — read a source file
        <tool name="write" path="path">content</tool>   — write/overwrite a file

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
        4. Validate: <tool name="execute">bundle exec rspec spec/tools/<name>_spec.rb --no-color</tool>

      Begin by reading your source files and deciding what to add or improve.
    SYS

    def initialize(mode:, client: nil, verbose: false)
      @mode   = mode.to_sym
      @kernel = KernelLoop.new(client: client, verbose: verbose)
    end

    def run
      case @mode
      when :assist then assist_loop
      when :evolve then evolve_loop
      else raise ArgumentError, "Unknown mode '#{@mode}'. Use: assist, evolve"
      end
    end

    private

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
