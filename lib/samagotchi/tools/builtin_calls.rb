# frozen_string_literal: true

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
    # by its schema at dispatch, Tools::Args) with +raw+ as its content.
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
        "edit" => { verbatim: %w[old_text new_text], aliases: { "old_text" => %w[old], "new_text" => %w[new] },
                    blob: true },
        "task_create" => { content: "command", verbatim: %w[env], fallback: :prefix_or_raw },
        "task_get" => { content: %w[id task_id], fallback: :prefix_or_raw },
        "task_stop" => { content: %w[id task_id], fallback: :prefix_or_raw },
        "task_wait" => { content: %w[id task_id], fallback: :prefix_or_raw },
        "web_fetch" => { content: "url", fallback: :prefix_or_raw },
        "register_reminder" => { content: "name", fallback: :prefix_or_raw },
        "cancel_reminder" => { content: "name", fallback: :prefix_or_raw },
        "list_sessions" => { fallback: :prefix, fallback_key: "cwd" },
        "send_note" => { content: "text" },
        "delegate" => { content: "task", fallback: :prefix_or_raw },
        "ask_user_question" => { content: "question", also: %w[question], verbatim: %w[options], options: true,
                                 fallback: :raw }
      }.freeze

      # One built-in's mapping, resolved from its schema and OVERRIDES.
      Row = Data.define(:name, :content_keys, :path_key, :fields, :aliases, :verbatim, :fallback, :fallback_key,
                        :options, :blob) do
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
        @rows ||= ToolDeclarations::TOOL_SCHEMAS.to_h { |schema| [schema[:name], row_for(schema)] }.freeze
      end

      def row_for(schema)
        name = schema[:name]
        o = OVERRIDES.fetch(name, {})
        properties = schema.dig(:parameters, :properties).keys.map(&:to_s)
        content_keys = Array(o[:content])
        path_key = o[:path] || ("path" if properties.include?("path") && !content_keys.include?("path"))
        taken = content_keys + [path_key].compact - Array(o[:also])
        fields = properties - taken - (o[:blob] ? %w[old_text new_text] : [])
        # content: may list a model's other spelling (task_wait's "id"), so
        # one of its keys must be a property; the rest must all be.
        unknown = ([path_key].compact + Array(o[:verbatim]) + Array(o[:also]) + o.fetch(:aliases, {}).keys) - properties
        unknown << content_keys.join("/") unless content_keys.empty? || content_keys.intersect?(properties)
        raise ArgumentError, "#{name}: overrides name no schema property: #{unknown.join(', ')}" unless unknown.empty?
        raise ArgumentError, "#{name}: a property would replace the call's name" if fields.include?("name")

        Row.new(name: name, content_keys: content_keys, path_key: path_key, fields: fields,
                aliases: o.fetch(:aliases, {}), verbatim: Array(o[:verbatim]), fallback: o[:fallback],
                fallback_key: o[:fallback_key], options: o.fetch(:options, false), blob: o.fetch(:blob, false))
      end

      # @return [Row, nil]
      def row(name) = rows[name.to_s]

      def builtin?(name) = rows.key?(name.to_s)

      # The internal call for a parsed one.
      # @param name [String]
      # @param args [Hash] string keys, as the model gave them
      # @param raw [String, nil] the call's text, the content of a tool
      #   that isn't built in
      # @return [Hash]
      def build(name, args, raw: nil)
        name = name.to_s
        args = args.is_a?(Hash) ? args.transform_keys(&:to_s) : {}
        row = row(name)
        return passthrough(name, args, raw) unless row

        call = { name: name, content: "", path: nil, scope: nil }
        call[:content] = content_value(row, args)
        call[:path] = value(row, args, row.path_key) if row.path_key
        row.fields.each { |key| call[key.to_sym] = value(row, args, key) }
        call[:content] = blob(row, args) if row.blob
        call[:options] = options(call[:options]) if row.options
        call
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

      def blob(row, args)
        "<old>#{value(row, args, 'old_text')}</old><new>#{value(row, args, 'new_text')}</new>"
      end

      # Normalized when they read as options, else as given (the question
      # card's validate reads them again).
      def options(raw)
        normalized = AskUserQuestion.normalize_options_lenient(raw)
        normalized.empty? ? raw : normalized
      end

      def passthrough(name, args, raw)
        { name: name, content: raw.nil? ? args.values.join(" ") : raw.to_s, path: nil, scope: nil, args: args }
      end
    end
  end
end
