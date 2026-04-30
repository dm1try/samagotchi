# frozen_string_literal: true

require_relative "kernel_loop"
require_relative "tools/memory"

module Samagotchi
  # Agent encapsulates the two operating modes of the harness.
  #
  # assist mode  — interactive REPL: user types, model responds, tools execute inline.
  # evolve mode  — autonomous: model reads its own source, extends itself, validates with rspec.
  class Agent
    AGENT_DESCRIPTION_FILE = "AGENT.md"
    SKIP_AGENT_DESCRIPTION_ENV = "SAMAGOTCHI_SKIP_AGENT_MD"
    CONTINUE_COMMAND = "/continue"

    # ── Tool declarations (Gemma 4 <|tool>/<tool|> format) ────────────────────

    TOOL_EXECUTE = <<~DECL.strip
      <|tool>declaration:execute{
        description:<|"|>Run any shell command and see its stdout, stderr, and exit code<|"|>,
        parameters:{
          command:{type:<|"|>string<|"|>, description:<|"|>The shell command to run<|"|>, required:true}
        }
      }<tool|>
    DECL

    TOOL_READ = <<~DECL.strip
      <|tool>declaration:read{
        description:<|"|>Read a file from disk<|"|>,
        parameters:{
          path:{type:<|"|>string<|"|>, description:<|"|>Path to the file<|"|>, required:true}
        }
      }<tool|>
    DECL

    TOOL_WRITE = <<~DECL.strip
      <|tool>declaration:write{
        description:<|"|>Write content to a file (parent directories are created automatically)<|"|>,
        parameters:{
          path:{type:<|"|>string<|"|>, description:<|"|>Destination file path<|"|>, required:true},
          content:{type:<|"|>string<|"|>, description:<|"|>Content to write to the file<|"|>, required:true}
        }
      }<tool|>
    DECL

    TOOL_EDIT = <<~DECL.strip
      <|tool>declaration:edit{
        description:<|"|>Replace an exact block of text in an existing file; the old block must appear exactly once<|"|>,
        parameters:{
          path:{type:<|"|>string<|"|>, description:<|"|>File path<|"|>, required:true},
          old_text:{type:<|"|>string<|"|>, description:<|"|>Exact text to replace<|"|>, required:true},
          new_text:{type:<|"|>string<|"|>, description:<|"|>Replacement text<|"|>, required:true}
        }
      }<tool|>
    DECL

    TOOL_MEMORY_READ = <<~DECL.strip
      <|tool>declaration:memory_read{
        description:<|"|>Read a memory entry from the memories directory (memories/<name>.md). Leave name blank to read the memory index.<|"|>,
        parameters:{
          name:{type:<|"|>string<|"|>, description:<|"|>Memory entry name without .md extension; leave blank for the index<|"|>}
        }
      }<tool|>
    DECL

    TOOL_MEMORY_WRITE = <<~DECL.strip
      <|tool>declaration:memory_write{
        description:<|"|>Write or update a memory entry in the memories directory (memories/<name>.md). Use name 'index' to update the index.<|"|>,
        parameters:{
          name:{type:<|"|>string<|"|>, description:<|"|>Memory entry name without .md extension<|"|>, required:true},
          content:{type:<|"|>string<|"|>, description:<|"|>Markdown content to write<|"|>, required:true}
        }
      }<tool|>
    DECL

    TOOL_CALL_HINT = 'To call a tool, emit: <|tool_call>call:NAME{param:<|"|>value<|"|>}<tool_call|>. CRITICAL: check the tool declaration for the exact parameter names and required fields!'
    RG_GUIDANCE = "For fast repository/text search, prefer `rg` (ripgrep) over `grep` when exploring files or text."
    CONTEXT_STATUS_PROTOCOL = <<~PROTOCOL
      Context budget protocol:
        You may receive synthetic system messages that start with CONTEXT_STATUS.
        Treat CONTEXT_STATUS as telemetry, not as a user request.
        If context usage is high (for example >= 80%), prioritise:
          1. clarifying ambiguous requirements before implementation,
          2. minimizing unnecessary tool calls and repetitive exploration,
          3. keeping plans and outputs concise while preserving correctness.
        Never ignore direct user instructions because of telemetry.
    PROTOCOL
    # ── System prompts ─────────────────────────────────────────────────────────

    SYSTEM_ASSIST = <<~SYS
      You are a Ruby code assistant. You have access to the following tools:

      #{TOOL_EXECUTE}
      #{TOOL_READ}
      #{TOOL_WRITE}
      #{TOOL_EDIT}
      #{TOOL_MEMORY_READ}
      #{TOOL_MEMORY_WRITE}

      #{TOOL_CALL_HINT}
      You may make multiple tool calls. After seeing tool results, continue reasoning or answer the user.

      Memory convention:
        memories/index.md  — the memory index: one line per entry with a short description and
                             the entry name, e.g. "- **ruby_style**: preferred Ruby style guide notes"
        memories/*.md      — individual memory entries referenced from the index
        Whenever you write a new or updated memory entry, also update memories/index.md.

      #{CONTEXT_STATUS_PROTOCOL}
    SYS

    SYSTEM_EVOLVE = <<~SYS
      You are samagotchi, a self-evolving Ruby agent harness running on Gemma 4 via llama.cpp.
      Your goal: read your own source, decide what to improve or extend, implement it, and validate with RSpec.

      Available tools:

      #{TOOL_EXECUTE}
      #{TOOL_READ}
      #{TOOL_WRITE}
      #{TOOL_EDIT}
      #{TOOL_MEMORY_READ}
      #{TOOL_MEMORY_WRITE}

      #{TOOL_CALL_HINT}
      Prefer edit over write when changing a small section of a large file.

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
        4. Validate: <|tool_call>call:execute{command:<|"|>bundle exec rspec spec/tools/<name>_spec.rb --no-color<|"|>}<tool_call|>

      #{CONTEXT_STATUS_PROTOCOL}

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
      result = @kernel.run(messages)
      emit_result(result)
    end

    def assist_loop
      $stdout.puts banner("assist")
      messages = [{ role: "system", content: system_prompt_with_index(SYSTEM_ASSIST) }]
      awaiting_continue = false

      loop do
        $stdout.print(awaiting_continue ? "\ncontinue> " : "\nyou> ")
        $stdout.flush
        input = $stdin.gets&.strip
        break if input.nil?

        if awaiting_continue
          unless continue_request?(input)
            $stdout.puts "\nmodel> iteration limit reached; type #{CONTINUE_COMMAND} to resume the interrupted turn"
            next
          end

          result = @kernel.run(messages)
        else
          next if input.empty?

          if continue_request?(input)
            $stdout.puts "\nmodel> nothing to continue"
            next
          end

          messages << { role: "user", content: input }
          result = @kernel.run(messages)
        end

        emit_result(result)
        messages = result.conversation
        awaiting_continue = result.resumable?
      end

      $stdout.puts "\nbye."
    end

    def evolve_loop
      $stdout.puts banner("evolve")
      messages = [
        { role: "system", content: system_prompt_with_index(SYSTEM_EVOLVE) },
        { role: "user",   content: "Read your source files, identify improvements, implement them, and validate with rspec." }
      ]
      result = @kernel.run(messages, max_iterations: 20)
      emit_result(result)
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
      project_description = project_specific_description
      # Enable thinking mode by injecting the control token if THINKING_MODE is not "false"
      # This allows it to be ON by default, but explicitly DISABLEABLE via ENV.
      thinking_token = ENV["THINKING_MODE"] == "false" ? "" : "<|think|>\n"
      [thinking_token + base, rg_guidance, project_description, "Memories:\n#{index}"].compact.join("\n")
    end

    def emit_result(result)
      $stdout.puts result.output
      return unless result.resumable?

      $stdout.puts "iteration limit reached; type #{CONTINUE_COMMAND} to resume"
    end

    def continue_request?(input)
      input.empty? || input == CONTINUE_COMMAND
    end

    def project_specific_description
      return nil if skip_agent_description?

      path = File.join(Dir.pwd, AGENT_DESCRIPTION_FILE)
      return nil unless File.file?(path)

      content = File.read(path).strip
      return nil if content.empty?

      "Project specific description:\n#{content}"
    rescue StandardError
      nil
    end

    def skip_agent_description?
      value = ENV[SKIP_AGENT_DESCRIPTION_ENV]
      value == "1" || value&.casecmp?("true")
    end

    def rg_available?
      system("command -v rg", out: File::NULL, err: File::NULL)
    end

    def rg_guidance
      RG_GUIDANCE if rg_available?
    end
  end
end
