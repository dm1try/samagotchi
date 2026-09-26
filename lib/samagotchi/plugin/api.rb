# frozen_string_literal: true

require_relative "../log"
require_relative "../tools/args"

module Samagotchi
  module Plugin
    # What a plugin's #register(chi) gets (docs/plugins.md). Each call
    # stages a registration and checks it; Loader commits them all once
    # #register returns, so a plugin that raises halfway adds nothing.
    class Api
      COMMAND_NAME = %r{\A/[a-z][a-z0-9_-]{0,31}\z}
      TOOL_NAME = /\A[a-z][a-z0-9_]{0,47}\z/
      PARAM_NAME = /\A[a-z_][a-z0-9_]*\z/i

      # @param bundle [String]
      # @param label [String] "<file> (bundle <name>)": what hooks and
      #   failures are named by
      # @param registries [Registries]
      # @param context [Context, nil] what handlers get as ctx
      def initialize(bundle:, label:, registries:, context: nil)
        @bundle = bundle
        @label = label
        @registries = registries
        @context = context
        @hooks = []
        @commands = []
        @tools = []
      end

      # A slash command the session runs: the block gets the text after the
      # name (stripped, "" for none) and the Context, and returns what to
      # show (a String) or nil for nothing. A raise is shown as an error.
      # @param name [String] "/name"; a name the session already has
      #   (built-in or another bundle's) is a load error
      # @param anytime [Boolean] may run while a turn runs (from P2; today
      #   it runs as other commands do)
      def command(name, description, anytime: false, &block)
        raise ArgumentError, "command #{name.inspect} needs a block" unless block
        name = name.to_s
        raise ArgumentError, "command name #{name.inspect} must look like /name (a-z, 0-9, _ and -)" unless name.match?(COMMAND_NAME)
        if (taken = @registries.commands.entries.find { |entry| entry.name == name })
          raise ArgumentError, "command #{name} is already registered (#{taken.source})"
        end
        raise ArgumentError, "command #{name} is registered twice" if @commands.any? { |cmd| cmd[:name] == name }

        @commands << { name: name, description: description.to_s, anytime: anytime ? true : false, block: block }
        nil
      end

      # A tool the model can call: the block gets the call's arguments (a
      # frozen Hash, string keys, typed by the schema: see Tools::Args) and
      # the Context, and returns the result text ("Error: …" marks a
      # failure). A raise is the model's "Error: <message>".
      # @param name [String] a-z, 0-9 and _; a name the session already has
      #   is a load error
      # @param params [Hash] name => a JSON Schema property ({type:,
      #   description:, enum:, items:, properties:, …}) plus required: true
      # @param schema [Hash, nil] instead of params: the parameters as one
      #   JSON Schema object ({type: "object", properties:, required: […]}),
      #   an MCP server's inputSchema for example
      # @param label [String, nil] the activity line's action
      # @param preview [#call, nil] args → the activity line's params
      # @param targets [#call, nil] args → what guardrail rules match: a Hash
      #   with paths: (absolute or relative to the cwd), command: (a shell
      #   command) and cwd:, each optional
      def tool(name, description, params: {}, schema: nil, label: nil, preview: nil, targets: nil, &block)
        raise ArgumentError, "tool #{name.inspect} needs a block" unless block
        name = name.to_s
        raise ArgumentError, "tool name #{name.inspect} must be a-z, 0-9 and _ (at most 48)" unless name.match?(TOOL_NAME)
        if (taken = @registries.tools[name])
          raise ArgumentError, "tool #{name} is already registered (#{taken.source})"
        end
        raise ArgumentError, "tool #{name} is registered twice" if @tools.any? { |tool| tool[:name] == name }
        raise ArgumentError, "tool #{name}: preview must respond to #call" if preview && !preview.respond_to?(:call)
        raise ArgumentError, "tool #{name}: targets must respond to #call" if targets && !targets.respond_to?(:call)

        parameters = schema ? schema_parameters(name, schema) : params_schema(name, params)
        @tools << { name: name, schema: { name: name, description: description.to_s, parameters: parameters },
                    label: label&.to_s, preview: preview,
                    targets: targets, block: block }
        nil
      end

      # Run the block on a hook event (docs/hooks.md: :before_turn,
      # :after_turn, :before_tool_call, …), like a bundle's hooks/*.rb:
      # the block gets the event hash, with event[:notify] and the other
      # helpers, and the Context (a block may take the event alone). A
      # block that raises is logged (not shown) and skipped.
      # @param priority [Integer] lower runs first among bundle hooks
      def on(event, priority: 100, &block)
        raise ArgumentError, "on(#{event.inspect}) needs a block" unless block
        raise ArgumentError, "on: the event must be a Symbol or String" unless event.is_a?(Symbol) || event.is_a?(String)

        @hooks << { event: event.to_sym, priority: Integer(priority), block: block }
        nil
      end

      # Say the session's tools changed after #register (a plugin that
      # registers tools late): the system prompts are built again for the
      # next turn, so the model sees the new set. That costs the server its
      # cached prompt prefix once, so call it only when the set changed.
      def tools_changed!
        @registries.tools_changed&.call
        nil
      end

      # Register what was staged. Called by Loader after #register.
      def commit!
        context = @context
        @commands.each do |cmd|
          block = cmd[:block]
          @registries.commands.register(cmd[:name], cmd[:description], anytime: cmd[:anytime], source: @bundle) do |args|
            block.call(args, context)
          end
        end
        @tools.each do |tool|
          block = tool[:block]
          preview = tool[:preview]
          targets = tool[:targets]
          parameters = tool[:schema][:parameters]
          @registries.tools.register(
            tool[:name], schema: tool[:schema], source: @bundle, label: tool[:label],
                         handler: lambda { |call, _kctx|
                           result = block.call(Api.args_of(call, parameters), context)
                           result.nil? ? "" : result.to_s
                         },
                         preview: preview && ->(call) { preview.call(Api.args_of(call, parameters))&.to_s },
                         targets: targets && ->(call) { targets.call(Api.args_of(call, parameters)) }
          )
        end
        @hooks.each do |hook|
          bundle = @bundle
          label = @label
          block = hook[:block]
          context = @context
          @registries.hooks.register_bundle(bundle, hook[:event], hook_name: label.split(" ").first,
                                                                  priority: hook[:priority]) do |event|
            block.call(event, context)
          rescue StandardError => e
            # Logged only: a turn's live region is on screen.
            Log.warn(:plugins, "plugin_hook_failed", bundle: bundle, event: hook[:event].to_s, error: e.class.name,
                                                     msg: "#{label} #{hook[:event]} hook failed: #{e.message}")
          end
        end
      end

      # @return [Hash] how many of each it registered (for the log)
      def counts = { commands: @commands.size, tools: @tools.size, hooks: @hooks.size }

      # A tool call's arguments as a plugin sees them: the parsers' args:
      # (a call built without one, in a spec say: the call without its
      # name), string keys, typed by +parameters+, frozen.
      def self.args_of(call, parameters = nil)
        given = call[:args].is_a?(Hash) ? call[:args] : call.reject { |key, _| key == :name || key == :args }
        Tools::Args.coerce(given, parameters).freeze
      end

      # A JSON Schema with symbol keys (property names included), as
      # ToolDeclarations::TOOL_SCHEMAS has them.
      def self.symbolize(value)
        case value
        when Hash then value.to_h { |key, item| [key.to_sym, symbolize(item)] }
        when Array then value.map { |item| symbolize(item) }
        else value
        end
      end

      private

      # The parameters object from params: (name => property spec).
      def params_schema(name, params)
        raise ArgumentError, "tool #{name}: params must be a Hash" unless params.is_a?(Hash)

        required = []
        properties = params.each_with_object({}) do |(param, spec), acc|
          param = param.to_s
          raise ArgumentError, "tool #{name}: parameter name #{param.inspect} is not a plain word" unless param.match?(PARAM_NAME)
          raise ArgumentError, "tool #{name}: parameter #{param} must be a Hash {type:, description:}" unless spec.is_a?(Hash)

          spec = Api.symbolize(spec)
          required << param if spec.delete(:required) == true
          acc[param.to_sym] = { type: (spec.delete(:type) || "string").to_s, description: spec.delete(:description).to_s }.merge(spec)
        end
        { type: "object", properties: properties, required: required }
      end

      # The parameters object from schema: (a JSON Schema object).
      def schema_parameters(name, schema)
        raise ArgumentError, "tool #{name}: schema must be a Hash" unless schema.is_a?(Hash)

        schema = Api.symbolize(schema)
        raise ArgumentError, "tool #{name}: schema must be {type: \"object\", properties: {…}}" unless schema.fetch(:type, "object").to_s == "object"

        properties = schema[:properties] || {}
        raise ArgumentError, "tool #{name}: schema properties must be a Hash" unless properties.is_a?(Hash)

        { type: "object", properties: properties, required: Array(schema[:required]).map(&:to_s) }
          .merge(schema.except(:type, :properties, :required))
      end
    end
  end
end
