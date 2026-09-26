# frozen_string_literal: true

require_relative "../log"

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
      # frozen Hash, symbol keys, as the parsers give them) and the Context,
      # and returns the result text ("Error: …" marks a failure). A raise is
      # the model's "Error: <message>".
      # @param name [String] a-z, 0-9 and _; a name the session already has
      #   is a load error
      # @param params [Hash] name => {type:, description:, required:}
      # @param label [String, nil] the activity line's action
      # @param preview [#call, nil] args → the activity line's params
      # @param targets [#call, nil] args → what guardrail rules match (P3)
      def tool(name, description, params: {}, label: nil, preview: nil, targets: nil, &block)
        raise ArgumentError, "tool #{name.inspect} needs a block" unless block
        name = name.to_s
        raise ArgumentError, "tool name #{name.inspect} must be a-z, 0-9 and _ (at most 48)" unless name.match?(TOOL_NAME)
        if (taken = @registries.tools[name])
          raise ArgumentError, "tool #{name} is already registered (#{taken.source})"
        end
        raise ArgumentError, "tool #{name} is registered twice" if @tools.any? { |tool| tool[:name] == name }
        raise ArgumentError, "tool #{name}: preview must respond to #call" if preview && !preview.respond_to?(:call)
        raise ArgumentError, "tool #{name}: targets must respond to #call" if targets && !targets.respond_to?(:call)

        @tools << { name: name, schema: tool_schema(name, description, params), label: label&.to_s, preview: preview,
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
          @registries.tools.register(
            tool[:name], schema: tool[:schema], source: @bundle, label: tool[:label],
                         handler: lambda { |call, _kctx|
                           result = block.call(Api.args_of(call), context)
                           result.nil? ? "" : result.to_s
                         },
                         preview: preview && ->(call) { preview.call(Api.args_of(call))&.to_s },
                         targets: targets && ->(call) { targets.call(Api.args_of(call)) }
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

      # A tool call's arguments as a plugin sees them: the parsed call
      # without its name, frozen.
      def self.args_of(call)
        call.reject { |key, _| key == :name }.freeze
      end

      private

      # {name:, description:, parameters:} as in ToolDeclarations::TOOL_SCHEMAS.
      def tool_schema(name, description, params)
        raise ArgumentError, "tool #{name}: params must be a Hash" unless params.is_a?(Hash)

        required = []
        properties = params.each_with_object({}) do |(param, spec), acc|
          param = param.to_s
          raise ArgumentError, "tool #{name}: parameter name #{param.inspect} is not a plain word" unless param.match?(PARAM_NAME)
          raise ArgumentError, "tool #{name}: parameter #{param} must be a Hash {type:, description:}" unless spec.is_a?(Hash)

          spec = spec.transform_keys(&:to_sym)
          required << param if spec[:required]
          acc[param.to_sym] = { type: (spec[:type] || "string").to_s, description: spec[:description].to_s }
        end
        { name: name, description: description.to_s, parameters: { type: "object", properties: properties, required: required } }
      end
    end
  end
end
