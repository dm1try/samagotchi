# frozen_string_literal: true

require "json"
require_relative "../tool_declarations"
require_relative "ask_user_question"

module Samagotchi
  module Tools
    # The one map from a parsed tool call ({name, args}) to the internal call
    # the built-in handlers, hooks, guardrails and bundles read:
    #
    #   { name:, content:, path:, scope:, <each other schema field>: }
    #
    # Each parser (Gemma, Qwen, the chat path) only reads its wire format
    # into string-keyed args; this table says where each argument goes. It is
    # derived from ToolDeclarations::TOOL_SCHEMAS: a property goes to the
    # field of its own name, unless OVERRIDES puts it in content: (the
    # tool's main argument) or path:. A new parameter is a schema property
    # and the handler reading it.
    #
    # A tool that is not built in keeps its arguments whole on args: (typed
    # by its schema at dispatch, Tools::Args) with their JSON as its content.
    module BuiltinCalls
      # Per tool, what the schema alone doesn't say:
      #   content:  the property (or ordered list of keys to try) that fills
      #             content:; absent, content: is "" (the handlers take a
      #             String)
      #   path:     the property that fills path: (otherwise "path" itself)
      #   also:     a property that fills content: and keeps its own field
      #   aliases:  other keys a model uses for a property, tried after it
      #   verbatim: values passed as given (file text, old/new, env,
      #             options); every other String value is stripped
      #   fallback: how Gemma fills the main argument from a body it could
      #             not read as key:value pairs (see ToolCallParser::Gemma)
      #   options:  ask_user_question's options, normalized
      OVERRIDES = {
        "execute" => { content: "command", fallback: :prefix_or_raw },
        "read" => { content: "path", fallback: :prefix_or_raw },
        "write" => { verbatim: %w[content], aliases: { "content" => %w[text] } },
        "memory_read" => { content: "name", fallback: :prefix_or_raw },
        "memory_write" => { path: "name", verbatim: %w[content], aliases: { "content" => %w[text body value] } },
        "edit" => { verbatim: %w[old_text new_text], aliases: { "old_text" => %w[old], "new_text" => %w[new] } },
        "task_create" => { content: "command", verbatim: %w[env], fallback: :prefix_or_raw },
        "task_get" => { content: %w[id task_id], fallback: :prefix_or_raw },
        "task_stop" => { content: %w[id task_id], fallback: :prefix_or_raw },
        "task_wait" => { content: %w[id task_id], fallback: :prefix_or_raw },
        "web_fetch" => { content: "url", fallback: :prefix_or_raw },
        "register_reminder" => { content: "name", fallback: :prefix_or_raw },
        "cancel_reminder" => { content: "name", fallback: :prefix_or_raw },
        "list_sessions" => { fallback: :prefix, fallback_key: "cwd" },
        "send_note" => { content: "text" },
        "context_read" => { content: "name", fallback: :prefix_or_raw },
        "delegate" => { content: "task", fallback: :prefix_or_raw },
        "ask_user_question" => { content: "question", also: %w[question], verbatim: %w[options], options: true,
                                 fallback: :raw },
        "forget_outputs" => { content: "note", also: %w[note], verbatim: %w[ids keep restore] }
      }.freeze

      # A name the model uses for a built-in, mapped to that built-in (a model
      # that keeps calling `bash` with execute's arguments; before this such a
      # call died as an unknown tool). It only takes effect when the
      # arguments really are the target's shape; the call then carries
      # called_as: with the model's own spelling.
      ALIASES = { "bash" => "execute" }.freeze

      # The tool index's call tool, whose call of a built-in runs as that
      # built-in (ToolIndex#unwrap; ToolIndex::CALL_NAME is this), and the
      # group it names them by. The one place the name is spelled.
      VIA = "call_tool"
      VIA_GROUP = "chi/"
      # A saved run's "[name]" lead (ToolResponse::LEAD).
      SAVED_LEAD = /\A\[([^\]\s]+)\]/

      # One built-in's mapping, resolved from its schema and OVERRIDES.
      Row = Data.define(:name, :content_keys, :path_key, :fields, :aliases, :verbatim, :fallback, :fallback_key,
                        :options) do
        # The keys to try for +key+, in order.
        def keys_for(key) = [key, *aliases.fetch(key, [])]

        # The keys Gemma's fallback may find as a "key:" prefix.
        def fallback_keys = fallback_key ? [fallback_key] : content_keys.flat_map { |key| keys_for(key) }

        # Whether a given +key+ (a property or one of its aliases) is
        # passed as given.
        def verbatim_key?(key) = verbatim.any? { |property| keys_for(property).include?(key) }
      end

      module_function

      # @return [Hash{String => Row}]
      def rows
        @rows ||= ToolDeclarations::BUILTIN_SCHEMAS.to_h { |schema| [schema[:name], row_for(schema)] }.freeze
      end

      def row_for(schema)
        name = schema[:name]
        o = OVERRIDES.fetch(name, {})
        properties = schema.dig(:parameters, :properties).keys.map(&:to_s)
        content_keys = Array(o[:content])
        path_key = o[:path] || ("path" if properties.include?("path") && !content_keys.include?("path"))
        taken = content_keys + [path_key].compact - Array(o[:also])
        fields = properties - taken
        # content: may list a model's other spelling (task_wait's "id"), so
        # one of its keys must be a property; the rest must all be.
        unknown = ([path_key].compact + Array(o[:verbatim]) + Array(o[:also]) + o.fetch(:aliases, {}).keys) - properties
        unknown << content_keys.join("/") unless content_keys.empty? || content_keys.intersect?(properties)
        raise ArgumentError, "#{name}: overrides name no schema property: #{unknown.join(", ")}" unless unknown.empty?
        # A property can't set the call's name, nor the fields only chi sets
        # (an alias's called_as, an unwrapped call's via).
        if (reserved = fields & %w[name called_as via]).any?
          raise ArgumentError, "#{name}: a property would replace the call's #{reserved.first}"
        end

        Row.new(name: name, content_keys: content_keys, path_key: path_key, fields: fields,
                aliases: o.fetch(:aliases, {}), verbatim: Array(o[:verbatim]), fallback: o[:fallback],
                fallback_key: o[:fallback_key], options: o.fetch(:options, false))
      end

      # @return [Row, nil]
      def row(name) = rows[name.to_s]

      # The internal call for a parsed one.
      # @param name [String]
      # @param args [Hash] string keys, as the model gave them
      # @param raw [String, nil] the call's text, the content of a tool
      #   that isn't built in when no argument could be read from it
      # @return [Hash]
      def build(name, args, raw: nil)
        name = name.to_s
        args = args.is_a?(Hash) ? args.transform_keys(&:to_s) : {}
        # An alias runs its target (bash → execute); the row is the target's,
        # and the call keeps the model's own spelling on called_as:.
        # Not the target's shape (a String main argument, only its keys) and
        # the alias doesn't take: the call passes through as an unknown tool.
        if (target = ALIASES[name.downcase])
          return aliasable?(row(target), args) ? aliased(name, target, args, raw) : passthrough(name, args, raw)
        end

        row = row(name)
        return passthrough(name, args, raw) unless row

        call = { name: name, content: "", path: nil, scope: nil }
        call[:content] = content_value(row, args)
        call[:path] = value(row, args, row.path_key) if row.path_key
        row.fields.each { |key| call[key.to_sym] = value(row, args, key) }
        call[:options] = options(call[:options]) if row.options
        call
      end

      # A saved call as it ran (a reload, the stale-read pairing): a call_tool
      # of a built-in ("chi/delegate", or a bare "delegate") is that
      # built-in's call with via: "call_tool" when +output+ (its saved
      # result) shows it ran as that built-in: its "[name]" lead, or, with
      # no lead, an error that names it (refused by its name before the
      # gate); any other call as it is (a call_tool that ran, refused or
      # not, leads with "[call_tool]").
      # @param call [Hash] as #build gives it
      # @param output [String, nil]
      # @return [Hash]
      def unwrap_saved(call, output)
        return call unless call[:name] == VIA && call[:args].is_a?(Hash)

        name = call[:args]["tool"].to_s.strip.delete_prefix(VIA_GROUP)
        return call unless row(name) && ran_as?(output.to_s, name)

        build(name, saved_args(call[:args]["args"])).merge(via: VIA)
      end

      # A saved direct call of a deferred source tool (an MCP tool by its
      # acts_as, on a host that loads tools) as the call_tool call it ran as
      # (ToolIndex#wrap): a name that is no built-in, object args, and a
      # result that leads with "[call_tool]". Any other call as it is. The
      # tool is named by its acts_as (the call tool takes it as well).
      # @param call [Hash] as #build gives it
      # @param output [String, nil]
      # @return [Hash]
      def wrap_saved(call, output)
        name = call[:name].to_s
        return call if name.empty? || name == VIA || row(name) || !call[:args].is_a?(Hash)
        return call unless output.to_s[SAVED_LEAD, 1] == VIA

        build(VIA, { "tool" => name, "args" => call[:args] })
      end

      def ran_as?(output, name)
        lead = output[SAVED_LEAD, 1]
        lead ? lead == name : output.start_with?("Error: #{name} ")
      end

      # call_tool's inner args as saved: an object, or its JSON text.
      def saved_args(args)
        args = JSON.parse(args) if args.is_a?(String) && !args.strip.empty?
        args.is_a?(Hash) ? args : {}
      rescue JSON::ParserError
        {}
      end

      # An execute-shaped call the model spelled +name+: built as its +target+,
      # tagged with the model's spelling for the activity event and the log.
      def aliased(name, target, args, raw)
        call = build(target, args, raw: raw)
        call[:called_as] = name
        call
      end

      # The alias gate: a String main argument, and every key one the target's
      # schema knows (its aliases included). More, or differently shaped, the
      # call is the model's own and passes through as an unknown tool.
      def aliasable?(row, args)
        return false unless row

        row.content_keys.map { |key| value(row, args, key) }.any?(String) &&
          (args.keys - (row.content_keys + [row.path_key].compact + row.fields + row.aliases.keys)).empty?
      end

      def content_value(row, args)
        found = row.content_keys.lazy.map { |key| value(row, args, key) }.find { |v| !v.nil? }
        found.nil? ? "" : found.to_s
      end

      # The first given value among +key+ and its aliases, stripped unless
      # verbatim; nil when none is given.
      def value(row, args, key)
        found = row.keys_for(key).lazy.map { |k| args[k] }.find { |v| !v.nil? }
        found.is_a?(String) && !row.verbatim.include?(key) ? found.strip : found
      end

      # Normalized when they read as options, else as given (the question
      # card's validate reads them again).
      def options(raw)
        normalized = AskUserQuestion.normalize_options_lenient(raw)
        normalized.empty? ? raw : normalized
      end

      def passthrough(name, args, raw)
        { name: name, content: passthrough_content(args, raw), path: nil, scope: nil, args: args }
      end

      # The arguments as JSON, one form for every model format and Ruby
      # version; the raw text when none could be read from it.
      def passthrough_content(args, raw)
        return raw.to_s if args.empty? && !raw.to_s.empty?

        JSON.generate(args)
      rescue JSON::GeneratorError
        args.values.join(" ")
      end
    end
  end
end
