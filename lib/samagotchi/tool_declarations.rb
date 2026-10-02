# frozen_string_literal: true

require "json"
require_relative "tools/args"

module Samagotchi
  # Tool-declaration constants, protocol constants, and guidance text.
  #
  # Placed in a dedicated module so that both Engine and any future UI can
  # reference declarations without instantiating an Engine.
  module ToolDeclarations
    # ── Tool schemas (declared once) ──────────────────────────────────────────
    #
    # Every tool's name, description and JSON Schema parameters. The Gemma 4
    # and Qwen 3.6 prompt declarations and the chat path's tools: are all
    # rendered from this table, in this order.

    TOOL_SCHEMAS = [
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
        description: "Read a file from disk. Large files may be truncated to a head+tail preview with metadata. Optionally pass start_line and end_line (1-based, inclusive) to read only a specific line range. An image file (png, jpeg, gif, webp) comes back as the picture itself: read it to see it.",
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
        description: "Write or update a memory entry in scoped memories. Scope is required: project or system. Use the `name` parameter for the entry name (use `name`, NOT `path` — the file tools use `path`); each scope's index.md is auto-maintained (one managed line per entry); use name \"index\" to write the index file verbatim. For a small change to an existing memory (a step, a line), `edit` its file (<scope dir>/<name>.md) instead of rewriting it all; its index line is refreshed either way. If the user asks to save guidance for the current model only, pass current_model_only: true to save a model-specific overlay.",
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
            },
            current_model_only: {
              type: "boolean",
              description: "Set true to save this entry as a model-specific overlay for the current model only (<name>.<model>.md); it is auto-appended when the entry is read under that model and never listed in the index."
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
      },
      {
        name: "list_sessions",
        description: "List the other chi sessions of this project (newest first, up to 20): id, whether a worker runs it, its folder and last prompt; other projects: cwd \"/\". Use it to find the session send_note should go to.",
        parameters: {
          type: "object",
          properties: {
            cwd: {
              type: "string",
              description: "Only sessions in this folder or below it, in any project (optional)"
            }
          }
        }
      },
      {
        name: "send_note",
        description: "Send a context note to another chi session: background information it sees on its next turn, attributed to this session. It does not start a turn there or ask it to do anything.",
        parameters: {
          type: "object",
          properties: {
            session: {
              type: "string",
              description: "The target session's id or a unique prefix of it (from list_sessions)"
            },
            text: {
              type: "string",
              description: "The note: what the other session should know (up to 16 KiB)"
            }
          },
          required: ["session", "text"]
        }
      },
      {
        name: "delegate",
        description: "Hand a task to a child chi session that runs in parallel in this folder and returns only its final reply (its trace stays out of this context). The child is a normal session: it shows in the lists as a child of this one and the user can attach to it. With session, send a follow-up to one of this session's children instead. A tool call the child needs approved goes to your user as one of your own approvals; you only see how it was answered, as a line in the result. Children keep running if this turn is canceled; delegate_result waits for them later. A child stays until stopped: once its work is done, stop it with execute `chi sessions stop ID` (a follow-up with session wakes it again).",
        parameters: {
          type: "object",
          properties: {
            task: {
              type: "string",
              description: "The task, as the child's first message: self-contained, with what to report back"
            },
            model: {
              type: "string",
              description: "The child's model (a name or alias; default: this session's)"
            },
            session: {
              type: "string",
              description: "A child's id or prefix: send the task there as a follow-up instead of starting a new child"
            },
            wait: {
              type: "boolean",
              description: "Wait for the reply (default true); false returns at once so several children can run side by side"
            },
            timeout: {
              type: "integer",
              description: "Maximum seconds to wait (default: 600; 0 checks once without waiting); a timed-out child keeps running"
            }
          },
          required: ["task"]
        }
      },
      {
        name: "delegate_result",
        description: "Wait for a delegated child session's next reply: the child named, or this session's newest running child. Returns early if the child waits for a question the user must answer. A tool call the child needs approved goes to your user while this waits; the result says how it was answered.",
        parameters: {
          type: "object",
          properties: {
            session: {
              type: "string",
              description: "The child's id or prefix (default: the newest running child)"
            },
            timeout: {
              type: "integer",
              description: "Maximum seconds to wait (default: 600; 0 checks once without waiting)"
            }
          }
        }
      },
      {
        name: "ask_user_question",
        description: "Ask the user a structured qualification question. Supports single/multi selection plus optional freeform/Other input. Prefer this over plain numbered lists when you need a clear choice. The harness renders it natively and returns {selected, freeform}.",
        parameters: {
          type: "object",
          properties: {
            question: {
              type: "string",
              description: "The question to ask the user"
            },
            options: {
              type: "array",
              description: "2-8 answer options as strings (labels)",
              items: { type: "string" }
            },
            header: {
              type: "string",
              description: "Optional short header/title"
            },
            multi_select: {
              type: "boolean",
              description: "Allow selecting multiple options (comma-separated in TUI). Default false."
            },
            allow_freeform: {
              type: "boolean",
              description: "Allow freeform/Other text alongside selection. Default false."
            }
          },
          required: ["question", "options"]
        }
      }
    ].freeze

    # Where Gemma's declaration text says something the schema doesn't: extra
    # description text, and explicit required:false on optional parameters.
    GEMMA_PARAM_OVERRIDES = {
      "edit" => { new_text: { description: "Replacement text (required)" } },
      "task_wait" => {
        timeout: { required: false },
        tail_lines: { required: false },
        done_pattern: { required: false }
      },
      "delegate" => {
        model: { required: false },
        session: { required: false },
        wait: { required: false },
        timeout: { required: false }
      },
      "delegate_result" => {
        session: { required: false },
        timeout: { required: false }
      },
      "ask_user_question" => {
        options: { description: "2-8 answer options as strings (labels). Single/multi selection via multi_select flag." }
      }
    }.freeze

    # What only the chat path's JSON Schemas carry (F3): enums the prompt
    # text states in words. Adding them to TOOL_SCHEMAS would change the
    # Qwen prompt, which renders the table as JSON.
    CHAT_PARAM_OVERRIDES = {
      "memory_read" => { scope: { enum: %w[project system] } },
      "memory_write" => { scope: { enum: %w[project system] } }
    }.freeze

    GEMMA_QUOTE = '<|"|>'

    module_function

    # Gemma 4 <|tool>declaration:NAME{…}<tool|> blocks for every tool, one per line group.
    # @param schemas [Array<Hash>] a Tools::Registry's schemas
    def gemma_declarations(schemas = TOOL_SCHEMAS)
      schemas.map { |schema| gemma_declaration(schema) }.join("\n")
    end

    def gemma_declaration(schema)
      q = GEMMA_QUOTE
      required = Array(schema[:parameters][:required])
      overrides = GEMMA_PARAM_OVERRIDES.fetch(schema[:name], {})
      lines = schema[:parameters][:properties].map do |name, param|
        override = overrides.fetch(name, {})
        description = override.fetch(:description, param[:description])
        line = "    #{name}:{type:#{q}#{param[:type]}#{q}, description:#{q}#{description}#{q}"
        req = override.fetch(:required, required.include?(name.to_s) ? true : nil)
        line += ", required:#{req}" unless req.nil?
        "#{line}}"
      end
      params = lines.empty? ? "  parameters:{}" : "  parameters:{\n#{lines.join(",\n")}\n  }"
      "<|tool>declaration:#{schema[:name]}{\n  description:#{q}#{schema[:description]}#{q},\n#{params}\n}<tool|>"
    end

    # The schemas for the chat path's tools: array: +schemas+ with
    # CHAT_PARAM_OVERRIDES merged in and each tool's parameters closed
    # (additionalProperties: false, unless a plugin's schema says), so a
    # strict provider rejects made-up parameters instead of the tool
    # ignoring them. A plugin's schema goes as it is, nesting and all.
    def chat_schemas(schemas = TOOL_SCHEMAS)
      schemas.map do |schema|
        overrides = CHAT_PARAM_OVERRIDES.fetch(schema[:name], {})
        properties = schema[:parameters][:properties].to_h do |name, param|
          [name, param.merge(overrides.fetch(name, {}))]
        end
        parameters = schema[:parameters].merge(properties: properties)
        parameters = parameters.merge(additionalProperties: false) unless parameters.key?(:additionalProperties)
        schema.merge(parameters: parameters)
      end
    end

    # The schemas the native (Gemma, Qwen) prompts declare: the built-ins
    # as they are, and each plugin tool's flattened (.flat_schema).
    # @param registry [Tools::Registry]
    def native_schemas(registry)
      registry.entries.map { |entry| entry.core? ? entry.schema : flat_schema(entry.schema) }
    end

    # A plugin tool's schema in the shape the built-ins have, which is all
    # the native declarations render: each parameter a type and a
    # description. What doesn't fit goes into the description in words: an
    # enum's values, an object's fields, a list's item type. Nested schemas
    # and additionalProperties are dropped; the call's args are still
    # typed by the full schema (Tools::Args).
    def flat_schema(schema)
      parameters = schema[:parameters] || {}
      properties = (parameters[:properties] || {}).to_h { |name, param| [name.to_sym, flat_param(param)] }
      { name: schema[:name], description: schema[:description].to_s,
        parameters: { type: "object", properties: properties, required: Array(parameters[:required]).map(&:to_s) } }
    end

    def flat_param(param)
      param = {} unless param.is_a?(Hash)
      type = Tools::Args.type_of(param) || "string"
      description = param[:description].to_s.strip
      notes = []
      notes << "One of: #{param[:enum].map { |value| JSON.generate(value) }.join(", ")}." if param[:enum].is_a?(Array)
      case type
      when "object"
        fields = param[:properties].is_a?(Hash) ? param[:properties] : {}
        notes << "A JSON object with #{fields.map { |name, field| "#{name} (#{field_type(field)})" }.join(", ")}." unless fields.empty?
      when "array"
        items = param[:items]
        notes << "A list of #{field_type(items)} values." if items.is_a?(Hash)
      end
      # "Extra fields." then the words: a description without an end mark
      # would run into them.
      description += "." unless description.empty? || notes.empty? || description.match?(/[.!?:;]\z/)
      { type: type, description: [description, *notes].reject(&:empty?).join(" ") }
    end

    def field_type(field)
      return "any" unless field.is_a?(Hash)

      type = Tools::Args.type_of(field) || "any"
      field[:enum].is_a?(Array) ? "#{type}: #{field[:enum].map { |value| JSON.generate(value) }.join("|")}" : type
    end

    # Qwen 3.6 <tools> block: the schemas as pretty-printed JSON.
    def qwen_declarations(schemas = TOOL_SCHEMAS)
      "<tools>\n#{JSON.pretty_generate(schemas)}\n</tools>"
    end

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
          1. If the user provides file:line (for example, src/app.rb:130), inspect that location first.
          2. Use execute with rg/nl/sed to find the smallest relevant snippet.
          3. Read a full file only when targeted snippet extraction is insufficient.
        Avoid broad reads early in debugging; gather just enough context to decide the next step.
    PROTOCOL
  end
end
