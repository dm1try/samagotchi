# frozen_string_literal: true

require "json"
require "fileutils"
require "io/console"
require "reline"

require_relative "model_profile"
require_relative "kernel_loop"
require_relative "session"
require_relative "tools/memory"

module Samagotchi
  # Agent encapsulates the two operating modes of the harness.
  #
  # assist mode  — interactive REPL: user types, model responds, tools execute inline.
  # evolve mode  — autonomous: model reads its own source, extends itself, validates with rspec.
  class Agent
    AGENT_DESCRIPTION_FILE = "AGENT.md"
    PROMPT_HISTORY_ENV = "SAMAGOTCHI_HISTORY_FILE"
    XDG_STATE_HOME_ENV = "XDG_STATE_HOME"
    PROMPT_HISTORY_FILE = "history.json"
    PROMPT_HISTORY_STATE_DIR = "samagotchi"
    PROMPT_HISTORY_LIMIT = 20
    SKIP_AGENT_DESCRIPTION_ENV = "SAMAGOTCHI_SKIP_AGENT_MD"
    CONTINUE_COMMAND = "/continue"
    MODEL_COMMAND = "/model"
    MODELS_COMMAND = "/models"
    CONTINUE_PROMPT = "continue(yes/no/no_with_reason)> "
    THINKING_UI_ENV = "SAMAGOTCHI_THINKING_UI"
    THINKING_UI_SPINNER = "spinner"
    THINKING_UI_OFF = "off"
    THINKING_SPINNER_FRAMES = ["|", "/", "-", "\\"].freeze
    MEMORY_SPINNER_COLOR = "38;5;208"
    TOOL_SPINNER_COLOR = 32
    NETWORK_RETRY_SPINNER_COLOR = 31
    MEMORY_SPINNER_PREVIEW_LIMIT = 3
    MEMORY_STICKY_PREVIEW_LIMIT = 8
    THINKING_PREVIEW_WIDTH = 120
    THINKING_PREVIEW_LINES_ENV = "SAMAGOTCHI_THINKING_PREVIEW_LINES"
    THINKING_PREVIEW_LINES_DEFAULT = 1
    THINKING_PREVIEW_LINES_MAX = 3
    THINKING_TAIL_PREVIEW_BUFFER_LIMIT = 4096
    THINKING_TOOL_PREVIEW_LIMIT = 56
    THINKING_RENDER_MIN_INTERVAL = 0.08
    THINKING_RENDER_INTERVAL_ENV = "SAMAGOTCHI_THINKING_RENDER_INTERVAL"
    STATUS_LINE_ENV = "SAMAGOTCHI_STATUS_LINE"
    STATUS_LINE_ON = "on"
    STATUS_LINE_OFF = "off"
    STATUS_WIDTH_MODE_ENV = "SAMAGOTCHI_STATUS_WIDTH_MODE"
    STATUS_WIDTH_MODE_TERMINAL_CAP = "terminal_cap"
    STATUS_WIDTH_MODE_FIXED = "fixed"
    STATUS_FIXED_WIDTH_ENV = "SAMAGOTCHI_STATUS_FIXED_WIDTH"
    STATUS_MAX_WIDTH_ENV = "SAMAGOTCHI_STATUS_MAX_WIDTH"
    STATUS_MAX_WIDTH_DEFAULT = 160
    INTERRUPTED_SUMMARY_PROMPT_LIMIT = 600
    INTERRUPTED_SUMMARY_MODEL_LIMIT = 360
    INTERRUPTED_SUMMARY_PARAMS_LIMIT = 80
    INTERRUPTED_SUMMARY_TOOLS_LIMIT = 5
    AT_PATH_COMPLETION_PREFIX = "@"
    MEMORY_COMPLETION_PREFIX = "#"
    AT_PATH_COMPLETION_MAX_CANDIDATES = 200
    CANCEL_MONITOR_POLL_INTERVAL = 0.05
    CTRL_C_BYTE = "\u0003"

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
        description:<|"|>Read a file from disk. Large files may be truncated to a head+tail preview with metadata. Optionally pass start_line and end_line (1-based, inclusive) to read only a specific line range.<|"|>,
        parameters:{
          path:{type:<|"|>string<|"|>, description:<|"|>Path to the file<|"|>, required:true},
          start_line:{type:<|"|>integer<|"|>, description:<|"|>Optional start line (1-based, inclusive). Must be provided with end_line.<|"|>},
          end_line:{type:<|"|>integer<|"|>, description:<|"|>Optional end line (1-based, inclusive). Must be provided with start_line.<|"|>}
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
        description:<|"|>Edit an existing file. Mode 1 (default): replace an exact old_text block with new_text, where old_text must appear exactly once. Mode 2 (range): when start_line and end_line are provided, replace that whole line range with new_text.<|"|>,
        parameters:{
          path:{type:<|"|>string<|"|>, description:<|"|>File path<|"|>, required:true},
          old_text:{type:<|"|>string<|"|>, description:<|"|>Exact text to replace (required in exact-match mode)<|"|>},
          new_text:{type:<|"|>string<|"|>, description:<|"|>Replacement text (required)<|"|>, required:true},
          start_line:{type:<|"|>integer<|"|>, description:<|"|>Optional start line (1-based, inclusive) for range mode. Must be provided with end_line.<|"|>},
          end_line:{type:<|"|>integer<|"|>, description:<|"|>Optional end line (1-based, inclusive) for range mode. Must be provided with start_line.<|"|>}
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

    TOOL_TASK_CREATE = <<~DECL.strip
      <|tool>declaration:task_create{
        description:<|"|>Start a background task for a long-running shell command. Returns task id and output path for later inspection.<|"|>,
        parameters:{
          command:{type:<|"|>string<|"|>, description:<|"|>Shell command to run in the background<|"|>, required:true},
          cwd:{type:<|"|>string<|"|>, description:<|"|>Optional working directory (defaults to project root)<|"|>}
        }
      }<tool|>
    DECL

    TOOL_TASK_GET = <<~DECL.strip
      <|tool>declaration:task_get{
        description:<|"|>Get full metadata for a task by id. Use read on output_path to inspect command output.<|"|>,
        parameters:{
          id:{type:<|"|>string<|"|>, description:<|"|>Task id returned by task_create<|"|>, required:true}
        }
      }<tool|>
    DECL

    TOOL_TASK_LIST = <<~DECL.strip
      <|tool>declaration:task_list{
        description:<|"|>List all background tasks in the current workspace with current status.<|"|>,
        parameters:{}
      }<tool|>
    DECL

    TOOL_TASK_STOP = <<~DECL.strip
      <|tool>declaration:task_stop{
        description:<|"|>Stop a running background task by id.<|"|>,
        parameters:{
          id:{type:<|"|>string<|"|>, description:<|"|>Task id to stop<|"|>, required:true}
        }
      }<tool|>
    DECL

    TOOL_WEB_FETCH = <<~DECL.strip
      <|tool>declaration:web_fetch{
        description:<|"|>Fetch the content of a URL (HTML or text) and return cleaned text. Handles HTML by stripping scripts/styles and extracting visible text. Returns error messages for invalid URLs or HTTP errors.<|"|>,
        parameters:{
          url:{type:<|"|>string<|"|>, description:<|"|>The URL to fetch<|"|>, required:true}
        }
      }<tool|>
    DECL

    # ── Qwen 3.6 tool declarations (JSON format) ──────────────────────────────

    QWEN_TOOLS_JSON = [
      {
        name: "execute",
        description: "Run any shell command and see stdout, stderr, and exit code. Large output may be truncated to a head+tail preview with metadata.",
        parameters: {
          type: "object",
          properties: {
            command: {
              type: "string",
              description: "The shell command to run"
            }
          },
          required: ["command"]
        }
      },
      {
        name: "read",
        description: "Read a file from disk. Large files may be truncated to a head+tail preview with metadata. Optionally pass start_line and end_line (1-based, inclusive) to read only a specific line range.",
        parameters: {
          type: "object",
          properties: {
            path: {
              type: "string",
              description: "Path to the file"
            },
            start_line: {
              type: "integer",
              description: "Optional start line (1-based, inclusive). Must be provided with end_line."
            },
            end_line: {
              type: "integer",
              description: "Optional end line (1-based, inclusive). Must be provided with start_line."
            }
          },
          required: ["path"]
        }
      },
      {
        name: "write",
        description: "Write content to a file (parent directories are created automatically)",
        parameters: {
          type: "object",
          properties: {
            path: {
              type: "string",
              description: "Destination file path"
            },
            content: {
              type: "string",
              description: "Content to write to the file"
            }
          },
          required: ["path", "content"]
        }
      },
      {
        name: "edit",
        description: "Edit an existing file. Mode 1 (default): replace an exact old_text block with new_text, where old_text must appear exactly once. Mode 2 (range): when start_line and end_line are provided, replace that whole line range with new_text.",
        parameters: {
          type: "object",
          properties: {
            path: {
              type: "string",
              description: "File path"
            },
            old_text: {
              type: "string",
              description: "Exact text to replace (required in exact-match mode)"
            },
            new_text: {
              type: "string",
              description: "Replacement text"
            },
            start_line: {
              type: "integer",
              description: "Optional start line (1-based, inclusive) for range mode. Must be provided with end_line."
            },
            end_line: {
              type: "integer",
              description: "Optional end line (1-based, inclusive) for range mode. Must be provided with start_line."
            }
          },
          required: ["path", "new_text"]
        }
      },
      {
        name: "memory_read",
        description: "Read a memory entry from scoped memories. Scope is optional: if omitted, read falls back from project to system. Leave name blank to read indexes.",
        parameters: {
          type: "object",
          properties: {
            name: {
              type: "string",
              description: "Memory entry name without .md extension; leave blank for indexes"
            },
            scope: {
              type: "string",
              description: "Optional scope: project or system"
            }
          }
        }
      },
      {
        name: "memory_write",
        description: "Write or update a memory entry in scoped memories. Scope is required: project or system.",
        parameters: {
          type: "object",
          properties: {
            name: {
              type: "string",
              description: "Memory entry name without .md extension"
            },
            content: {
              type: "string",
              description: "Markdown content to write"
            },
            scope: {
              type: "string",
              description: "Scope to write into: project or system"
            }
          },
          required: ["name", "content", "scope"]
        }
      },
      {
        name: "task_create",
        description: "Start a background task for a long-running shell command. Returns task id and output path for later inspection.",
        parameters: {
          type: "object",
          properties: {
            command: {
              type: "string",
              description: "Shell command to run in the background"
            },
            cwd: {
              type: "string",
              description: "Optional working directory (defaults to project root)"
            }
          },
          required: ["command"]
        }
      },
      {
        name: "task_get",
        description: "Get full metadata for a task by id. Use read on output_path to inspect command output.",
        parameters: {
          type: "object",
          properties: {
            id: {
              type: "string",
              description: "Task id returned by task_create"
            }
          },
          required: ["id"]
        }
      },
      {
        name: "task_list",
        description: "List all background tasks in the current workspace with current status.",
        parameters: {
          type: "object",
          properties: {}
        }
      },
      {
        name: "task_stop",
        description: "Stop a running background task by id.",
        parameters: {
          type: "object",
          properties: {
            id: {
              type: "string",
              description: "Task id to stop"
            }
          },
          required: ["id"]
        }
      },
      {
        name: "web_fetch",
        description: "Fetch the content of a URL (HTML or text) and return cleaned text. Handles HTML by stripping scripts/styles and extracting visible text. Returns error messages for invalid URLs or HTTP errors.",
        parameters: {
          type: "object",
          properties: {
            url: {
              type: "string",
              description: "The URL to fetch"
            }
          },
          required: ["url"]
        }
      }
    ].freeze

    TOOL_CALL_HINT = 'To call a tool, emit: <|tool_call>call:NAME{param:<|"|>value<|"|>}<tool_call|>. CRITICAL: check the tool declaration for the exact parameter names and required fields!'
    QWEN_TOOL_CALL_HINT = <<~HINT
      To call a tool, emit XML in this exact shape:
      <tool_call>
      <function=NAME>
      <parameter=KEY>
      VALUE
      </parameter>
      </function>
      </tool_call>

      Required parameters must be present and use exact names from the tool declaration.
      You may include optional natural-language reasoning before the <tool_call> block, but never after it.
      If you call a function, end your response at </tool_call> with no suffix.
      For write and memory_write, preserve content bytes exactly as provided by the user (no reformatting, no markdown normalization, no heading level changes).
    HINT
    RG_GUIDANCE = "For fast repository/text search, prefer `rg` (ripgrep) over `grep` when exploring files or text."
    SMALL_CONTEXT_PROTOCOL = <<~PROTOCOL
      Small-context retrieval protocol:
        Default to targeted context before full-file reads.
        Retrieval order:
          1. If the user provides file:line (for example, spec/agent_spec.rb:130), inspect that location first.
          2. Use execute with rg/nl/sed to find the smallest relevant snippet.
          3. Read a full file only when targeted snippet extraction is insufficient.
        Avoid broad reads early in debugging; gather just enough context to decide the next step.
    PROTOCOL
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
      You are Chi (pronounced "chee"), the friendly name for the Samagotchi assistant harness. You have access to the following tools:

      #{TOOL_EXECUTE}
      #{TOOL_READ}
      #{TOOL_WRITE}
      #{TOOL_EDIT}
      #{TOOL_MEMORY_READ}
      #{TOOL_MEMORY_WRITE}
      #{TOOL_TASK_CREATE}
      #{TOOL_TASK_GET}
      #{TOOL_TASK_LIST}
      #{TOOL_TASK_STOP}
      #{TOOL_WEB_FETCH}

      #{TOOL_CALL_HINT}
      You may make multiple tool calls. After seeing tool results, continue reasoning or answer the user.

      #{SMALL_CONTEXT_PROTOCOL}

      Editing workflow:
        1. Read the target file or line range immediately before calling edit.
        2. For exact-match mode, copy old_text verbatim from that read output; do not reconstruct it from memory.
        3. Prefer the smallest unique block (about 3-15 lines) that contains the change.
        4. For large files, prefer range mode (start_line/end_line) to minimize context.
        5. If exact-match mode reports not found or multiple matches, read again and retry with a smaller or more unique block.
        6. Use write for full-file rewrites or creating new files.

      Memory convention:
        Project scope: memories/ (project-local)
        System scope:  ~/.config/samagotchi/memories/ (cross-project)
        memory_read accepts optional scope (project|system).
        memory_write requires explicit scope and entry name.
        User prompts may contain memory shorthand like #entry_name.
        Treat #entry_name as a memory reference, not as a file path.
        If shorthand includes a scope prefix, such as #project/entry_name or #system/entry_name,
        preserve that scope when reading the memory.
        Keep each scope's index.md updated when adding/updating entries.

      #{CONTEXT_STATUS_PROTOCOL}
    SYS

    SYSTEM_EVOLVE = <<~SYS
      You are Chi (pronounced "chee"), the friendly name for the Samagotchi self-evolving Ruby agent harness running on Gemma 4 via llama.cpp.
      Your goal: read your own source, decide what to improve or extend, implement it, and validate with RSpec.

      Available tools:

      #{TOOL_EXECUTE}
      #{TOOL_READ}
      #{TOOL_WRITE}
      #{TOOL_EDIT}
      #{TOOL_MEMORY_READ}
      #{TOOL_MEMORY_WRITE}
      #{TOOL_TASK_CREATE}
      #{TOOL_TASK_GET}
      #{TOOL_TASK_LIST}
      #{TOOL_TASK_STOP}
      #{TOOL_WEB_FETCH}

      #{TOOL_CALL_HINT}
      #{SMALL_CONTEXT_PROTOCOL}

      Editing workflow:
        1. Read the target file or line range immediately before calling edit.
        2. For exact-match mode, copy old_text verbatim from that read output; do not reconstruct it from memory.
        3. Prefer the smallest unique block (about 3-15 lines) that contains the change.
        4. For large files, prefer range mode (start_line/end_line) to minimize context.
        5. If exact-match mode reports not found or multiple matches, read again and retry with a smaller or more unique block.
        6. Use write for full-file rewrites or creating new files.

      Source layout:
        bin/chi                        CLI entry point
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

    def self.system_prompt_for(profile, mode: :assist)
      profile = ModelProfile.normalize(profile) unless profile.is_a?(ModelProfile)
      case mode.to_sym
      when :assist   then new(mode: :assist, profile: profile).send(:assist_system_prompt)
      when :evolve   then new(mode: :evolve, profile: profile).send(:evolve_system_prompt)
      else raise ArgumentError, "Unknown mode: #{mode}"
      end
    end

    def initialize(mode:, prompt: nil, client: nil, verbose: false, log_file: nil, profile: nil, session_id: nil, no_interrupt: false)
      @mode    = mode.to_sym
      @prompt  = prompt
      @base_model_name = ModelProfile.required_model_name
      @session_model_name = @base_model_name
      @client = client || Client.new
      @profile = profile ? ModelProfile.normalize(profile) : ModelProfile.from_model_name(@session_model_name)
      @kernel  = KernelLoop.new(client: @client, verbose: verbose, log_file: log_file, profile: @profile, no_interrupt: no_interrupt)
      @resume_session = session_id ? Session.load(session_id) : nil
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

    # Generate profile-aware tool declarations
    def tool_declarations
      case @profile.name
      when "qwen36"
        "<tools>\n#{JSON.pretty_generate(QWEN_TOOLS_JSON)}\n</tools>"
      else
        # Gemma 4 format
        [
          TOOL_EXECUTE,
          TOOL_READ,
          TOOL_WRITE,
          TOOL_EDIT,
          TOOL_MEMORY_READ,
          TOOL_MEMORY_WRITE,
          TOOL_TASK_CREATE,
          TOOL_TASK_GET,
          TOOL_TASK_LIST,
          TOOL_TASK_STOP,
          TOOL_WEB_FETCH
        ].join("\n")
      end
    end

    # Generate profile-aware tool calling hint
    def tool_call_hint
      case @profile.name
      when "qwen36"
        QWEN_TOOL_CALL_HINT
      else
        TOOL_CALL_HINT
      end
    end

    # Generate profile-aware assist system prompt
    def assist_system_prompt
      declarations = tool_declarations
      hint = tool_call_hint

      <<~SYS
        You are Chi (pronounced "chee"), the friendly name for the Samagotchi assistant harness. You have access to the following tools:

        #{declarations}

        #{hint}
        You may make multiple tool calls. After seeing tool results, continue reasoning or answer the user.

        #{SMALL_CONTEXT_PROTOCOL}

        Editing workflow:
          1. Read the target file or line range immediately before calling edit.
          2. For exact-match mode, copy old_text verbatim from that read output; do not reconstruct it from memory.
          3. Prefer the smallest unique block (about 3-15 lines) that contains the change.
          4. For large files, prefer range mode (start_line/end_line) to minimize context.
          5. If exact-match mode reports not found or multiple matches, read again and retry with a smaller or more unique block.
          6. Use write for full-file rewrites or creating new files.

        Memory convention:
          Project scope: memories/ (project-local)
          System scope:  ~/.config/samagotchi/memories/ (cross-project)
          memory_read accepts optional scope (project|system).
          memory_write requires explicit scope and entry name.
          User prompts may contain memory shorthand like #entry_name.
          Treat #entry_name as a memory reference, not as a file path.
          If shorthand includes a scope prefix, such as #project/entry_name or #system/entry_name,
          preserve that scope when reading the memory.
          Keep each scope's index.md updated when adding/updating entries.

        #{CONTEXT_STATUS_PROTOCOL}
      SYS
    end

    # Generate profile-aware evolve system prompt
    def evolve_system_prompt
      declarations = tool_declarations
      hint = tool_call_hint

      <<~SYS
        You are Chi (pronounced "chee"), the friendly name for the Samagotchi self-evolving Ruby agent harness running on #{@profile.name.upcase} via llama.cpp.
        Your goal: read your own source, decide what to improve or extend, implement it, and validate with RSpec.

        Available tools:

        #{declarations}

        #{hint}
        #{SMALL_CONTEXT_PROTOCOL}

        Editing workflow:
          1. Read the target file or line range immediately before calling edit.
          2. For exact-match mode, copy old_text verbatim from that read output; do not reconstruct it from memory.
          3. Prefer the smallest unique block (about 3-15 lines) that contains the change.
          4. For large files, prefer range mode (start_line/end_line) to minimize context.
          5. If exact-match mode reports not found or multiple matches, read again and retry with a smaller or more unique block.
          6. Use write for full-file rewrites or creating new files.

        Source layout:
          bin/chi                        CLI entry point
          lib/samagotchi/prompt.rb       Prompt formatter (multi-profile)
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
          4. Validate with RSpec

        #{CONTEXT_STATUS_PROTOCOL}

        Begin by reading your source files and deciding what to add or improve.
      SYS
    end

    def prompt_mode
      messages = [
        { role: "system", content: system_prompt_with_index(assist_system_prompt) },
        { role: "user",   content: @prompt }
      ]
      max_iter = @no_interrupt ? 1000 : 10
      result = run_kernel_with_thinking_feedback(messages, max_iterations: max_iter)
      emit_result(result)
    end

    def assist_loop
      load_persistent_history

      if @resume_session
        session = @resume_session
        messages = session.messages.dup
        if messages.empty?
          messages = [{ role: "system", content: system_prompt_with_index(assist_system_prompt) }]
        else
          messages[0] = { role: "system", content: system_prompt_with_index(assist_system_prompt) }
        end
        $stdout.puts "Resumed session: #{session.id}"
      else
        messages = [{ role: "system", content: system_prompt_with_index(assist_system_prompt) }]
        session = Session.new_session(mode: @mode.to_s, model_name: @session_model_name, working_directory: Dir.pwd)
        $stdout.puts "Session: #{session.id}"
      end

      awaiting_continue = false
      interrupted_turn_checkpoint = nil
      interrupted_turn_context = nil

      loop do
        input = read_input(awaiting_continue: awaiting_continue)
        break if input.nil?
        break if exit_command?(input)
        continue_flow = awaiting_continue

        if awaiting_continue
          decision, reason = continue_decision(input)

          case decision
          when :resume
            begin
              result = run_kernel_with_thinking_feedback(messages)
            rescue Client::RetryExhausted => e
              $stdout.puts "\nmodel> network error after #{e.attempts} attempts; continue prompt preserved"
              awaiting_continue = true
              interrupted_turn_checkpoint = nil unless awaiting_continue
              next
            end
          when :abort
            messages = clone_messages(interrupted_turn_checkpoint) if interrupted_turn_checkpoint
            interrupted_turn_checkpoint = nil
            interrupted_turn_context = nil
            awaiting_continue = false
            session.messages = messages
            session.model_name = @session_model_name
            session.save
            $stdout.puts "\nmodel> interrupted turn cancelled; enter your next prompt"
            next
          when :abort_with_reason
            messages = clone_messages(interrupted_turn_checkpoint) if interrupted_turn_checkpoint
            interrupted_turn_checkpoint = nil
            messages << {
              role: "user",
              content: interrupted_turn_reason_message(reason: reason, context: interrupted_turn_context)
            }
            interrupted_turn_context = nil
            awaiting_continue = false
            session.messages = messages
            session.model_name = @session_model_name
            session.save
            $stdout.puts "\nmodel> interrupted turn cancelled; noted your explanation"
            next
          else
            $stdout.puts "\nmodel> answer yes, no, or no, <reason>"
            next
          end
        else
          next if input.empty?

          if continue_request?(input)
            $stdout.puts "\nmodel> nothing to continue"
            next
          end

          if models_command?(input)
            $stdout.puts "\nmodel> #{handle_models_command}"
            next
          end

          if model_command?(input)
            $stdout.puts "\nmodel> #{handle_model_command(input)}"
            next
          end

          interrupted_turn_checkpoint = clone_messages(messages)
          messages << { role: "user", content: normalize_model_input(input) }
          persist_recent_history(input)
          begin
            result = run_kernel_with_thinking_feedback(messages)
          rescue Client::RetryExhausted => e
            messages = clone_messages(interrupted_turn_checkpoint) if interrupted_turn_checkpoint
            awaiting_continue = false
            queue_input_prefill(input)
            $stdout.puts "\nmodel> network error after #{e.attempts} attempts; prompt restored for retry"
            interrupted_turn_checkpoint = nil unless awaiting_continue
            next
          end
        end

        if result.respond_to?(:canceled?) && result.canceled?
          if continue_flow
            awaiting_continue = true
          else
            messages = clone_messages(interrupted_turn_checkpoint) if interrupted_turn_checkpoint
            awaiting_continue = false
          end
          interrupted_turn_checkpoint = nil unless awaiting_continue
          next
        end

        emit_result(result)

        messages = result.conversation
        awaiting_continue = result.resumable?
        interrupted_turn_context = if awaiting_continue
                                     build_interrupted_turn_context(
                                       result: result,
                                       checkpoint: interrupted_turn_checkpoint,
                                       conversation: messages
                                     )
                                   else
                                     nil
                                   end
        interrupted_turn_checkpoint = nil unless awaiting_continue

        session.messages = messages
        session.model_name = @session_model_name
        session.save
      end

      $stdout.puts "\nbye."
    end

    def evolve_loop
      messages = [
        { role: "system", content: system_prompt_with_index(evolve_system_prompt) },
        { role: "user",   content: "Read your source files, identify improvements, implement them, and validate with rspec." }
      ]
      result = run_kernel_with_thinking_feedback(messages, max_iterations: 20)
      emit_result(result)
    end

    def status_server_segment
      host = ENV.fetch("LLAMA_HOST", "localhost")
      return "" if ["localhost", "127.0.0.1"].include?(host)

      port = ENV.fetch("LLAMA_PORT", "8080")
      "server=#{host}:#{port}"
    end

    # Appends the current memory index to the base system prompt so the agent
    # is always aware of stored memories without needing to call a tool first.
    def system_prompt_with_index(base)
      project_index = read_memory_index("project")
      system_index = read_memory_index("system")
      project_description = project_specific_description
      # Only inject Gemma thought control tokens for Gemma profiles.
      # Qwen uses a different reasoning format and should not receive <|think|>.
      thinking_token = if @profile.name == "gemma4" && ENV["THINKING_MODE"] != "false"
                         "<|think|>\n"
                       else
                         ""
                       end
      memory_sections = [
        "Project memories:\n#{project_index}",
        "System memories:\n#{system_index}"
      ].join("\n\n")
      [thinking_token + base, rg_guidance, project_description, memory_sections].compact.join("\n")
    end

    def emit_result(result)
      finish_thinking_spinner
      capture_context_status_from_result(result)
      emit_tool_activity(result)
      emit_active_memories_line
      $stdout.puts result.output
      return unless result.resumable?

      $stdout.puts "iteration limit reached"
    end

    def emit_active_memories_line
      lines = sticky_status_lines
      return if lines.empty?

      lines.each { |line| $stdout.puts line }
    end

    def emit_tool_activity(result)
      activities = result.respond_to?(:tool_activity) ? Array(result.tool_activity) : []
      activities.each do |activity|
        next if consume_streamed_tool_activity(activity)

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
      Tools::MemoryRead.call("", scope: scope)
    end

    def read_input(awaiting_continue:)
      emit_idle_status_line

      if awaiting_continue
        prompt = color_output? ? paint(CONTINUE_PROMPT, 33) : CONTINUE_PROMPT
        input = Reline.readline(prompt, true)
        return nil if input.nil?

        return input.strip
      end

      # In multiline mode Enter submits, while Meta+Enter/Alt+Enter inserts a
      # newline on terminals that emit that distinct sequence (for example kitty).
      input = with_scoped_at_path_completion do
        with_next_input_prefill do
          Reline.readmultiline(paint("> ", 92), true) { true }
        end
      end
      return nil if input.nil?

      input.gsub(/\r\n?|\n\z/, "\n").strip
    rescue Interrupt
      nil
    end

    def with_scoped_at_path_completion
      previous_completion_proc = Reline.completion_proc
      previous_autocompletion = Reline.autocompletion
      Reline.autocompletion = true
      Reline.completion_proc = method(:assist_path_completion_candidates).to_proc
      yield
    ensure
      Reline.completion_proc = previous_completion_proc
      Reline.autocompletion = previous_autocompletion
    end

    def assist_path_completion_candidates(word)
      token = word.to_s
      return [] if token.empty?

      if token.start_with?(AT_PATH_COMPLETION_PREFIX)
        path_fragment = token.delete_prefix(AT_PATH_COMPLETION_PREFIX)
        return build_project_path_completion_candidates(path_fragment)
      end

      if token.start_with?(MEMORY_COMPLETION_PREFIX)
        memory_fragment = token.delete_prefix(MEMORY_COMPLETION_PREFIX)
        return build_memory_completion_candidates(memory_fragment)
      end

      []
    end

    def build_project_path_completion_candidates(path_fragment)
      fragment = path_fragment.to_s.tr("\\", "/")
      return [] if fragment.start_with?("/")
      return [] if fragment.split("/").include?("..")

      dir_part = ""
      entry_prefix = fragment

      if fragment.include?("/")
        dir_part = fragment.sub(%r{[^/]*\z}, "")
        entry_prefix = fragment.split("/").last.to_s
      end

      base_dir = dir_part.empty? ? Dir.pwd : File.expand_path(dir_part, Dir.pwd)
      return [] unless path_within_cwd?(base_dir)
      return [] unless File.directory?(base_dir)

      entries = Dir.children(base_dir).sort
      entries.reject! { |entry| entry.start_with?(".") } unless entry_prefix.start_with?(".")
      matches = entries.select { |entry| entry.start_with?(entry_prefix) }

      matches.first(AT_PATH_COMPLETION_MAX_CANDIDATES).map do |entry|
        relative_path = "#{dir_part}#{entry}".tr("\\", "/")
        absolute_path = File.join(base_dir, entry)
        relative_path = "#{relative_path}/" if File.directory?(absolute_path)
        "#{AT_PATH_COMPLETION_PREFIX}#{relative_path}"
      end
    rescue StandardError
      []
    end

    def path_within_cwd?(path)
      expanded = File.expand_path(path)
      cwd = Dir.pwd
      expanded == cwd || expanded.start_with?("#{cwd}#{File::SEPARATOR}")
    end

    def build_memory_completion_candidates(memory_fragment)
      fragment = memory_fragment.to_s.strip.tr("\\", "/")
      candidates = memory_completion_entries
      return candidates.map { |entry| entry[:token] } if fragment.empty?

      candidates.filter_map do |entry|
        entry[:token] if entry[:token].delete_prefix(MEMORY_COMPLETION_PREFIX).start_with?(fragment)
      end
    end

    def memory_completion_entries
      grouped = Hash.new { |hash, key| hash[key] = [] }

      each_memory_completion_entry do |scope, name|
        grouped[name] << scope unless grouped[name].include?(scope)
      end

      grouped.sort_by do |name, scopes|
        [memory_scope_sort_key(scopes.min_by { |scope| memory_scope_sort_key(scope) }), name]
      end.flat_map do |name, scopes|
        scopes = scopes.sort_by { |scope| [memory_scope_sort_key(scope), scope] }
        if scopes.length == 1
          [{ token: "#{MEMORY_COMPLETION_PREFIX}#{name}", scope: scopes.first, name: name }]
        else
          scopes.map do |scope|
            { token: "#{MEMORY_COMPLETION_PREFIX}#{scope}/#{name}", scope: scope, name: name }
          end
        end
      end
    end

    def memory_scope_sort_key(scope)
      scope == "project" ? 0 : 1
    end

    def each_memory_completion_entry
      memory_completion_dirs.each do |scope, dir|
        next unless File.directory?(dir)

        Dir.glob(File.join(dir, "*.md")).sort.each do |path|
          name = File.basename(path, ".md")
          next if name.empty? || name == Tools::MEMORY_INDEX

          yield scope, name
        end
      end
    rescue StandardError
      []
    end

    def memory_completion_dirs
      {
        "project" => File.expand_path(Tools::PROJECT_MEMORIES_DIR, Dir.pwd),
        "system" => File.expand_path(Tools::SYSTEM_MEMORIES_DIR)
      }
    end

    def normalize_model_input(input)
      input.to_s.gsub(/(^|[^\w\/])#((?:project|system)\/)?([a-zA-Z0-9][a-zA-Z0-9_-]*)/) do
        prefix = Regexp.last_match(1)
        scoped = Regexp.last_match(2).to_s
        name = Regexp.last_match(3)
        scope = scoped.delete_suffix("/")
        normalized = if scope.empty?
                       "memory \"#{name}\""
                     else
                       "memory \"#{name}\" in #{scope} scope"
                     end
        "#{prefix}#{normalized}"
      end
    end

    def history_file_path
      explicit = ENV[PROMPT_HISTORY_ENV].to_s.strip
      return explicit unless explicit.empty?

      File.join(xdg_state_home, PROMPT_HISTORY_STATE_DIR, PROMPT_HISTORY_FILE)
    end

    def xdg_state_home
      configured = ENV[XDG_STATE_HOME_ENV].to_s.strip
      return configured unless configured.empty?

      File.join(Dir.home, ".local", "state")
    end

    def load_persistent_history
      entries = load_history_entries_from_disk
      entries.last(PROMPT_HISTORY_LIMIT).each { |entry| Reline::HISTORY << entry }
    rescue StandardError
      nil
    end

    def persist_recent_history(input)
      entries = normalize_history_entries(load_history_entries_from_disk)
      entries << input
      trimmed_entries = entries.last(PROMPT_HISTORY_LIMIT)
      path = history_file_path
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(trimmed_entries) + "\n")
    rescue StandardError
      nil
    end

    def load_history_entries_from_disk
      path = history_file_path
      return [] unless File.file?(path)

      raw = File.read(path)
      parsed = JSON.parse(raw)
      normalize_history_entries(parsed)
    rescue JSON::ParserError
      normalize_history_entries(raw.to_s.lines.map(&:chomp))
    rescue StandardError
      []
    end

    def normalize_history_entries(entries)
      Array(entries).map { |entry| entry.to_s.gsub(/\r\n?/, "\n").strip }.reject(&:empty?)
    end

    def continue_request?(input)
      input == CONTINUE_COMMAND
    end

    def model_command?(input)
      input.to_s.strip.match?(/\A\/model(?:\s+.*)?\z/)
    end

    def models_command?(input)
      input.to_s.strip == MODELS_COMMAND
    end

    def handle_model_command(input)
      suffix = input.to_s.strip.delete_prefix(MODEL_COMMAND).strip
      if suffix.empty?
        return "runtime model: #{current_model_label} (profile=#{@profile.name})"
      end

      lowered = suffix.downcase
      if ["clear", "default", "none", "off"].include?(lowered)
        apply_runtime_model!(@base_model_name)
        return "runtime model reset to #{@session_model_name} (profile=#{@profile.name})"
      end

      apply_runtime_model!(suffix)
      "runtime model set to #{@session_model_name} (profile=#{@profile.name})"
    end

    def current_model_label
      @session_model_name
    end

    def handle_models_command
      models = Array(@client.list_models)
      return "no models discovered" if models.empty?

      models.map do |entry|
        identifier = entry["id"] || entry[:id] || "unknown"
        status = entry["status"] || entry[:status]
        status.to_s.empty? ? identifier : "#{identifier} (#{status})"
      end.join("\n")
    rescue RetryExhausted => e
      "network error after #{e.attempts} attempts while listing models"
    rescue StandardError => e
      "unable to list models: #{e.message}"
    end

    def apply_runtime_model!(model_name)
      resolved_model_name = ModelProfile.required_model_name(model_name)
      @session_model_name = resolved_model_name
      @profile = ModelProfile.from_model_name(resolved_model_name)
      @kernel.sync_profile_from_model!(resolved_model_name)
    end

    def exit_command?(input)
      normalized = input.to_s.strip.downcase
      normalized == "exit" || normalized == "/exit"
    end

    def continue_decision(input)
      normalized = input.to_s.strip
      return [:resume, nil] if normalized.empty?

      lowered = normalized.downcase
      return [:resume, nil] if lowered == CONTINUE_COMMAND || lowered == "yes" || lowered == "y"
      return [:abort, nil] if lowered == "no" || lowered == "n"

      reason_match = normalized.match(/\A(?:no|n)\s*[,:\-]\s*(.+)\z/i)
      if reason_match
        reason = reason_match[1].to_s.strip
        return [:abort, nil] if reason.empty?

        return [:abort_with_reason, reason]
      end

      [:invalid, nil]
    end

    def clone_messages(messages)
      Array(messages).map(&:dup)
    end

    def build_interrupted_turn_context(result:, checkpoint:, conversation:)
      interrupted_messages = extract_interrupted_turn_messages(checkpoint: checkpoint, conversation: conversation)
      {
        original_prompt: summarized_interrupted_prompt(interrupted_messages),
        tool_trace: summarized_interrupted_tool_trace(result),
        last_model_intent: summarized_interrupted_model_excerpt(interrupted_messages)
      }
    end

    def extract_interrupted_turn_messages(checkpoint:, conversation:)
      checkpoint_messages = Array(checkpoint)
      conversation_messages = Array(conversation)
      return [] if checkpoint_messages.empty? || conversation_messages.length < checkpoint_messages.length
      return [] unless conversation_messages.first(checkpoint_messages.length) == checkpoint_messages

      conversation_messages[checkpoint_messages.length..] || []
    end

    def summarized_interrupted_prompt(messages)
      prompt = Array(messages).find { |message| message[:role] == "user" }
      preview_text(prompt && prompt[:content], INTERRUPTED_SUMMARY_PROMPT_LIMIT)
    end

    def summarized_interrupted_tool_trace(result)
      activities = if result.respond_to?(:tool_activity)
                     Array(result.tool_activity)
                   else
                     []
                   end
      return [] if activities.empty?

      activities.last(INTERRUPTED_SUMMARY_TOOLS_LIMIT).map do |activity|
        tool = activity[:tool].to_s.strip
        status = activity[:status].to_s.strip
        params = preview_text(activity[:params], INTERRUPTED_SUMMARY_PARAMS_LIMIT)
        parts = [tool]
        parts << "status=#{status}" unless status.empty?
        parts << "params=#{params}" unless params.empty?
        parts.join(" ")
      end
    end

    def summarized_interrupted_model_excerpt(messages)
      model_message = Array(messages).reverse.find { |message| message[:role] == "model" }
      preview_text(model_message && model_message[:content], INTERRUPTED_SUMMARY_MODEL_LIMIT)
    end

    def interrupted_turn_reason_message(reason:, context:)
      lines = ["I chose not to continue the interrupted turn because: #{reason}"]
      lines << ""
      lines << "Interrupted turn summary:"
      original_prompt = context && context[:original_prompt]
      lines << "- original_prompt: #{original_prompt.to_s.empty? ? "(unavailable)" : original_prompt}"

      tool_trace = context ? Array(context[:tool_trace]) : []
      if tool_trace.empty?
        lines << "- interrupted_tools: (none)"
      else
        lines << "- interrupted_tools: #{tool_trace.join("; ")}"
      end

      model_intent = context && context[:last_model_intent]
      lines << "- last_model_intent: #{model_intent.to_s.empty? ? "(unavailable)" : model_intent}"
      lines << ""
      lines << "Please keep the original prompt context. If my next message does not provide a clear replacement request, ask what we should do instead."
      lines.join("\n")
    end

    def preview_text(text, limit)
      normalized = text.to_s.gsub(/\s+/, " ").strip
      return "" if normalized.empty?
      return normalized if normalized.length <= limit

      normalized[0, limit].rstrip + "..."
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

    def run_kernel_with_thinking_feedback(messages, max_iterations: 10)
      cancellation_controller = Client::CancellationController.new
      @active_cancel_controller = cancellation_controller
      reset_streamed_tool_activity_counts
      clear_retry_spinner_status
      reset_thinking_memory_notification
      reset_thinking_memory_names
      reset_thinking_tool_notification
      result = @kernel.run(
        messages,
        max_iterations: max_iterations,
        on_stream_event: method(:handle_stream_event),
        cancel_controller: cancellation_controller,
        model_name: @session_model_name
      )
      emit_cancellation_notice(result)
      result
    rescue Interrupt
      cancellation_controller&.cancel!(:ctrl_c)
      result = cancelled_result_from(messages, reason: :ctrl_c)
      emit_cancellation_notice(result)
      result
    ensure
      stop_cancel_hotkey_monitor
      @active_cancel_controller = nil
      finish_thinking_spinner
    end

    def handle_stream_event(event)
      case event[:type]
      when :generation_started
        start_cancel_hotkey_monitor(@active_cancel_controller)
        clear_retry_spinner_status
        @latest_server_context_status = nil
        reset_thinking_tail_preview
        start_thinking_spinner
      when :generation_retrying
        set_retry_spinner_status(event)
        refresh_thinking_spinner_status
      when :generation_chunk
        clear_retry_spinner_status if retry_spinner_status_active?
        capture_server_context_status_from_payload(event[:payload])
        capture_thinking_tail_chunk(event[:content])
        tick_thinking_spinner
      when :tool_call_started
        clear_retry_spinner_status
        memory_loaded = capture_memory_tool_call(event)
        capture_thinking_tool_call(event) if memory_loaded
        refresh_thinking_spinner_status
      when :tool_call_completed
        clear_retry_spinner_status
        emit_streamed_tool_activity(event[:activity])
      when :generation_completed
        stop_cancel_hotkey_monitor
        clear_retry_spinner_status
        reset_thinking_tail_preview
        finish_thinking_spinner
      when :generation_cancelled
        stop_cancel_hotkey_monitor
        clear_retry_spinner_status
        reset_thinking_tail_preview
        finish_thinking_spinner
      when :tool_dispatch_started
        stop_cancel_hotkey_monitor
        clear_retry_spinner_status
        reset_thinking_tail_preview
        finish_thinking_spinner
      end
    end

    def emit_streamed_tool_activity(activity)
      return if activity.nil?

      track_streamed_tool_activity(activity)
      $stdout.puts format_tool_activity_line(activity)
    end

    def reset_streamed_tool_activity_counts
      @streamed_tool_activity_counts = Hash.new(0)
    end

    def track_streamed_tool_activity(activity)
      @streamed_tool_activity_counts ||= Hash.new(0)
      key = tool_activity_key(activity)
      @streamed_tool_activity_counts[key] += 1
    end

    def consume_streamed_tool_activity(activity)
      @streamed_tool_activity_counts ||= Hash.new(0)
      key = tool_activity_key(activity)
      count = @streamed_tool_activity_counts[key]
      return false unless count.positive?

      @streamed_tool_activity_counts[key] = count - 1
      true
    end

    def tool_activity_key(activity)
      [activity[:action], activity[:tool], activity[:params], activity[:status]].map(&:to_s).join("|")
    end

    def emit_cancellation_notice(result)
      return unless result.respond_to?(:canceled?) && result.canceled?

      reason = result.respond_to?(:cancellation_reason) ? result.cancellation_reason : nil
      label = cancellation_reason_label(reason)
      $stdout.puts "\nmodel> request cancelled#{label.empty? ? "" : " (#{label})"}"
    end

    def cancelled_result_from(messages, reason:)
      KernelLoop::Result.new(
        output: "",
        conversation: clone_messages(messages),
        exhausted: false,
        pending_tool_calls: false,
        tool_activity: [],
        canceled: true,
        cancellation_reason: reason
      )
    end

    def cancellation_reason_label(reason)
      return "" if reason.nil?

      case reason.to_sym
      when :ctrl_c
        "ctrl-c"
      else
        reason.to_s
      end
    end

    def start_cancel_hotkey_monitor(cancellation_controller)
      return unless cancellation_controller
      return unless cancel_hotkey_monitor_enabled?

      stop_cancel_hotkey_monitor
      @cancel_hotkey_stop_requested = false

      @cancel_hotkey_thread = Thread.new do
        Thread.current.report_on_exception = false
        stdin = $stdin

        begin
          with_cancel_hotkey_input_mode(stdin) do
            loop do
              break if @cancel_hotkey_stop_requested
              break if cancellation_controller.cancelled?

              readable = IO.select([stdin], nil, nil, CANCEL_MONITOR_POLL_INTERVAL)
              next unless readable

              key = begin
                stdin.read_nonblock(1)
              rescue IO::WaitReadable, EOFError
                nil
              end
              next if key.nil?

              process_cancel_hotkey_char(key, at: monotonic_time, controller: cancellation_controller)
              break if cancellation_controller.cancelled?
            end
          end
        rescue StandardError
          nil
        end
      end
    end

    def stop_cancel_hotkey_monitor
      thread = @cancel_hotkey_thread
      @cancel_hotkey_thread = nil
      @cancel_hotkey_stop_requested = true
      return unless thread
      return if thread == Thread.current

      thread.join(CANCEL_MONITOR_POLL_INTERVAL * 3)
    rescue StandardError
      nil
    end

    def with_cancel_hotkey_input_mode(stdin)
      stdin.cbreak do
        yield
      end
    end

    def cancel_hotkey_monitor_enabled?
      return false unless @mode == :assist
      return false unless $stdin.tty?
      return false unless $stdout.tty?

      ENV.fetch("TERM", "") != "dumb"
    end

    def process_cancel_hotkey_char(char, at:, controller:)
      if char == CTRL_C_BYTE
        controller.cancel!(:ctrl_c)
      end
    end

    def start_thinking_spinner
      return unless thinking_spinner_enabled?

      @thinking_spinner_active = true
      @thinking_spinner_index = 0 if @thinking_spinner_index.nil?
      @thinking_spinner_last_render_at = nil
      @thinking_tail_preview_dirty = false
      @thinking_preview_has_content = false
      render_thinking_spinner
    end

    def tick_thinking_spinner
      return unless @thinking_spinner_active

      @thinking_spinner_index = (@thinking_spinner_index + 1) % THINKING_SPINNER_FRAMES.length
      render_thinking_spinner_if_due
    end

    def refresh_thinking_spinner_status
      return unless @thinking_spinner_active

      render_thinking_spinner
    end

    def render_thinking_spinner_if_due
      return render_thinking_spinner if force_spinner_render?

      last = @thinking_spinner_last_render_at
      return render_thinking_spinner if last.nil?
      return if (monotonic_time - last) < thinking_render_min_interval

      render_thinking_spinner
    end

    def force_spinner_render?
      @thinking_tail_preview_dirty && !@thinking_preview_has_content
    end

    def finish_thinking_spinner
      return unless @thinking_spinner_rendered

      line_count = @thinking_spinner_lines_rendered.to_i
      line_count = 1 if line_count <= 0

      if line_count > 1
        $stdout.print("\e[#{line_count - 1}A")
      end
      $stdout.print("\r")
      line_count.times do |index|
        $stdout.print("\e[0K")
        $stdout.print("\n") if index < line_count - 1
      end
      if line_count > 1
        $stdout.print("\e[#{line_count - 1}A")
      end
      $stdout.print("\r")
      $stdout.flush
      @thinking_spinner_rendered = false
      @thinking_spinner_active = false
      @thinking_spinner_lines_rendered = 0
      @thinking_spinner_last_render_at = nil
      @thinking_tail_preview_dirty = false
      @thinking_preview_has_content = false
    end

    def move_to_thinking_spinner_origin
      return unless @thinking_spinner_rendered

      line_count = @thinking_spinner_lines_rendered.to_i
      if line_count > 1
        $stdout.print("\e[#{line_count - 1}A")
      end
      $stdout.print("\r")
    end

    def capture_thinking_tail_chunk(chunk)
      return unless thinking_tail_preview_enabled?
      return if chunk.nil? || chunk.empty?

      buffer = String.new(@thinking_tail_preview_buffer.to_s)
      buffer << chunk.to_s
      @thinking_tail_preview_buffer = buffer[-THINKING_TAIL_PREVIEW_BUFFER_LIMIT, THINKING_TAIL_PREVIEW_BUFFER_LIMIT] || buffer
      @thinking_tail_preview_dirty = true
    end

    def thinking_tail_preview_enabled?
      @mode == :assist && @thinking_spinner_active
    end

    def thinking_tail_preview_line
      lines, has_content = thinking_tail_preview_lines
      return nil unless has_content

      lines.first
    end

    def thinking_tail_preview_lines
      line_count = thinking_preview_lines_count
      prefix = "model> … "
      continuation = " " * prefix.length
      first_width = [THINKING_PREVIEW_WIDTH - prefix.length, 1].max
      continuation_width = [THINKING_PREVIEW_WIDTH - continuation.length, 1].max

      text = thinking_tail_preview_text
      text = text[-thinking_tail_preview_capacity, thinking_tail_preview_capacity] || text
      chunks = [text.slice(0, first_width).to_s]
      offset = first_width
      (line_count - 1).times do
        chunks << text.slice(offset, continuation_width).to_s
        offset += continuation_width
      end

      lines = [cap_preview_line("#{prefix}#{chunks[0]}")]
      chunks.drop(1).each do |chunk|
        lines << cap_preview_line("#{continuation}#{chunk}")
      end

      [lines, !text.empty?]
    end

    def thinking_tail_preview_text
      text = @thinking_tail_preview_buffer.to_s
      return "" if text.empty?

      # Strip model control-token fragments from the tail preview.
      text = text.gsub(/<\|[^>]{1,120}>/, "")
      text = text.gsub(/<[a-z_\|]{1,40}>/, "")
      text = text.gsub(/\s+/, " ").strip
      text.empty? ? "" : text
    end

    def reset_thinking_tail_preview
      @thinking_tail_preview_buffer = String.new
      @thinking_tail_preview_dirty = false
      @thinking_preview_has_content = false
    end

    def retry_spinner_status_line(frame)
      data = @retry_spinner_status || {}
      attempt = data[:attempt].to_i
      max_retries = data[:max_retries].to_i
      total_attempts = max_retries + 1
      delay = format("%.1f", data[:next_delay].to_f)
      error_class = data[:error_class].to_s
      message = "model> network error: retrying (#{attempt}/#{total_attempts} in #{delay}s) #{frame}"
      message += " #{error_class}" unless error_class.empty?
      capped = cap_preview_line(message)
      color_output? ? paint(capped, NETWORK_RETRY_SPINNER_COLOR) : capped
    end

    def cap_preview_line(text)
      cap_preview_text(text, THINKING_PREVIEW_WIDTH)
    end

    def cap_preview_text(text, width)
      return "" if width <= 0

      value = text.to_s
      value.length > width ? value[0, width] : value
    end

    def thinking_preview_lines_count
      raw = ENV.fetch(THINKING_PREVIEW_LINES_ENV, THINKING_PREVIEW_LINES_DEFAULT.to_s).to_s.strip
      value = Integer(raw)
      value = THINKING_PREVIEW_LINES_DEFAULT unless value.positive?
      [[value, 1].max, THINKING_PREVIEW_LINES_MAX].min
    rescue ArgumentError
      THINKING_PREVIEW_LINES_DEFAULT
    end

    def thinking_tail_preview_capacity
      prefix_length = "model> … ".length
      first_width = [THINKING_PREVIEW_WIDTH - prefix_length, 1].max
      continuation_width = first_width
      first_width + ((thinking_preview_lines_count - 1) * continuation_width)
    end

    def thinking_render_min_interval
      value = ENV.fetch(THINKING_RENDER_INTERVAL_ENV, THINKING_RENDER_MIN_INTERVAL.to_s).to_f
      return THINKING_RENDER_MIN_INTERVAL unless value.positive?

      value
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def capture_memory_tool_call(event)
      call = event[:call].is_a?(Hash) ? event[:call] : {}
      memory_name = memory_name_from_tool_call(call)
      return false if memory_name.nil? || memory_name.empty?

      added_to_thinking = add_unique_memory_name(:@thinking_memory_names, memory_name)
      add_unique_memory_name(:@session_memory_names, memory_name)
      @thinking_recent_memory_loaded = memory_name if added_to_thinking
      added_to_thinking
    end

    def capture_thinking_tool_call(event)
      call = event[:call].is_a?(Hash) ? event[:call] : {}
      name = call[:name].to_s.strip
      return if name.empty?

      params = thinking_tool_params_preview(call, event[:params])
      text = params.empty? ? name : "#{name}(#{params})"
      @thinking_recent_tool_call = cap_preview_text(text, THINKING_TOOL_PREVIEW_LIMIT)
    end

    def thinking_tool_params_preview(call, raw_params)
      compact = raw_params.to_s.gsub(/\s+/, " ").strip
      return compact unless compact.empty?

      tool_name = call[:name].to_s
      case tool_name
      when Tools::Execute::NAME
        "command=#{preview_value_for_spinner(call[:content])}"
      when Tools::Read::NAME
        "path=#{preview_value_for_spinner(call[:content])}"
      when Tools::Write::NAME, Tools::Edit::NAME
        "path=#{preview_value_for_spinner(call[:path])}"
      when Tools::MemoryRead::NAME
        parts = []
        name = call[:content].to_s.strip
        parts << "name=#{preview_value_for_spinner(name)}" unless name.empty?
        scope = call[:scope].to_s.strip
        parts << "scope=#{preview_value_for_spinner(scope)}" unless scope.empty?
        parts.join(" ")
      when Tools::MemoryWrite::NAME
        parts = []
        path = call[:path].to_s.strip
        parts << "name=#{preview_value_for_spinner(path)}" unless path.empty?
        scope = call[:scope].to_s.strip
        parts << "scope=#{preview_value_for_spinner(scope)}" unless scope.empty?
        parts.join(" ")
      else
        ""
      end
    end

    def preview_value_for_spinner(value)
      text = value.to_s.gsub(/\s+/, " ").strip
      return '""' if text.empty?

      text.inspect
    end

    def add_unique_memory_name(ivar_name, value)
      names = instance_variable_get(ivar_name) || []
      return false if names.include?(value)

      names << value
      instance_variable_set(ivar_name, names)
      true
    end

    def memory_name_from_tool_call(call)
      tool_name = call[:name].to_s
      case tool_name
      when Tools::MemoryRead::NAME
        normalize_memory_name(call[:content])
      when Tools::Read::NAME
        memory_name_from_read_path(call[:content])
      else
        nil
      end
    end

    def normalize_memory_name(raw)
      value = raw.to_s.strip
      return nil if value.empty?

      File.basename(value, ".md")
    end

    def memory_name_from_read_path(raw_path)
      path = raw_path.to_s.strip.tr("\\", "/")
      return nil if path.empty?
      return nil unless path.match?(%r{(?:\A|/)memories/.+\.md\z})

      normalize_memory_name(path)
    end

    def memory_spinner_segment
      segment = memory_spinner_segment_plain
      return "" if segment.empty?

      color_output? ? paint(segment, MEMORY_SPINNER_COLOR) : segment
    end

    def memory_spinner_segment_plain
      names = Array(@thinking_memory_names)
      return "" if names.empty?

      visible = names.first(MEMORY_SPINNER_PREVIEW_LIMIT)
      suffix = names.length > visible.length ? ", +#{names.length - visible.length}" : ""
      " mem: #{visible.join(', ')}#{suffix}"
    end

    def memory_sticky_line
      names = Array(@session_memory_names)
      return "" if names.empty?

      visible = names.first(MEMORY_STICKY_PREVIEW_LIMIT)
      suffix = names.length > visible.length ? ", +#{names.length - visible.length}" : ""
      body = "memories> active this session: #{visible.join(', ')}#{suffix}"
      color_output? ? paint(body, MEMORY_SPINNER_COLOR) : body
    end

    def reset_thinking_memory_names
      @thinking_memory_names = []
    end

    def reset_thinking_memory_notification
      @thinking_recent_memory_loaded = nil
    end

    def reset_thinking_tool_notification
      @thinking_recent_tool_call = nil
    end

    def capture_context_status_from_result(result)
      conversation = result.respond_to?(:conversation) ? Array(result.conversation) : []
      message = conversation.reverse.find do |entry|
        entry[:role] == "system" && entry[:content].to_s.start_with?(KernelLoop::CONTEXT_STATUS_PREFIX)
      end
      return unless message

      content = message[:content].to_s
      pct_match = content.match(/\best_pct=([0-9]+(?:\.[0-9]+)?)/)
      bucket_match = content.match(/\bbucket=([a-z0-9_]+)/)
      return unless pct_match

      @latest_context_status = {
        est_pct: pct_match[1].to_f,
        bucket: bucket_match && bucket_match[1]
      }
    end

    def capture_server_context_status_from_payload(payload)
      normalized = normalize_server_context_status(payload)
      return unless normalized

      @latest_server_context_status = normalized
    end

    def normalize_server_context_status(payload)
      payload_hash = payload.is_a?(Hash) ? payload : {}
      usage = payload_hash["usage"] || payload_hash[:usage]
      usage = {} unless usage.is_a?(Hash)

      prompt_tokens = first_positive_integer(
        usage["prompt_tokens"],
        usage[:prompt_tokens],
        payload_hash["prompt_tokens"],
        payload_hash[:prompt_tokens],
        payload_hash["prompt_n"],
        payload_hash[:prompt_n],
        payload_hash["tokens_evaluated"],
        payload_hash[:tokens_evaluated],
        payload_hash.dig("timings", "prompt_n"),
        payload_hash.dig(:timings, :prompt_n)
      )

      completion_tokens = first_positive_integer(
        usage["completion_tokens"],
        usage[:completion_tokens],
        payload_hash["completion_tokens"],
        payload_hash[:completion_tokens],
        payload_hash["predicted_n"],
        payload_hash[:predicted_n],
        payload_hash["tokens_predicted"],
        payload_hash[:tokens_predicted],
        payload_hash.dig("timings", "predicted_n"),
        payload_hash.dig(:timings, :predicted_n)
      )

      total_tokens = first_positive_integer(
        usage["total_tokens"],
        usage[:total_tokens],
        payload_hash["total_tokens"],
        payload_hash[:total_tokens],
        payload_hash["n_past"],
        payload_hash[:n_past]
      )
      total_tokens ||= prompt_tokens.to_i + completion_tokens.to_i if prompt_tokens || completion_tokens

      context_window_tokens = first_positive_integer(
        payload_hash["n_ctx"],
        payload_hash[:n_ctx],
        payload_hash["context_window"],
        payload_hash[:context_window],
        ENV[KernelLoop::CONTEXT_WINDOW_TOKENS_ENV],
        KernelLoop::DEFAULT_CONTEXT_WINDOW_TOKENS
      )

      context_used_tokens = first_positive_integer(
        payload_hash["n_past"],
        payload_hash[:n_past],
        total_tokens
      )

      ctx_pct = if context_window_tokens && context_used_tokens
                  (context_used_tokens.to_f / context_window_tokens) * 100.0
                end

      return nil unless prompt_tokens || completion_tokens || total_tokens || ctx_pct

      {
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens,
        total_tokens: total_tokens,
        ctx_pct: ctx_pct
      }
    end

    def first_positive_integer(*values)
      values.each do |value|
        integer = Integer(value)
        return integer if integer.positive?
      rescue ArgumentError, TypeError
        next
      end

      nil
    end

    def status_line_enabled?
      value = ENV.fetch(STATUS_LINE_ENV, STATUS_LINE_ON).to_s.strip.downcase
      !(value.empty? || value == STATUS_LINE_OFF || value == "0" || value == "false")
    end

    def emit_idle_status_line
      return unless status_line_enabled?

      lines = idle_status_lines
      return if lines.empty?

      lines.each { |line| $stdout.puts line }
    end

    def spinner_status_line
      return "" unless status_line_enabled?

      lines = spinner_status_lines
      lines.empty? ? "" : lines.first
    end

    def spinner_status_lines
      return [] unless status_line_enabled?

      build_status_lines(scope: :spinner)
    end

    def sticky_status_line
      return "" unless status_line_enabled?

      lines = sticky_status_lines
      lines.empty? ? "" : lines.first
    end

    def sticky_status_lines
      return [] unless status_line_enabled?

      build_status_lines(scope: :sticky)
    end

    def idle_status_line
      return "" unless status_line_enabled?

      lines = idle_status_lines
      lines.empty? ? "" : lines.first
    end

    def idle_status_lines
      return [] unless status_line_enabled?

      build_status_lines(scope: :idle)
    end

    def build_status_line(scope:)
      lines = build_status_lines(scope: scope)
      lines.empty? ? "" : lines.first
    end

    def build_status_lines(scope:)
      segments = status_segments(scope)
      return [] if segments.empty?

      body = "status> #{segments.join(' | ')}"
      lines = status_body_lines(body)
      if color_output?
        lines.map { |line| paint(line, 90) }
      else
        lines
      end
    end

    def status_body_lines(body)
      width = status_effective_width
      return [] if width <= 0

      [cap_preview_text(body, width)]
    end

    def status_width_mode
      mode = ENV.fetch(STATUS_WIDTH_MODE_ENV, STATUS_WIDTH_MODE_TERMINAL_CAP).to_s.strip.downcase
      return STATUS_WIDTH_MODE_FIXED if mode == STATUS_WIDTH_MODE_FIXED

      STATUS_WIDTH_MODE_TERMINAL_CAP
    end

    def status_effective_width
      mode = status_width_mode
      width = if mode == STATUS_WIDTH_MODE_FIXED
                status_fixed_width
              else
                [terminal_columns, status_max_width].min
              end
      width = status_fixed_width unless width.positive?
      width
    end

    def status_fixed_width
      env_positive_int(STATUS_FIXED_WIDTH_ENV, THINKING_PREVIEW_WIDTH)
    end

    def status_max_width
      env_positive_int(STATUS_MAX_WIDTH_ENV, STATUS_MAX_WIDTH_DEFAULT)
    end

    def terminal_columns
      columns = begin
        io = IO.console
        io&.winsize&.[](1).to_i
      rescue StandardError
        0
      end
      return columns if columns.positive?

      env_positive_int("COLUMNS", status_max_width)
    end

    def env_positive_int(key, default)
      value = ENV.fetch(key, default.to_s).to_i
      value.positive? ? value : default
    end

    def status_segments(scope)
      segments = [status_mode_segment, status_server_segment].reject(&:empty?)
      context_segment = status_context_segment
      memory_segment = status_memory_segment(scope)
      segments << context_segment unless context_segment.empty?
      segments << memory_segment unless memory_segment.empty?
      segments
    end

    def status_mode_segment
      "mode=#{@mode}"
    end

    def status_context_segment
      server_status = @latest_server_context_status
      return format_server_context_segment(server_status) if server_status.is_a?(Hash)

      status = @latest_context_status
      return "" unless status.is_a?(Hash)

      pct = format("%.1f", status[:est_pct].to_f)
      bucket = status[:bucket].to_s
      return "ctx=#{pct}%" if bucket.empty?

      "ctx=#{pct}% (#{bucket})"
    end

    def format_server_context_segment(status)
      pct = status[:ctx_pct]
      base = pct ? "ctx=#{format('%.1f', pct)}%" : "ctx=srv"

      tokens = []
      prompt_tokens = status[:prompt_tokens]
      completion_tokens = status[:completion_tokens]
      total_tokens = status[:total_tokens]
      tokens << "p=#{prompt_tokens}" if prompt_tokens
      tokens << "c=#{completion_tokens}" if completion_tokens
      tokens << "t=#{total_tokens}" if total_tokens

      return base if tokens.empty?

      "#{base} (#{tokens.join(' ')})"
    end

    def status_memory_segment(scope)
      names, limit = case scope
                     when :spinner
                       [Array(@thinking_memory_names), MEMORY_SPINNER_PREVIEW_LIMIT]
                     else
                       [Array(@session_memory_names), MEMORY_STICKY_PREVIEW_LIMIT]
                     end
      return "" if names.empty?

      visible = names.first(limit)
      suffix = names.length > visible.length ? ", +#{names.length - visible.length}" : ""
      "mem: #{visible.join(', ')}#{suffix}"
    end

    def thinking_memory_notification_suffix
      memory_name = @thinking_recent_memory_loaded.to_s.strip
      return "" if memory_name.empty?

      " memory_loaded: #{memory_name}"
    end

    def thinking_tool_notification_suffix
      tool_call = @thinking_recent_tool_call.to_s.strip
      return "" if tool_call.empty?

      " last_tool: #{tool_call}"
    end

    def thinking_notification_segments(width)
      return ["", ""] if width <= 0

      memory_suffix = cap_preview_text(thinking_memory_notification_suffix, width)
      remaining = [width - memory_suffix.length, 0].max
      tool_suffix = cap_preview_text(thinking_tool_notification_suffix, remaining)
      [memory_suffix, tool_suffix]
    end

    def paint_if_present(text, code)
      return "" if text.to_s.empty?

      paint(text, code)
    end

    def thinking_spinner_enabled?
      return false unless $stdout.tty?

      mode = ENV.fetch(THINKING_UI_ENV, THINKING_UI_SPINNER).to_s.strip.downcase
      return false if mode.empty? || mode == THINKING_UI_OFF || mode == "false" || mode == "0"

      mode == THINKING_UI_SPINNER && ENV.fetch("TERM", "") != "dumb"
    end

    def set_retry_spinner_status(event)
      @retry_spinner_status = {
        attempt: event[:attempt],
        max_retries: event[:max_retries],
        next_delay: event[:next_delay],
        error_class: event[:error_class]
      }
    end

    def clear_retry_spinner_status
      @retry_spinner_status = nil
    end

    def retry_spinner_status_active?
      @retry_spinner_status.is_a?(Hash)
    end

    def queue_input_prefill(text)
      normalized = text.to_s
      return if normalized.strip.empty?

      @next_input_prefill = normalized
    end

    def consume_input_prefill
      value = @next_input_prefill
      @next_input_prefill = nil
      value
    end

    def with_next_input_prefill
      prefill = consume_input_prefill
      return yield if prefill.nil? || prefill.empty?

      previous_hook = Reline.pre_input_hook
      inserted = false
      Reline.pre_input_hook = proc do
        unless inserted
          Reline.insert_text(prefill)
          inserted = true
        end
        previous_hook.call if previous_hook
      end
      yield
    ensure
      Reline.pre_input_hook = previous_hook
    end

    def render_thinking_spinner
      frame = THINKING_SPINNER_FRAMES[@thinking_spinner_index % THINKING_SPINNER_FRAMES.length]
      spinner_lines = thinking_spinner_status_lines(frame)
      preview_lines, preview_has_content = thinking_tail_preview_lines
      if color_output?
        preview_lines = preview_lines.map { |text| paint(text, 90) }
      end
      lines = spinner_lines + preview_lines
      status_lines = spinner_status_lines
      lines.concat(status_lines) unless status_lines.empty?

      move_to_thinking_spinner_origin
      previous_line_count = @thinking_spinner_lines_rendered.to_i
      render_line_count = [previous_line_count, lines.length].max
      padded_lines = lines + Array.new(render_line_count - lines.length, "")
      $stdout.print(padded_lines.map { |text| "#{text}\e[0K" }.join("\n"))
      $stdout.flush
      @thinking_spinner_rendered = true
      @thinking_spinner_lines_rendered = render_line_count
      @thinking_spinner_last_render_at = monotonic_time
      @thinking_tail_preview_dirty = false
      @thinking_preview_has_content = preview_has_content
    end

    def thinking_spinner_status_line(frame)
      lines = thinking_spinner_status_lines(frame)
      lines.empty? ? "" : lines.first
    end

    def thinking_spinner_status_lines(frame)
      if retry_spinner_status_active?
        return [retry_spinner_status_line(frame)]
      end

      base = "model> thinking... #{frame}"
      available_for_notification = [status_effective_width - base.length, 0].max
      memory_notification, tool_notification = thinking_notification_segments(available_for_notification)
      notification = "#{memory_notification}#{tool_notification}"

      return ["#{base}#{notification}"] unless color_output?

      ["#{paint(base, 90)}#{paint_if_present(memory_notification, MEMORY_SPINNER_COLOR)}#{paint_if_present(tool_notification, TOOL_SPINNER_COLOR)}"]
    end
  end
end
