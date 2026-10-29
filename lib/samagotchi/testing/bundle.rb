# frozen_string_literal: true

require_relative "../plugin/loader"
require_relative "../plugin/tool_spec"
require_relative "../hooks"
require_relative "../question_asked"
require_relative "../commands/registry"
require_relative "../session_commands"
require_relative "../tools/builtins"
require_relative "../tools/tool_index"
require_relative "../peer_sources"
require_relative "../toolkit"
require_relative "../guardrails/gate"
require_relative "../memory_bundle/manifest"
require_relative "../memory_bundle/source"
require_relative "../session_setup"
require_relative "sandbox"
require_relative "recorder"
require_relative "host"
require_relative "sessions"
require_relative "fake_http"
require_relative "verdict"
require_relative "recording_api"

module Samagotchi
  module Testing
    # A hook (a plugin's chi.on block or a hook file) raised while the kit
    # fired it: chi would log it and go on, a test fails with it.
    class HookFailed < StandardError
      # @return [Hooks::Failure]
      attr_reader :failure
      # @return [Array<Hooks::Failure>]
      attr_reader :failures

      def initialize(failures)
        @failures = failures.dup.freeze
        @failure = @failures.first
        super(@failures.map do |failure|
          error = failure.error
          "#{failure.hook} raised on #{failure.event}: #{error.class}: #{error.message}"
        end.join("; "))
        set_backtrace(@failure.error.backtrace) if @failure.error.backtrace
      end

      def cause = @failure.error
    end

    # A chi.init the plugin registered: its arguments and block.
    Init = Data.define(:label, :plugin_label, :provides_tools, :quiet, :timeout, :failed, :block)
    # A chi.replace_tools set, staged as chi stages it for the turn thread.
    StagedTools = Data.define(:specs, :context)

    # One bundle loaded for a test through chi's own seams: its plugin
    # through Plugin::Loader.register_file (Plugin::Api, a real
    # Plugin::Context) and its hook files through
    # Hooks::BundleLoader.load_hook_file, into real registries (commands
    # and tools with chi's built-ins in them, so a name clash fails as in
    # chi). Only the edges are recorded: the Host and hook Runtime
    # (Recorder), ctx.sessions (Testing::Sessions), chi.init tasks and
    # staged tool sets. No sha256 or requires_chi check: it loads the
    # source as it is.
    #
    #   bundle = Samagotchi::Testing::Bundle.load("path/to/bundle", settings: { "every" => 3 })
    #   bundle.fire(:after_turn, status: "completed")
    #   bundle.command("/checkin stop")
    #   bundle.tool_call({ name: "execute", content: "ls" })   # → Verdict
    #   bundle.notices, bundle.cards, bundle.steers …
    #   bundle.shutdown
    #
    # A hook that raises while #fire, #tool_call, #command or #tool runs
    # raises HookFailed after the call (chi would log it and go on);
    # #lenient collects them in #errors instead.
    class Bundle
      SHIPPED_DIR = MemoryBundle::SourceNormalizer::SHIPPED_DIR

      class << self
        # @param dir [String] the bundle's folder (its manifest.yml)
        # @param settings [Hash] config.yml `bundles: <name>:`
        # @param host [Hash] session values (Recorder::DEFAULTS' keys)
        # @param session_settings [Hash] the session's own values for the
        #   bundle (chi --set), keys its manifest lists in session_settings:;
        #   ctx.settings lays them over +settings+ (Plugin::Context#settings),
        #   initialize(settings) doesn't see them
        # @param sandbox [Sandbox, nil] default Sandbox.current, else one of
        #   its own, left at #shutdown
        # @return [Bundle]
        def load(dir, settings: {}, host: {}, session_settings: {}, sandbox: nil)
          new(dir, settings: settings, host: host, session_settings: session_settings, sandbox: sandbox).tap(&:load!)
        end

        # A bundle chi ships (lib/samagotchi/bundles/<name>), as #load.
        def shipped(name, **) = load(File.join(SHIPPED_DIR, name.to_s), **)

        # Registries as an Engine's start: chi's built-in commands and
        # tools, empty services, toolkits, tool index and peer sources;
        # +fields+ set the rest (hooks:, context_for:, init: ...) or replace
        # these. Bundle#build_registries and Install's load both start here.
        # @api private
        # @return [Plugin::Registries]
        def registries(**fields)
          Plugin::Registries.new(
            commands: SessionCommands.register_builtins(Commands::Registry.new), tools: Tools::Builtins.registry,
            services: Plugin::Services.new, stage_tools: ->(*) {}, toolkits: [], tool_index: Tools::ToolIndex.new,
            peer_sources: PeerSources.new, prompt_sections: Plugin::PromptSections.new, **fields
          )
        end
      end

      # @return [String] the bundle's name (manifest.yml)
      attr_reader :name
      # @return [MemoryBundle::Manifest]
      attr_reader :manifest
      # @return [Plugin::Registries]
      attr_reader :registries
      # @return [Recorder]
      attr_reader :recorder
      # @return [Sessions] ctx.sessions
      attr_reader :sessions
      # @return [FakeHttp] what answers ctx.http (stub, requests, unmatched)
      attr_reader :http
      # @return [Sandbox]
      attr_reader :sandbox
      # @return [Plugin::Api, nil] the plugin's committed Api (nil without one)
      attr_reader :api
      # @return [Object, nil] the plugin's instance (the object #register ran
      #   on), for specs of its own methods
      attr_reader :plugin
      # @return [Module, nil] the module the plugin was evaluated in
      #   (bundle.namespace::ThinkingWatch)
      attr_reader :namespace
      # @return [Module] the module the hook files were evaluated in
      attr_reader :hooks_namespace
      # @return [Array<Init>]
      attr_reader :inits
      # @return [Array<StagedTools>]
      attr_reader :staged_tools
      # @return [Array<Hooks::Failure>] what raised under #lenient
      attr_reader :errors
      # @return [Integer] how often chi was told the tools changed
      attr_reader :tools_changes
      # @return [Integer] how often chi was told the prompt sections changed
      #   (chi.prompt_changed!)
      attr_reader :prompt_changes

      def initialize(dir, settings: {}, host: {}, session_settings: {}, sandbox: nil)
        @dir = File.expand_path(dir)
        @manifest = MemoryBundle::Manifest.read(dir: @dir)
        @name = @manifest.name
        @settings = stringify(settings || {})
        @session_moves = 1
        own = session_settings.nil? || session_settings.empty? ? {} : { setup: setup_with(session_settings, host[:setup]) }
        @own_sandbox = sandbox.nil? && Sandbox.current.nil?
        @sandbox = sandbox || Sandbox.current || Sandbox.enter
        build(host, own)
      rescue Exception # rubocop:disable Lint/RescueException -- leave the sandbox it entered, whatever failed
        @sandbox.leave if @own_sandbox && @sandbox
        raise
      end

      def build(host, own)
        @recorder = Recorder.new(cwd: @sandbox.work_dir, **host, **own)
        @sessions = Sessions.new
        @http = FakeHttp.new
        @inits = []
        @staged_tools = []
        @errors = []
        @lenient = false
        @tools_changes = 0
        @prompt_changes = 0
        @contexts = {}
        @registries = build_registries
      end
      private :build

      # @api private (Bundle.load)
      def load!
        if (plugin = @manifest.plugin)
          @namespace = Plugin::Loader.fresh_namespace(@name)
          @api = Plugin::Loader.register_file(@name, File.join(@dir, plugin[:file]), @registries, settings: @settings,
                                                                                                  namespace: @namespace,
                                                                                                  api_class: RecordingApi) do |built|
            @plugin = built
          end
        end
        @hooks_namespace = Module.new
        @manifest.hooks.each do |basename, hook|
          next if hook.events.empty?

          Hooks::BundleLoader.load_hook_file(@name, basename, File.join(@dir, "hooks", basename), hook, hooks,
                                             settings: @settings, namespace: @hooks_namespace)
        end
        self
      rescue Exception # rubocop:disable Lint/RescueException -- leave the sandbox it entered, whatever failed
        shutdown
        raise
      end

      # ── Firing ──────────────────────────────────────────────────────────

      # Fire hook +event+ through the registry, as chi's fire sites do: the
      # event is {type: event, **fields} (a fire site's own keys, such as
      # after_turn's present:/refs:, come from +fields+), with the runtime
      # helpers added. Returns the event after the hooks.
      # @return [Hash]
      def fire(event, **fields)
        payload = { type: event.to_sym, **fields }
        failing { hooks.fire(event.to_sym, payload) }
        payload
      end

      # Fire :question_asked as chi's two seams do (QuestionAsked.fire): a
      # question (+kind+ "question") or an approval ("approval") asked by a
      # step whose text is +text+, with the question's +question+ fields.
      # The hooks' refs are checked as chi checks them (the question caps,
      # file refs under +cwd+, default the session's folder).
      # @return [Array<Hash>] the refs the step and its pending question
      #   get, as stored; [] for none
      def question_asked(text, kind: "question", question: {}, cwd: nil)
        step = { role: "model", content: text.to_s }
        fields = failing do
          QuestionAsked.fire(hooks: hooks, conversation: [step], kind: kind.to_s, fields: question.to_h,
                             cwd: cwd || @recorder[:cwd])
        end
        Array(fields[:refs])
      end

      # Build the before_tool_call payload from the real Gate, without firing
      # this bundle's hooks.
      # @param call [Hash] the parsed tool call
      # @param iteration [Integer]
      # @param params [String] the call's one-line preview
      # @param context [Guardrails::Context, nil]
      # @param verdict [Verdict, nil]
      # @return [Hash]
      def before_tool_call_event(call, params:, iteration: 1, context: nil, verdict: nil)
        context ||= Guardrails::Context.new(cwd: @recorder[:cwd], session_id: @recorder[:session_id],
                                            interface: @recorder[:frontend])
        dispatched = nil
        capture = Hooks::Registry.new
        capture.register(:before_tool_call) { |event| dispatched = event.dup }
        gate = Guardrails::Gate.new(-> { capture }, context_lookup: -> { context }, tools_lookup: -> { tools })
        gate.evaluate(call, iteration: iteration, params: params, verdict: verdict || Verdict.new(call: call))
        raise ArgumentError, "guardrails did not dispatch a before_tool_call event for #{call[:name].inspect}" unless dispatched

        dispatched.slice(:type, :iteration, :call, :params, :blocked, :block_reason, :guardrail, :context, :targets)
      end

      # One tool call through a real Guardrails::Gate: the before_tool_call
      # hooks vote on a Testing::Verdict (pass +verdict+ to start from one,
      # another voter's deny in it), with the context and targets the Gate
      # computes for the call (cwd: the session's by default).
      # @param call [Hash] the parsed call ({name:, content:/path:/args:})
      # @param context [Guardrails::Context, nil]
      # @return [Verdict]
      def tool_call(call, params: nil, cwd: nil, context: nil, verdict: nil, iteration: 1)
        context ||= Guardrails::Context.new(cwd: cwd || @recorder[:cwd], session_id: @recorder[:session_id],
                                            interface: @recorder[:frontend])
        gate = Guardrails::Gate.new(-> { hooks }, context_lookup: -> { context }, tools_lookup: -> { tools },
                                                  checks_lookup: -> { [] })
        verdict ||= Verdict.new(call: call)
        params ||= "#{call[:name]} #{call[:content] || call[:path]}".strip
        failing { gate.evaluate(call, iteration: iteration, params: params, verdict: verdict) }
      end

      # Run a command line ("/name args") as chi does: the first matching
      # command, given the text after its name. Returns the handler's value
      # (a raise propagates: chi would show it as an error result).
      def command(line)
        entry = commands.lookup(line)
        raise ArgumentError, "no command matches #{line.inspect}" unless entry
        raise ArgumentError, "#{entry.name} is chi's own command, not the bundle's" if entry.source == "core"

        failing { entry.handler.call(line.to_s.strip.delete_prefix(entry.name).strip) }
      end

      # Call a registered tool as chi's dispatch does: its handler gets the
      # call ({name:, args:}), types the args by the tool's schema
      # (ToolSpec.args_of) and returns the text the model reads.
      # @return [String]
      def tool(name, args = {})
        entry = tools[name.to_s]
        raise ArgumentError, "no tool #{name}" unless entry

        failing { entry.handler.call({ name: name.to_s, args: stringify(args) }, nil) }
      end

      # Install this bundle's dir into its sandbox as chi does and load the
      # installed copy with chi's loaders (Install.run, with its settings):
      # what a test of the installed bundle needs (its scripts, context
      # providers), and the install warnings and load failures.
      # @return [Install::Result]
      def install(force: false) = Install.run(@dir, settings: @settings, sandbox: @sandbox, force: force)

      # Run the chi.init blocks in order, as chi's init tasks do.
      # @return [Array] their results
      def run_inits = failing { @inits.map { |init| init.block.call } }

      # Apply the staged chi.replace_tools sets, as chi does before a turn
      # (ToolSpec.apply). @return [Boolean] whether the tools changed
      def apply_staged_tools!
        sets = @staged_tools.dup
        @staged_tools.clear
        sets.map { |set| Plugin::ToolSpec.apply(tools, @name, set.specs, set.context)[:changed] }.any?
      end

      # Collect what raises in the block's fires in #errors instead of
      # raising HookFailed.
      def lenient
        was = @lenient
        @lenient = true
        yield
      ensure
        @lenient = was
      end

      # ── What it registered ─────────────────────────────────────────────

      # @return [Commands::Registry] chi's built-ins and the bundle's
      def commands = @registries.commands
      # @return [Tools::Registry] chi's built-ins and the bundle's
      def tools = @registries.tools
      # @return [Hooks::Registry]
      def hooks = @registries.hooks
      # @return [Array<Toolkit::Kit>]
      def toolkits = @registries.toolkits
      # @return [Tools::ToolIndex]
      def tool_index = @registries.tool_index
      # @return [PeerSources]
      def peer_sources = @registries.peer_sources

      # The prompt sections as chi's next prompt build runs them, for the
      # session now (its id: a failure keeps that session's last good text).
      # @return [Array<Plugin::PromptSections::Built>]
      def prompt_sections = @registries.prompt_sections.render(@recorder[:session_id])

      # The text they add to the system prompt, as chi puts it there; nil
      # with none.
      # @return [String, nil]
      def prompt_text = Plugin::PromptSections.text(prompt_sections)

      # The bundle's own command entries.
      def bundle_commands = commands.entries.select { |entry| entry.source == @name }
      # The bundle's own tool entries.
      def bundle_tools = tools.by_source(@name)
      # Its hooks for +event+ as [bundle, hook_name, priority], fire order.
      def hook_names(event) = hooks.bundle_hook_names(event.to_sym)
      # The annotations its commands carry.
      def annotations = bundle_commands.flat_map(&:annotations)

      # The chi.* calls #register made, in order, as made (RecordingApi).
      # @return [Array<Declaration>]
      def declarations = @api ? @api.declarations : []

      # The plugin's ctx (a real Plugin::Context; nil without a plugin).
      def ctx = @contexts.values.first

      # ── Recorders ──────────────────────────────────────────────────────

      def notices = @recorder.notices
      def cards = @recorder.cards
      def steers = @recorder.steers
      # Every stop_turn and stop_generation, in order (Stop#kind).
      def stops = @recorder.stops
      def turn_stops = @recorder.turn_stops
      def generation_stops = @recorder.generation_stops
      def questions = @recorder.questions
      def model_requests = @recorder.model_requests
      def toolkit_uses = @recorder.toolkit_uses
      # Every ctx.load_tools call (ToolLoad: names, bundle).
      def tool_loads = @recorder.tool_loads
      # Queue ask_model answers: a String, an exception, or a callable.
      def model_answers = @recorder.model_answers

      # Queue ask_user answers ({selected:, freeform:, selected_indices:},
      # or a callable given the HookQuestion).
      def answer(*answers)
        @recorder.answers.concat(answers)
        self
      end

      # Change the session's values (cwd:, messages:, running: …).
      # +session_settings+ changes the session's own values for the bundle
      # (as Bundle.load's) and moves it to a new session id
      # ("test-session-2", or the session_id: given beside it): chi never
      # changes them within a session, and ctx.settings is built once per
      # session id.
      def set(session_settings: nil, **values)
        unless session_settings.nil?
          values[:setup] = setup_with(session_settings, @recorder[:setup])
          values[:session_id] ||= "#{@recorder[:session_id] || "test-session"}-#{@session_moves += 1}"
        end
        @recorder.set(**values)
        self
      end

      # Stop the plugin's services; leave the sandbox it entered.
      def shutdown
        @registries&.services&.stop_all
        return unless @own_sandbox

        @own_sandbox = false
        @sandbox.leave
      end

      private

      def build_registries
        toolkits = []
        host = Host.build(@recorder, toolkits: -> { Toolkit::BUILTIN_KITS.keys + toolkits.map(&:name) },
                                     tool_names: -> { @registries.tools.names })
        Bundle.registries(
          hooks: Hooks::Registry.new.tap { |registry| registry.runtime = Runtime.build(@recorder) },
          context_for: lambda { |bundle, settings, label|
            @contexts[label] = Plugin::Context.new(bundle: bundle, label: label, settings: settings, host: host,
                                                   env: ENV, sessions: @sessions, http_transport: @http)
          },
          tools_changed: -> { @tools_changes += 1 },
          prompt_changed: -> { @prompt_changes += 1 },
          stage_tools: ->(_bundle, specs, context) { @staged_tools << StagedTools.new(specs: specs, context: context) },
          init: lambda { |_bundle, label, plugin_label, provides_tools:, quiet:, timeout:, failed: nil, &block|
            @inits << Init.new(label: label, plugin_label: plugin_label, provides_tools: provides_tools, quiet: quiet,
                               timeout: timeout, failed: failed, block: block)
          },
          toolkits: toolkits
        )
      end

      # Run the block catching the hooks that raise in it.
      def failing(&)
        failures = []
        result = Hooks.capture_failures(failures, &)
        if @lenient
          @errors.concat(failures)
        elsif failures.any?
          raise HookFailed, failures
        end
        result
      end

      # +setup+ (the recorder's, nil for none) with +session_settings+ as
      # this bundle's own values, checked against the manifest's
      # session_settings: (keys and types) as chi --set checks them.
      # @raise [ArgumentError] a key the manifest doesn't list, or a value
      #   of another type than it gives the key
      def setup_with(session_settings, setup)
        values = { @name => stringify(session_settings) }
        SessionConfig.check!(values, bundles: { @name => @manifest.session_settings },
                                             types: { @name => @manifest.session_setting_types }, flag: "session_settings")
        setup ||= SessionSetup.new
        setup.with(settings: setup.settings.with(bundles: values))
      end

      def stringify(value) = Sandbox.stringify(value)
    end
  end
end
