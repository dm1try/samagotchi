# frozen_string_literal: true

require "json"
require_relative "../log"
require_relative "../hooks/registry"
require_relative "../tools/args"
require_relative "service"
require_relative "tool_result"

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
        @services = []
        @inits = []
        @committed = false
      end

      # The Context the plugin's handlers get, for #register itself: its
      # settings, log, data_dir, and ctx.notify / ctx.card, which, shown
      # while chi starts, wait for the first turn (beside the plugins' load
      # warnings).
      # @return [Context, nil]
      def ctx = @context

      # A slash command the session runs: the block gets the text after the
      # name (stripped, "" for none) and the Context, and returns what to
      # show (a String) or nil for nothing. A raise is shown as an error.
      # @param name [String] "/name"; a name the session already has
      #   (built-in or another bundle's) is a load error
      # @param anytime [Boolean] runs at once on its own thread, beside a
      #   running turn, instead of being refused as busy (docs/plugins.md)
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
      def tool(name, description, params: {}, schema: nil, label: nil, preview: nil, targets: nil, &)
        spec = Api.tool_spec(name, description, params: params, schema: schema, label: label, preview: preview,
                                                targets: targets, &)
        if (taken = @registries.tools[spec[:name]])
          raise ArgumentError, "tool #{spec[:name]} is already registered (#{taken.source})"
        end
        raise ArgumentError, "tool #{spec[:name]} is registered twice" if @tools.any? { |tool| tool[:name] == spec[:name] }

        @tools << spec
        nil
      end

      # The plugin's whole tool set, after #register (a plugin whose tools
      # are known only later: an MCP server that listed them). The block
      # gets a set whose #tool takes #tool's arguments; what it declares
      # replaces the plugin's tools from the next turn on: its tools not in
      # the set go, new or changed ones are registered, and the system
      # prompts are built again if anything changed. Safe from any thread:
      # the set is staged, and the turn thread applies it before the
      # turn's first model request. A name another bundle (or chi) has is
      # left out, with a notice.
      # @raise [ArgumentError] a bad tool (as #tool), or called in #register
      def replace_tools
        raise ArgumentError, "replace_tools needs a block" unless block_given?
        raise ArgumentError, "replace_tools is for after register (use chi.tool there)" unless @committed

        set = ToolSet.new
        yield set
        if (stage = @registries.stage_tools)
          stage.call(@bundle, set.specs, @context)
        elsif Api.apply_tools(@registries.tools, @bundle, set.specs, @context)[:changed]
          tools_changed!
        end
        nil
      end

      # What #replace_tools' block declares tools on.
      class ToolSet
        # @return [Array<Hash>]
        attr_reader :specs

        def initialize
          @specs = []
        end

        # As Api#tool.
        def tool(name, description, params: {}, schema: nil, label: nil, preview: nil, targets: nil, &)
          spec = Api.tool_spec(name, description, params: params, schema: schema, label: label, preview: preview,
                                                  targets: targets, &)
          raise ArgumentError, "tool #{spec[:name]} is registered twice" if @specs.any? { |s| s[:name] == spec[:name] }

          @specs << spec
          nil
        end
      end

      # Run the block on a hook event (docs/hooks.md: :before_turn,
      # :after_turn, :before_tool_call, …), like a bundle's hooks/*.rb:
      # the block gets the event hash and the Context (a block may take the
      # event alone); while it runs, ctx.notify and the other helpers act
      # as this event's (Context#with_event). A block that raises is
      # logged (not shown) and skipped.
      # @param priority [Integer] lower runs first among bundle hooks
      def on(event, priority: 100, &block)
        raise ArgumentError, "on(#{event.inspect}) needs a block" unless block
        raise ArgumentError, "on: the event must be a Symbol or String" unless event.is_a?(Symbol) || event.is_a?(String)

        @hooks << { event: event.to_sym, priority: Integer(priority), block: block }
        nil
      end

      # A long-lived thing the plugin keeps (a server process): the block
      # starts it and returns what #value gives; in it, svc.on_stop { }
      # says how to stop it. It starts on first svc.value, or now with
      # eager: true (a raise then fails the plugin's load, unless the
      # plugin rescues it). The Engine stops its services when it shuts
      # down (the REPL or the session's worker exits), newest first.
      # @param name [String, Symbol] unique in the plugin
      # @return [Service]
      def service(name, eager: false, &block)
        raise ArgumentError, "service #{name.inspect} needs a block" unless block

        name = "#{@bundle}:#{name}"
        raise ArgumentError, "service #{name} is registered twice" if @services.any? { |svc| svc.name == name }
        raise ArgumentError, "this chi has no services (plugins: false)" unless @registries.services

        service = @registries.services.add(Service.new(name, &block))
        @services << service
        service.start if eager
        service
      end

      # Slow setup (downloading a model, indexing a repo, logging in, an
      # MCP server's first start) that must not hold chi's start: the block
      # runs on its own thread once the session's UI can show it, not in
      # #register. It gets the Context (ctx.cancelled? says chi is shutting
      # down) and returns a short summary ("3 tools") or raises (the UIs
      # show a warn card). Every UI shows it running (the label) and done.
      # @param label [String] what it does, shown while it runs
      # @param provides_tools [Boolean] it provides what the plugin's tools
      #   need (its own, or through chi.replace_tools; the mcp bundle's
      #   index of a server's tools): a turn sent meanwhile waits for it
      #   before its first model request, up to +timeout+; a Ctrl-C ends
      #   the wait
      # @param quiet [Boolean] shown only if it fails (a background refresh)
      # @param timeout [Numeric, nil] seconds a turn waits for it (default 60)
      # @param failed [String, nil] the warn card's short title if it raises
      #   ("chrome didn't start"; default "setup failed", the label then
      #   leads the card's body)
      def init(label, provides_tools: false, quiet: false, timeout: nil, failed: nil, &block)
        raise ArgumentError, "init needs a block" unless block
        raise ArgumentError, "init needs a label" if label.to_s.strip.empty?
        raise ArgumentError, "this chi runs no init tasks (plugins: false)" unless @registries.init

        @inits << { label: label.to_s.strip, provides_tools: provides_tools ? true : false, quiet: quiet ? true : false,
                    timeout: timeout && Float(timeout), failed: failed.to_s.strip.empty? ? nil : failed.to_s.strip,
                    block: block }
        nil
      end

      # Stop the services the plugin started: its load failed after all.
      def abort!
        @services.reverse_each(&:stop)
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
        @tools.each { |tool| @registries.tools.register(tool[:name], source: @bundle, **Api.entry_fields(tool, context)) }
        @hooks.each do |hook|
          block = hook[:block]
          # Logged only (echo: false): a turn's live region is on screen.
          handler = Hooks.wrap(label: "#{@label} #{hook[:event]} hook", event: hook[:event], policy: :log,
                               log: [:plugins, "plugin_hook_failed"], echo: false, fields: { bundle: @bundle }) do |event|
            # ctx's helpers act as this event's while the block runs.
            context ? context.with_event(event) { block.call(event, context) } : block.call(event, context)
          end
          @registries.hooks.register_bundle(@bundle, hook[:event], hook_name: @label.split(" ").first,
                                                                   priority: hook[:priority], &handler)
        end
        @inits.each do |init|
          block = init[:block]
          @registries.init.call(@bundle, init[:label], @label, provides_tools: init[:provides_tools], quiet: init[:quiet],
                                                              timeout: init[:timeout], failed: init[:failed]) do
            block.call(context)
          end
        end
        @committed = true
      end

      # @return [Hash] how many of each it registered (for the log)
      def counts = { commands: @commands.size, tools: @tools.size, hooks: @hooks.size, services: @services.size,
                     inits: @inits.size }

      # A checked tool declaration (#tool's arguments).
      # @return [Hash] {name:, schema:, label:, preview:, targets:, block:}
      def self.tool_spec(name, description, params: {}, schema: nil, label: nil, preview: nil, targets: nil, &block)
        raise ArgumentError, "tool #{name.inspect} needs a block" unless block

        name = name.to_s
        raise ArgumentError, "tool name #{name.inspect} must be a-z, 0-9 and _ (at most 48)" unless name.match?(TOOL_NAME)
        raise ArgumentError, "tool #{name}: preview must respond to #call" if preview && !preview.respond_to?(:call)
        raise ArgumentError, "tool #{name}: targets must respond to #call" if targets && !targets.respond_to?(:call)

        parameters = schema ? schema_parameters(name, schema) : params_schema(name, params)
        { name: name, schema: { name: name, description: description.to_s, parameters: parameters },
          label: label&.to_s, preview: preview, targets: targets, block: block }
      end

      # Make +bundle+'s tools in +registry+ the +specs+: its tools not in
      # them go; a new one, or one whose schema or label changed, is
      # registered (a changed one again, in its place: Tools::Registry
      # orders bundle tools by bundle and name); an unchanged one is kept
      # as it is. A name another source has is left out. Called on
      # the turn thread (Engine#apply_staged_tools!).
      # @return [Hash] {changed: Boolean, skipped: [String] (why)}
      def self.apply_tools(registry, bundle, specs, context)
        wanted = specs.to_h { |spec| [spec[:name], spec] }
        changed = false
        registry.entries.each do |entry|
          next unless entry.source == bundle
          next if (spec = wanted[entry.name]) && spec[:schema] == entry.schema && spec[:label] == entry.label

          registry.unregister(entry.name)
          changed = true
        end
        skipped = []
        specs.each do |spec|
          if (taken = registry[spec[:name]])
            skipped << "tool #{spec[:name]} is already registered (#{taken.source})" unless taken.source == bundle
            next
          end

          registry.register(spec[:name], source: bundle, **entry_fields(spec, context))
          changed = true
        end
        { changed: changed, skipped: skipped }
      end

      # Registry#register's keywords for a tool declaration: its block
      # wrapped as a handler (typed args, the Context), preview, targets.
      def self.entry_fields(spec, context)
        block = spec[:block]
        preview = spec[:preview]
        targets = spec[:targets]
        parameters = spec[:schema][:parameters]
        {
          schema: spec[:schema], label: spec[:label],
          handler: lambda { |call, _kctx|
            result = block.call(Api.args_of(call, parameters), context)
            Api.result_text(result)
          },
          preview: preview && ->(call) { preview.call(Api.args_of(call, parameters))&.to_s },
          targets: targets && ->(call) { targets.call(Api.args_of(call, parameters)) }
        }
      end

      # A tool's result as the model reads it: a String (a ToolResult too,
      # with its images) as it is, a Hash or Array as JSON (its #to_s is
      # Hash#inspect, which changes with the Ruby version), else #to_s.
      def self.result_text(result)
        case result
        when String then result
        when Hash, Array then JSON.generate(result)
        else result.to_s
        end
      rescue JSON::GeneratorError
        result.to_s
      end

      # A tool call's arguments as a plugin sees them: the parsers' args:
      # (a call built without one, in a spec say: the call without its
      # name), string keys, typed by +parameters+, frozen.
      def self.args_of(call, parameters = nil)
        given = call[:args].is_a?(Hash) ? call[:args] : call.reject { |key, _| %i[name args].include?(key) }
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

      # The parameters object from params: (name => property spec).
      def self.params_schema(name, params)
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
      private_class_method :params_schema

      # The parameters object from schema: (a JSON Schema object).
      def self.schema_parameters(name, schema)
        raise ArgumentError, "tool #{name}: schema must be a Hash" unless schema.is_a?(Hash)

        schema = Api.symbolize(schema)
        raise ArgumentError, "tool #{name}: schema must be {type: \"object\", properties: {…}}" unless schema.fetch(:type, "object").to_s == "object"

        properties = schema[:properties] || {}
        raise ArgumentError, "tool #{name}: schema properties must be a Hash" unless properties.is_a?(Hash)

        { type: "object", properties: properties, required: Array(schema[:required]).map(&:to_s) }
          .merge(schema.except(:type, :properties, :required))
      end
      private_class_method :schema_parameters
    end
  end
end
