# frozen_string_literal: true

require "json"
require_relative "../tools/execute"
require_relative "../tools/read"
require_relative "../tools/write"
require_relative "../tools/memory"
require_relative "../tools/edit"
require_relative "../tools/task_create"
require_relative "../tools/task_get"
require_relative "../tools/task_list"
require_relative "../tools/task_stop"
require_relative "../tools/task_wait"
require_relative "../tools/web_fetch"
require_relative "../tools/ask_user_question"

module Samagotchi
  module LLM
    # Bridges a ruby_llm gem native `ToolCall` (as emitted by an OpenAI-compatible
    # server and parsed by the gem) into samagotchi's internal tool-call shape that
    # `KernelLoop#dispatch` consumes:
    #
    #   { name:, content:, path:, scope:, start_line:, end_line:, cwd:, env:, description: }
    #
    # The gem hands you a *structured* `arguments` Hash (`.arguments` is a parsed
    # Hash), while the internal `content` is a per-tool serialized text blob
    # (e.g. `Edit` wants "<old>…</old><new>…</new>"; `Read` wants a `path`;
    # `Execute` wants the command). Rather than re-architect every tool to accept
    # structured args (huge blast radius), we rebuild the exact blob per tool so
    # `dispatch` and every tool stay unchanged.
    #
    # Unknown tool names pass through untouched so `dispatch` renders its standard
    # "unknown tool … available: …" error — the loop feeds that back like any tool
    # result.
    #
    # This is the Phase-3 crux from Spike #4: the gem→internal mapping is
    # independent of how tools were driven in the request body.
    class NativeToolNormalizer
      # Map each known tool NAME to a proc(args => internal-call-hash).
      # Each proc receives the gem ToolCall (`.arguments` is a Hash of string→value)
      # and returns the internal dispatch shape with every expected key present
      # (missing values are nil).
      #
      # Args come back as strings from the wire (e.g. "start_line" => "1"); tools
      # that read them do `.to_s.strip`, so we leave them as-is here and let the
      # dispatch site coerce.
      MAP = {
        Tools::Execute::NAME => lambda { |args|
          {
            name: Tools::Execute::NAME,
            content: args["command"].to_s,
            path: nil, scope: nil,
            start_line: nil, end_line: nil,
            cwd: args["cwd"], env: args["env"]
          }
        },
        Tools::Read::NAME => lambda { |args|
          {
            name: Tools::Read::NAME,
            content: args["path"].to_s,
            path: nil, scope: nil,
            start_line: args["start_line"], end_line: args["end_line"],
            cwd: nil, env: nil, description: nil
          }
        },
        Tools::Write::NAME => lambda { |args|
          {
            name: Tools::Write::NAME,
            content: args["content"] || args["text"],
            path: args["path"], scope: nil,
            start_line: nil, end_line: nil,
            cwd: nil, env: nil, description: nil
          }
        },
        Tools::MemoryRead::NAME => lambda { |args|
          {
            name: Tools::MemoryRead::NAME,
            content: args["name"].to_s,
            path: nil, scope: args["scope"],
            start_line: nil, end_line: nil,
            cwd: nil, env: nil, description: nil
          }
        },
        Tools::MemoryWrite::NAME => lambda { |args|
          {
            name: Tools::MemoryWrite::NAME,
            content: args["content"] || args["text"] || args["body"],
            path: args["name"], scope: args["scope"],
            description: args["description"],
            start_line: nil, end_line: nil,
            cwd: nil, env: nil
          }
        },
        Tools::Edit::NAME => lambda { |args|
          old_text = args["old_text"] || args["old"]
          new_text = args["new_text"] || args["new"]
          {
            name: Tools::Edit::NAME,
            content: "<old>#{old_text}</old><new>#{new_text}</new>",
            path: args["path"],
            start_line: args["start_line"], end_line: args["end_line"],
            scope: nil, cwd: nil, env: nil, description: nil
          }
        },
        Tools::TaskCreate::NAME => lambda { |args|
          {
            name: Tools::TaskCreate::NAME,
            content: args["command"].to_s,
            path: nil, scope: nil,
            start_line: nil, end_line: nil,
            cwd: args["cwd"], env: args["env"], description: nil
          }
        },
        Tools::TaskGet::NAME => lambda { |args|
          {
            name: Tools::TaskGet::NAME,
            content: (args["id"] || args["task_id"]).to_s,
            path: nil, scope: nil,
            start_line: nil, end_line: nil,
            cwd: nil, env: nil, description: nil
          }
        },
        Tools::TaskStop::NAME => lambda { |args|
          {
            name: Tools::TaskStop::NAME,
            content: (args["id"] || args["task_id"]).to_s,
            path: nil, scope: nil,
            start_line: nil, end_line: nil,
            cwd: nil, env: nil, description: nil
          }
        },
        Tools::TaskWait::NAME => lambda { |args|
          {
            name: Tools::TaskWait::NAME,
            content: (args["id"] || args["task_id"]).to_s,
            path: nil, scope: nil,
            start_line: nil, end_line: nil,
            cwd: nil, env: nil,
            timeout: args["timeout"], tail_lines: args["tail_lines"], done_pattern: args["done_pattern"],
            description: nil
          }
        },
        Tools::TaskList::NAME => lambda { |_args|
          {
            name: Tools::TaskList::NAME,
            content: "", path: nil, scope: nil,
            start_line: nil, end_line: nil,
            cwd: nil, env: nil, description: nil
          }
        },
        Tools::WebFetch::NAME => lambda { |args|
          {
            name: Tools::WebFetch::NAME,
            content: args["url"].to_s,
            path: nil, scope: nil,
            start_line: nil, end_line: nil,
            cwd: nil, env: nil, description: nil
          }
        },
        Tools::AskUserQuestion::NAME => lambda { |args|
          raw_opts = args["options"]
          norm_opts = Samagotchi::Tools::AskUserQuestion.normalize_options_lenient(raw_opts)
          norm_opts = raw_opts if norm_opts.empty? && raw_opts.is_a?(Array)
          {
            name: Tools::AskUserQuestion::NAME,
            content: args["question"].to_s,
            path: nil, scope: nil,
            question: args["question"].to_s,
            options: norm_opts.empty? ? raw_opts : norm_opts,
            header: args["header"],
            multi_select: args["multi_select"],
            allow_freeform: args["allow_freeform"]
          }
        }
      }.freeze

      class << self
        # Map a single gem `RubyLLM::ToolCall` to the internal call hash.
        #
        # `call.arguments` is a parsed Hash (string keys). If it is nil or a bare
        # string we defensively coerce (string → JSON.parse when possible) so the
        # mapping never explodes on an odd wire shape.
        def normalize(call)
          return nil if call.nil?

          name = call.name.to_s
          args = args_for(call)
          proc = MAP[name]
          return passthrough(name, args) unless proc

          proc.call(args).merge(name: name)
        end

        # Map an Array of gem ToolCalls to internal call hashes (nils dropped).
        def normalize_all(calls)
          Array(calls).map { |call| normalize(call) }.compact
        end

        private

        # args_for: gem arguments is normally a Hash. Defensively handle nil /
        # JSON-string / other shapes without raising.
        def args_for(call)
          raw = call.respond_to?(:arguments) ? call.arguments : nil
          case raw
          when Hash then raw
          when String
            raw.strip.empty? ? {} : safe_json_parse(raw)
          when nil
            {}
          else
            { "__raw__" => raw.to_s }
          end
        end

        def safe_json_parse(str)
          JSON.parse(str)
        rescue JSON::ParserError
          { "__raw__" => str }
        end

        # Unknown tool: hand back enough for `dispatch` to render the standard
        # "unknown tool" error. `content` is the joined argument values (harmless;
        # the unknown-tool branch of dispatch ignores it).
        def passthrough(name, args)
          {
            name: name,
            content: args.is_a?(Hash) ? args.values.join(" ") : name,
            path: nil, scope: nil,
            start_line: nil, end_line: nil,
            cwd: nil, env: nil, description: nil
          }
        end
      end
    end
  end
end
