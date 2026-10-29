# frozen_string_literal: true

require_relative "../toolkit"
require_relative "../log"
require_relative "../hooks/registry"
require_relative "../commands/registry"
require_relative "service"
require_relative "tool_result"
require_relative "tool_spec"
require_relative "prompt_sections"

module Samagotchi
  module Plugin
    # What a plugin's #register(chi) gets (docs/plugins.md). Each call
    # stages a registration and checks it; Loader commits them all once
    # #register returns, so a plugin that raises halfway adds nothing.
    class Api
      COMMAND_NAME = %r{\A/[a-z][a-z0-9_-]{0,31}\z}
      ANNOTATION_LABEL_MAX = 40
      ANNOTATIONS_MAX = 5

      # The first chi release with each call a plugin may make (from git:
      # the first release tag holding it), for `chi bundle check`'s
      # requires-chi-floor: a bundle whose requires_chi admits an older chi.
      # A call not listed gets no floor check: it is in the first tag (v0.2.0:
      # chi.command/tool/on/service/init, ctx.settings, ctx.sessions,
      # ctx.ask_model, ctx.notify, ctx.card, ctx.messages…). A member of
      # one (ctx.sessions.children) is listed when it came later; fork, send
      # and read are in v0.2.0. Keys have no "?" (API_CALL drops it). A
      # keyword added later is "call(keyword:)", the call's receiver as the
      # plugin writes it (Check#keyword_calls: `ctx.sessions.send(…,
      # delivery:)` is seen, a `sessions = ctx.sessions` alias isn't).
      # Events aren't listed: chi.on takes any symbol and an older chi never
      # fires one it doesn't know (harmless; chi bundle check warns on it),
      # and a manifest hook's events: list (BundleHook) needs the bundle's
      # requires_chi set by hand (docs/hooks.md, Bundle Hooks): no source
      # scan covers manifest.yml.
      SINCE = {
        "ctx.steer" => "0.3.0", "ctx.stop_turn" => "0.3.0", "ctx.stop_generation" => "0.6.0",
        "Samagotchi::AtomicFile" => "0.8.0", "ctx.model" => "0.17.0", "ctx.model_key" => "0.17.0",
        "ctx.context" => "0.32.0", "ctx.delegate" => "0.32.0", "ctx.scratch" => "0.32.0",
        "fallback_for:" => "0.35.0", "ctx.fork" => "0.45.0", "ctx.frontend" => "0.49.0",
        "ctx.prompt_files" => "0.60.0", "chi.annotation" => "0.66.0", "chi.toolkit" => "0.66.0",
        "ctx.use_toolkit" => "0.66.0", "ctx.toolkit" => "0.66.0", "ctx.declared_tools" => "0.66.0",
        "chi.tool_source" => "0.67.0", "chi.peer_source" => "0.67.0", "ctx.http" => "0.80.0",
        "ctx.cost" => "0.83.0", "ctx.sessions.children" => "0.34.0", "ctx.load_tools" => "0.99.0",
        "ctx.usage" => "0.100.0", "ctx.sessions.stop" => "0.34.0", "ctx.turn_author" => "0.106.0",
        "ctx.sessions.review" => "0.107.0", "ctx.sessions.send(delivery:)" => "0.64.0",
        "chi.toolkit(prompt:)" => "0.72.0", "ctx.ask_model(model:)" => "0.80.0", "chi.toolkit(groups:)" => "0.121.0",
        "chi.prompt_section" => "0.132.0", "chi.prompt_changed" => "0.132.0", "ctx.cache_confirm" => "0.132.0",
        "ctx.model_names" => "0.132.0"
      }.freeze

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
        @annotations = []
        @tools = []
        @services = []
        @inits = []
        @toolkits = []
        @prompt_sections = []
        @peer_sources = []
        @tool_source = nil
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

      # A pill in the web's selection bar: it prepares +command+ (a command
      # line) with +template+ filled from the selected text on the lines
      # under it ({quote}: the labelled quote block Annotate makes, {text}:
      # the selection alone, {source}: answer, thinking, step, tool or
      # user), and fills the composer with it, or sends it at once with
      # +send+ (docs/plugins.md). Web only.
      # @param label [String] the pill's text, 1–40 characters
      # @param command [String] "/name" or "/name words": a command this
      #   plugin registers (checked once #register returns, so the order
      #   doesn't matter; another's is a load error)
      # @param template [String] what goes under the command line
      # @param send [Boolean] send at once instead of filling the composer
      def annotation(label, command:, template: "{quote}", send: false)
        label = label.to_s.strip
        unless label.length.between?(1, ANNOTATION_LABEL_MAX)
          raise ArgumentError, "annotation label #{label.inspect} must be 1 to #{ANNOTATION_LABEL_MAX} characters"
        end

        line = command.to_s.strip
        name = line.split(/\s/, 2).first.to_s
        raise ArgumentError, "annotation #{label}: command #{line.inspect} must start with a /name" unless name.match?(COMMAND_NAME)
        raise ArgumentError, "annotation #{label}: template must be a non-blank String" unless template.is_a?(String) && !template.strip.empty?
        raise ArgumentError, "at most #{ANNOTATIONS_MAX} annotations per plugin" if @annotations.size >= ANNOTATIONS_MAX

        @annotations << { name: name, annotation: Commands::Registry::Annotation.new(label: label, line: line, template: template,
                                                                                     sends: send ? true : false) }
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
      # @param refs [#call, nil] args → the call's row's refs, display only:
      #   a list of {kind:, target:, label:, actions:} (RowRefs, Ref). Run
      #   once per call on the tool path, so it must be cheap (no I/O)
      def tool(name, description, **, &)
        spec = ToolSpec.build(name, description, **, &)
        if (taken = @registries.tools[spec.name])
          raise ArgumentError, "tool #{spec.name} is already registered (#{taken.source})"
        end
        raise ArgumentError, "tool #{spec.name} is registered twice" if @tools.any? { |tool| tool.name == spec.name }

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
        elsif ToolSpec.apply(@registries.tools, @bundle, set.specs, @context)[:changed]
          tools_changed!
        end
        nil
      end

      # What #replace_tools' block declares tools on.
      class ToolSet
        # @return [Array<ToolSpec>]
        attr_reader :specs

        def initialize
          @specs = []
        end

        # As Api#tool.
        def tool(name, description, **, &)
          spec = ToolSpec.build(name, description, **, &)
          raise ArgumentError, "tool #{spec.name} is registered twice" if @specs.any? { |s| s.name == spec.name }

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

      # Text this session's system prompt carries (docs/plugins.md, Prompt
      # sections): the block gets the Context and returns a String (at most
      # PromptSections::MAX characters) or nil for none. It runs when the
      # prompt is built (a session's first turn, after /model or a
      # #prompt_changed!), never per request, on whatever thread builds:
      # keep it quick (no I/O beyond reading a small file) and give the same
      # text for the same inputs. A raise, a non-String or text over the
      # limit keeps the section's last good text (one warn).
      # @param name [String] a-z, 0-9, _ and -; unique in the bundle
      def prompt_section(name, &block)
        raise ArgumentError, "prompt_section #{name.inspect} needs a block" unless block

        name = name.to_s
        unless name.match?(PromptSections::NAME)
          raise ArgumentError, "prompt section name #{name.inspect} must be a-z, 0-9, _ and - (at most 32)"
        end
        raise ArgumentError, "this chi has no prompt sections (plugins: false)" unless @registries.prompt_sections
        if @prompt_sections.any? { |item| item[:name] == name } || @registries.prompt_sections.registered?(@bundle, name)
          raise ArgumentError, "prompt section #{name} is registered twice"
        end

        @prompt_sections << { name: name, block: block }
        nil
      end

      # Say this session's prompt sections would now give other text (a
      # setting the plugin keeps changed): the system prompt is built again
      # at its next build (the next turn's start; a running turn keeps the
      # prompt it started with). That restarts the model server's prompt
      # cache, so a command that changes a section asks first
      # (Context#cache_confirm) and calls this only once it applies.
      def prompt_changed!
        @registries.prompt_changed&.call
        nil
      end

      # Publish tools into the session's tool index instead of declaring
      # them one by one (docs/plugins.md, "Publishing tools to the index"):
      # the model searches them with find_tools and calls one with
      # call_tool (<group>/<tool>), which chi declares once, after the
      # plugins load, when a source registered. Returns the source: its
      # #publish(groups) (ToolIndex::Group values, each with its
      # ToolIndex::Tool values) swaps in the plugin's whole list, from any
      # thread, at any time, and changes only what searches answer.
      # @param label [String] the call tool's row label (default: the bundle)
      # @param call [#call] (tool, args, ctx) → the call's result, as a
      #   tool's block returns it; +tool+ a ToolIndex::Tool the index looked
      #   up and checked, +args+ typed by its schema
      # @param acts_as [#call] (group, tool) → the name guardrail rules
      #   match for a tool from its names alone (one not published yet)
      # @param wait [#call, nil] (group) waits for a :starting group's start
      # @param prefix [String, nil] a bare name with it is taken as an
      #   acts_as as given
      # @return [Tools::ToolIndex::Source]
      def tool_source(call:, acts_as:, label: @bundle, wait: nil, prefix: nil)
        raise ArgumentError, "this chi has no tool index (plugins: false)" unless @registries.tool_index
        raise ArgumentError, "tool_source is declared twice" if @tool_source

        @tool_source = @registries.tool_index.source(label: label, call: call, acts_as: acts_as, wait: wait,
                                                     prefix: prefix, context: @context)
      end

      TOOLKIT_NAME = /\A[a-z][a-z0-9_-]{0,31}\z/

      # A named toolkit sessions can be put on (/toolkit NAME, chi --toolkit,
      # toolkit.default, ctx.use_toolkit): +base+'s tools (a toolkit chi or
      # a bundle has) with +add+ declared and +remove+ left out, and
      # +prompt+: text the sessions on it get in their system prompt (nil:
      #   its base's, "" none; at most Toolkit::PROMPT_MAX characters);
      #   +groups+: MCP source group names/globs (nil inherits its base);
      #   +description+: optional classifier text, not included in prompts
      #   (at most Toolkit::DESCRIPTION_MAX characters).
      #   A
      # name chi (full, lean, child) or another bundle has is a load error,
      # and so is a prompt that isn't text or is too long; a base that
      # doesn't resolve leaves the sessions on it with every tool
      # (Toolkit#resolve).
      def toolkit(name, base:, add: [], remove: [], prompt: nil, groups: nil, description: nil)
        name = name.to_s
        raise ArgumentError, "toolkit name #{name.inspect} must be a-z, 0-9, _ and -" unless name.match?(TOOLKIT_NAME)

        problem = Toolkit.prompt_error(prompt) || Toolkit.description_error(description) ||
                  (Toolkit.groups_error(groups) unless groups == :all)
        raise ArgumentError, "toolkit #{name}: #{problem}" if problem
        raise ArgumentError, "this chi has no toolkits (plugins: false)" unless @registries.toolkits
        if Toolkit::BUILTIN_KITS.key?(name)
          raise ArgumentError, "toolkit #{name} is chi's own"
        elsif (taken = @registries.toolkits.find { |kit| kit.name == name })
          raise ArgumentError, "toolkit #{name} is already declared (#{taken.source})"
        end
        raise ArgumentError, "toolkit #{name} is declared twice" if @toolkits.any? { |kit| kit.name == name }

        @toolkits << Toolkit::Kit.new(name: name, base: base, add: add, remove: remove, prompt: prompt,
                                      groups: groups, source: @bundle, description: description)
        nil
      end

      # A context source that holds a peer agent's answers (the peer
      # bundles' claude-outbox, codex-outbox): +label+ is the peer's name
      # ("Codex", PeerSources::LABEL), said in chi's own lines. Such a
      # source, when it is a pushed one of the session's own, wakes on
      # context.peer_turns rather than the 10-minute window, with the peer
      # line, or the closing line for an answer that agrees (docs/context.md,
      # Waking). Declared here, in-process, never by
      # a source file; gone with the bundle.
      def peer_source(name, label:)
        raise ArgumentError, "this chi has no peer sources (plugins: false)" unless @registries.peer_sources

        name = @registries.peer_sources.check!(name, label: label, bundle: @bundle)
        raise ArgumentError, "peer source #{name} is declared twice" if @peer_sources.any? { |item| item[:name] == name }

        @peer_sources << { name: name, label: label.to_s }
        nil
      end

      # Register what was staged. Called by Loader after #register. What
      # can only be checked now (an annotation's command) is checked before
      # anything is registered: a raise here leaves the registries as they were.
      def commit!
        check_annotations!
        @peer_sources.each { |item| @registries.peer_sources.check!(item[:name], label: item[:label], bundle: @bundle) }
        context = @context
        @commands.each do |cmd|
          block = cmd[:block]
          annotations = @annotations.select { |item| item[:name] == cmd[:name] }.map { |item| item[:annotation] }
          @registries.commands.register(cmd[:name], cmd[:description], anytime: cmd[:anytime], source: @bundle,
                                                                       annotations: annotations) do |args|
            block.call(args, context)
          end
        end
        @tools.each { |tool| @registries.tools.register(tool.name, source: @bundle, **tool.entry_fields(context)) }
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
        @registries.toolkits&.concat(@toolkits)
        @prompt_sections.each do |item|
          @registries.prompt_sections.add(bundle: @bundle, name: item[:name], context: context, &item[:block])
        end
        @registries.tool_index.add(@tool_source) if @tool_source
        @peer_sources.each { |item| @registries.peer_sources.declare(item[:name], label: item[:label], bundle: @bundle) }
        @committed = true
      end

      # @return [Hash] how many of each it registered (for the log)
      def counts = { commands: @commands.size, annotations: @annotations.size, tools: @tools.size, hooks: @hooks.size,
                     services: @services.size, inits: @inits.size, toolkits: @toolkits.size,
                     prompt_sections: @prompt_sections.size,
                     tool_sources: @tool_source ? 1 : 0, peer_sources: @peer_sources.size }

      # Each annotation's command is one #command staged.
      def check_annotations!
        names = @commands.map { |cmd| cmd[:name] }
        @annotations.each do |item|
          next if names.include?(item[:name])

          raise ArgumentError, "annotation #{item[:annotation].label}: #{item[:name]} is not a command this plugin registers"
        end
      end
      private :check_annotations!

      # A checked tool declaration (ToolSpec.build), for bundles: the mcp
      # bundle's token estimate calls it, installed ones included.
      # @return [ToolSpec]
      def self.tool_spec(...) = ToolSpec.build(...)
    end
  end
end
