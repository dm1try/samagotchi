# frozen_string_literal: true

require "reline"

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
        description:<|"|>Run any shell command and see stdout, stderr, and exit code. Large output may be truncated to a head+tail preview with metadata.<|"|>,
        parameters:{
          command:{type:<|"|>string<|"|>, description:<|"|>The shell command to run<|"|>, required:true}
        }
      }<tool|>
    DECL

    TOOL_READ = <<~DECL.strip
      <|tool>declaration:read{
        description:<|"|>Read a file from disk. Large files may be truncated to a head+tail preview with metadata.<|"|>,
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
        description:<|"|>Read a memory entry from scoped memories. Scope is optional: if omitted, read falls back from project to system. Leave name blank to read indexes.<|"|>,
        parameters:{
          name:{type:<|"|>string<|"|>, description:<|"|>Memory entry name without .md extension; leave blank for indexes<|"|>},
          scope:{type:<|"|>string<|"|>, description:<|"|>Optional scope: project or system<|"|>}
        }
      }<tool|>
    DECL

    TOOL_MEMORY_WRITE = <<~DECL.strip
      <|tool>declaration:memory_write{
        description:<|"|>Write or update a memory entry in scoped memories. Scope is required: project or system.<|"|>,
        parameters:{
          name:{type:<|"|>string<|"|>, description:<|"|>Memory entry name without .md extension<|"|>, required:true},
          content:{type:<|"|>string<|"|>, description:<|"|>Markdown content to write<|"|>, required:true},
          scope:{type:<|"|>string<|"|>, description:<|"|>Scope to write into: project or system<|"|>, required:true}
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
        Project scope: memories/ (project-local)
        System scope:  ~/.config/samagotchi/memories/ (cross-project)
        memory_read accepts optional scope (project|system).
        memory_write requires explicit scope and entry name.
        Keep each scope's index.md updated when adding/updating entries.

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
        Project scope: memories/ (project-local)
        System scope:  ~/.config/samagotchi/memories/ (cross-project)
        memory_read accepts optional scope (project|system).
        memory_write requires explicit scope and entry name.
        Keep each scope's index.md updated when adding/updating entries.
        The current indexes are injected below for your reference.

      Workflow for adding a new tool:
        1. Write lib/samagotchi/tools/<name>.rb with self.name and self.call
        2. Require it in lib/samagotchi/kernel_loop.rb and add to TOOLS
        3. Write spec/tools/<name>_spec.rb
        4. Validate: <|tool_call>call:execute{command:<|"|>bundle exec rspec spec/tools/<name>_spec.rb --no-color<|"|>}<tool_call|>

      #{CONTEXT_STATUS_PROTOCOL}

      Begin by reading your source files and deciding what to add or improve.
    SYS

    def initialize(mode:, prompt: nil, client: nil, verbose: false, log_file: nil)
      @mode   = mode.to_sym
      @prompt = prompt
      @kernel = KernelLoop.new(client: client, verbose: verbose, log_file: log_file)
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
        input = read_input(awaiting_continue: awaiting_continue)
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
      project_index = read_memory_index("project")
      system_index = read_memory_index("system")
      project_description = project_specific_description
      # Enable thinking mode by injecting the control token if THINKING_MODE is not "false"
      # This allows it to be ON by default, but explicitly DISABLEABLE via ENV.
      thinking_token = ENV["THINKING_MODE"] == "false" ? "" : "<|think|>\n"
      memory_sections = [
        "Project memories:\n#{project_index}",
        "System memories:\n#{system_index}"
      ].join("\n\n")
      [thinking_token + base, rg_guidance, project_description, memory_sections].compact.join("\n")
    end

    def emit_result(result)
      emit_tool_activity(result)
      $stdout.puts result.output
      return unless result.resumable?

      $stdout.puts "iteration limit reached; type #{CONTINUE_COMMAND} to resume"
    end

    def emit_tool_activity(result)
      activities = result.respond_to?(:tool_activity) ? Array(result.tool_activity) : []
      activities.each do |activity|
        $stdout.puts format_tool_activity_line(activity)
      end
    end

    def format_tool_activity_line(activity)
      params = activity[:params].to_s.strip
      params_suffix = params.empty? ? "" : " #{paint(params, 90)}"
      status = activity[:status].to_s
      status_color = status == "ok" ? 32 : 31
      "#{paint('tool>', 36)} #{activity[:action]} (#{activity[:tool]}#{params_suffix}): #{paint(status, status_color)}"
    end

    def paint(text, code)
      return text unless color_output?

      "\e[#{code}m#{text}\e[0m"
    end

    def color_output?
      return false unless $stdout.tty?
      return false if ENV.key?("NO_COLOR")

      ENV.fetch("TERM", "") != "dumb"
    end

    def read_memory_index(scope)
      result = Tools::MemoryRead.call("", scope: scope)
      status = result.to_s.start_with?("Error:") ? "error" : "ok"
      activity = {
        action: "reading memory",
        tool: "memory_read",
        params: "name=\"\" scope=#{scope.inspect}",
        status: status
      }
      $stdout.puts format_tool_activity_line(activity)
      result
    end

    def read_input(awaiting_continue:)
      if awaiting_continue
        input = Reline.readline("continue> ", true)
        return nil if input.nil?

        return input.strip
      end

      # In multiline mode Enter submits, while Meta+Enter/Alt+Enter inserts a
      # newline on terminals that emit that distinct sequence (for example kitty).
      input = Reline.readmultiline("you> ", true) { true }
      return nil if input.nil?

      input.gsub(/\r\n?|\n\z/, "\n").strip
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
