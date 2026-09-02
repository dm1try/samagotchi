# frozen_string_literal: true

module Samagotchi
  # Tool-declaration constants, protocol constants, and guidance text.
  #
  # Placed in a dedicated module so that both Engine and any future UI can
  # reference declarations without instantiating an Engine.
  module ToolDeclarations
    # ── Tool declarations (Gemma 4 <|tool>/<tool|> format) ────────────────────

    TOOL_EXECUTE = <<~DECL.strip
      <|tool>declaration:execute{
        description:<|"|>Run any shell command in a working directory (defaults to the project root) and see stdout, stderr, and exit code. Large output may be truncated to a head+tail preview with metadata.<|"|>,
        parameters:{
          command:{type:<|"|>string<|"|>, description:<|"|>The shell command to run<|"|>, required:true},
          cwd:{type:<|"|>string<|"|>, description:<|"|>Optional working directory to run in (defaults to the project root). Relative paths are resolved against the project root.<|"|>}
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
        description:<|"|>Write or update a memory entry in scoped memories. Scope is required: project or system. Use the `name` parameter for the entry name (use `name`, NOT `path` — the file tools use `path`); each scope's index.md is auto-maintained (one managed line per entry); use name "index" to write the index file verbatim.<|"|>,
        parameters:{
          name:{type:<|"|>string<|"|>, description:<|"|>Memory entry name without .md extension<|"|>, required:true},
          content:{type:<|"|>string<|"|>, description:<|"|>Markdown content to write<|"|>, required:true},
          scope:{type:<|"|>string<|"|>, description:<|"|>Scope to write into: project or system<|"|>, required:true},
          description:{type:<|"|>string<|"|>, description:<|"|>Optional short description appended to the managed index line<|"|>}
        }
      }<tool|>
    DECL

    TOOL_TASK_CREATE = <<~DECL.strip
      <|tool>declaration:task_create{
        description:<|"|>Start a background task for a long-running shell command. Returns task id and output path for later inspection.<|"|>,
        parameters:{
          command:{type:<|"|>string<|"|>, description:<|"|>Shell command to run in the background<|"|>, required:true},
          cwd:{type:<|"|>string<|"|>, description:<|"|>Optional working directory (defaults to project root)<|"|>},
          env:{type:<|"|>string<|"|>, description:<|"|>Optional JSON object of environment overrides; use this for PATH or tool-specific variables<|"|>}
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

    TOOL_TASK_WAIT = <<~DECL.strip
      <|tool>declaration:task_wait{
        description:<|"|>Wait for a background task to finish. Polls every 0.5s until completion, a log pattern matches, or timeout. Timed-out waits include a bounded output tail.<|"|>,
        parameters:{
          task_id:{type:<|"|>string<|"|>, description:<|"|>Task id returned by task_create<|"|>, required:true},
          timeout:{type:<|"|>integer<|"|>, description:<|"|>Maximum seconds to wait (default: 600)<|"|>, required:false},
          tail_lines:{type:<|"|>integer<|"|>, description:<|"|>Log lines to return when timing out or matching a pattern (default: 10, max: 100)<|"|>, required:false},
          done_pattern:{type:<|"|>string<|"|>, description:<|"|>Optional regular expression that returns early when it matches the recent log output<|"|>, required:false}
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

    TOOL_REGISTER_REMINDER = <<~DECL.strip
      <|tool>declaration:register_reminder{
        description:<|"|>Register a periodic reminder. The harness injects a [SYSTEM:] message into your next idle turn when the reminder is due.<|"|>,
        parameters:{
          name:{type:<|"|>string<|"|>, description:<|"|>Short identifier, e.g. 'api_health'<|"|>, required:true},
          description:{type:<|"|>string<|"|>, description:<|"|>What should happen when this reminder fires<|"|>, required:true},
          interval_minutes:{type:<|"|>integer<|"|>, description:<|"|>How often to remind (1-1440 minutes, i.e. up to 1 day)<|"|>, required:true}
        }
      }<tool|>
    DECL

    TOOL_CANCEL_REMINDER = <<~DECL.strip
      <|tool>declaration:cancel_reminder{
        description:<|"|>Cancel a previously registered reminder so it stops firing.<|"|>,
        parameters:{
          name:{type:<|"|>string<|"|>, description:<|"|>The reminder identifier to cancel<|"|>, required:true}
        }
      }<tool|>
    DECL

    TOOL_LIST_REMINDERS = <<~DECL.strip
      <|tool>declaration:list_reminders{
        description:<|"|>List all active registered reminders.<|"|>,
        parameters:{}
      }<tool|>
    DECL

    # ── Qwen 3.6 tool declarations (JSON format) ──────────────────────────────

    QWEN_TOOLS_JSON = [
      {
        name: "execute",
        description: "Run any shell command in a working directory (defaults to the project root) and see stdout, stderr, and exit code. Large output may be truncated to a head+tail preview with metadata.",
        parameters: {
          type: "object",
          properties: {
            command: {
              type: "string",
              description: "The shell command to run"
            },
            cwd: {
              type: "string",
              description: "Optional working directory to run in (defaults to the project root). Relative paths are resolved against the project root."
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
        description: "Write or update a memory entry in scoped memories. Scope is required: project or system. Use the `name` parameter for the entry name (use `name`, NOT `path` — the file tools use `path`); each scope's index.md is auto-maintained (one managed line per entry); use name \"index\" to write the index file verbatim.",
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
            },
            description: {
              type: "string",
              description: "Optional short description appended to the managed index line"
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
            },
            env: {
              type: "string",
              description: "Optional JSON object of environment overrides; use this for PATH or tool-specific variables"
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
        name: "task_wait",
        description: "Wait for a background task to finish. Polls every 0.5s until completion, a log pattern matches, or timeout. Timed-out waits include a bounded output tail.",
        parameters: {
          type: "object",
          properties: {
            task_id: {
              type: "string",
              description: "Task id returned by task_create"
            },
            timeout: {
              type: "integer",
              description: "Maximum seconds to wait (default: 600)"
            },
            tail_lines: {
              type: "integer",
              description: "Log lines to return when timing out or matching a pattern (default: 10, max: 100)"
            },
            done_pattern: {
              type: "string",
              description: "Optional regular expression that returns early when it matches the recent log output"
            }
          },
          required: ["task_id"]
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
      },
      {
        name: "register_reminder",
        description: "Register a periodic reminder. The harness injects a [SYSTEM:] message into your next idle turn when the reminder is due.",
        parameters: {
          type: "object",
          properties: {
            name: {
              type: "string",
              description: "Short identifier, e.g. 'api_health'"
            },
            description: {
              type: "string",
              description: "What should happen when this reminder fires"
            },
            interval_minutes: {
              type: "integer",
              description: "How often to remind (1-1440 minutes, i.e. up to 1 day)"
            }
          },
          required: ["name", "description", "interval_minutes"]
        }
      },
      {
        name: "cancel_reminder",
        description: "Cancel a previously registered reminder so it stops firing.",
        parameters: {
          type: "object",
          properties: {
            name: {
              type: "string",
              description: "The reminder identifier to cancel"
            }
          },
          required: ["name"]
        }
      },
      {
        name: "list_reminders",
        description: "List all active registered reminders.",
        parameters: {
          type: "object",
          properties: {}
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
  end
end
