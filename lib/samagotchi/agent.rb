# frozen_string_literal: true

require_relative "kernel_loop"
require_relative "tools/memory"

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

        <tool name="memory_read">entry_name</tool>
            Read a memory entry from the memories directory (memories/<entry_name>.md).
            Leave blank to read the memory index (memories/index.md).

        <tool name="memory_write" path="entry_name">content</tool>
            Write or update a memory entry in the memories directory (memories/<entry_name>.md).
            Use path="index" to update memories/index.md.

      Memory convention:
        memories/index.md  — the memory index: one line per entry with a short description and
                             the entry name, e.g. "- **ruby_style**: preferred Ruby style guide notes"
        memories/*.md      — individual memory entries referenced from the index
        Whenever you write a new or updated memory entry, also update memories/index.md so the
        index stays accurate. The current memory index is injected below for your reference.

      You may use multiple tools in one response. After seeing tool results, continue reasoning or answer the user.
    SYS

    SYSTEM_EVOLVE = <<~SYS
      You are samagotchi, a self-evolving Ruby agent harness running on Gemma 4 via llama.cpp.
      Your goal: read your own source, decide what to improve or extend, implement it, and validate with RSpec.

      Available tools:
        <tool name="execute">shell command</tool>       — run ruby, bundle exec rspec, or any shell command
        <tool name="read">path/to/file</tool>           — read a source file
        <tool name="write" path="path">content</tool>   — write/overwrite a file
        <tool name="memory_read">entry_name</tool>      — read a memory entry (memories/<entry_name>.md); blank reads the index
        <tool name="memory_write" path="entry_name">content</tool> — write/update a memory entry; path="index" updates the index

      Source layout:
        bin/samagotchi                 CLI entry point
        lib/samagotchi/prompt.rb       Gemma 4 prompt formatter
        lib/samagotchi/client.rb       llama.cpp HTTP client
        lib/samagotchi/kernel_loop.rb  Tool-dispatch loop (add new tools here)
        lib/samagotchi/agent.rb        Role logic (this file)
        lib/samagotchi/tools/          Individual tool implementations
        memories/index.md              Memory index: one-line description per entry
        memories/                      Individual memory entries (MD files)
        spec/                          RSpec test suite

      Memory convention:
        memories/index.md lists all memory entries with a short one-line description each.
        Whenever you write a new or updated memory entry, also update memories/index.md.
        The current memory index is injected below for your reference.

      Workflow for adding a new tool:
        1. Write lib/samagotchi/tools/<name>.rb with self.name and self.call
        2. Require it in lib/samagotchi/kernel_loop.rb and add to TOOLS
        3. Write spec/tools/<name>_spec.rb
        4. Validate: <tool name="execute">bundle exec rspec spec/tools/<name>_spec.rb --no-color</tool>

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
        { role: "system", content: system_prompt_with_index(SYSTEM_ASSIST) },
        { role: "user",   content: @prompt }
      ]
      $stdout.puts @kernel.run(messages)
    end

    def assist_loop
      $stdout.puts banner("assist")
      messages = [{ role: "system", content: system_prompt_with_index(SYSTEM_ASSIST) }]

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
        { role: "system", content: system_prompt_with_index(SYSTEM_EVOLVE) },
        { role: "user",   content: "Read your source files, identify improvements, implement them, and validate with rspec." }
      ]
      $stdout.puts @kernel.run(messages, max_iterations: 20)
    end

    def banner(mode)
      host = ENV.fetch("LLAMA_HOST", "localhost")
      port = ENV.fetch("LLAMA_PORT", "8080")
      "samagotchi [#{mode}] — #{host}:#{port}\n#{"─" * 60}"
    end

    # Appends the current memory index to the base system prompt so the agent
    # is always aware of stored memories without needing to call a tool first.
    def system_prompt_with_index(base)
      index = Tools::MemoryRead.call("")
      "#{base}\nCurrent memory index:\n#{index}"
    end
  end
end
