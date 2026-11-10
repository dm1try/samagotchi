# frozen_string_literal: true

module Samagotchi
  class Engine
    # The Engine as the plugins' host: loading them (Plugin::Registries), their
    # init tasks and staged tool sets (PluginTasks), Plugin::Host's view of
    # the session, ctx.messages and ctx.http's cancel. Writes nothing of its
    # own; reads @plugin_tasks, @extension_load, @hook_routes, @tools,
    # @tool_index, @toolkit_binding, @prompt_builder, @session.
    module PluginsPart
      # Add a plugin's init task (Plugin::Api#init at commit); it starts with
      # #start_init_tasks!.
      def add_init_task(bundle:, label:, plugin_label:, provides_tools:, quiet:, timeout:, failed: nil, &)
        @plugin_tasks.add(bundle: bundle, label: label, plugin_label: plugin_label, provides_tools: provides_tools,
                          quiet: quiet, timeout: timeout, failed: failed, &)
      end

      # Start the init tasks not started yet, each on its own thread
      # (PluginTasks#start!).
      def start_init_tasks!
        @plugin_tasks.start!
      end

      # The running init tasks a UI shows (not the quiet ones), for a UI that
      # joins while they run (Bridge#snapshot, with the event log held).
      # @return [Array<Hash>] {bundle:, id:, label:}
      def init_tasks
        @plugin_tasks.running
      end

      # Wait for the running init tasks that provide tools (PluginTasks#await).
      # @return [Boolean] whether it waited
      def await_init_tasks(controller = nil, on_event = nil)
        @plugin_tasks.await(controller, on_event)
      end

      # The init task this thread runs, or nil.
      def current_init_task = @plugin_tasks.current
      private :current_init_task

      private

      def load_plugins
        host = plugin_host
        registries = Plugin::Registries.new(
          commands: @command_registry, tools: @tools, hooks: @hooks,
          context_for: lambda { |bundle, settings, label|
            Plugin::Context.new(bundle: bundle, label: label, settings: settings, host: host)
          },
          tools_changed: -> { tools_changed! },
          services: @services,
          stage_tools: ->(bundle, specs, context) { stage_tools(bundle, specs, context) },
          init: lambda { |bundle, label, plugin_label, provides_tools:, quiet:, timeout:, failed: nil, &block|
            add_init_task(bundle: bundle, label: label, plugin_label: plugin_label, provides_tools: provides_tools,
                          quiet: quiet, timeout: timeout, failed: failed, &block)
          },
          toolkits: @toolkit_binding.plugin_kits,
          tool_index: @tool_index,
          peer_sources: @peer_sources,
          prompt_sections: @prompt_sections,
          prompt_changed: -> { prompt_changed! },
          judgments: @judgments,
          hook_failed: ->(hook, failed, effect: :log) { @hook_routes.plugin_hook_failed(hook, failed, effect: effect) }
        )
        # What plugins show while they load (an MCP server that didn't
        # start) waits for the first turn, beside the load warnings: no UI
        # is there yet, and the Engine isn't built.
        @extension_load.load_plugins(registries, failures: @plugin_failures) do
          warn_undeclared_judgments
          warn_bundle_settings
        end
      end

      # config.yml bundles: names and keys that do nothing (BundleSettingsCheck),
      # held like the judgments' line, for the same reason. Logged by every
      # Engine; shown by the first to find them (BundleSettingsCheck.unshown).
      def warn_bundle_settings
        lines = BundleSettingsCheck.warnings(@extension_load.bundle_settings)
        lines.each { |line| Log.warn(:config, "bundle_setting_unknown", msg: line) }
        BundleSettingsCheck.unshown(lines).each { |line| hook_notify(line, :warn, "config") }
      end
      private :warn_bundle_settings

      # Held with the plugins' own notices, so every UI gets it: a worker's
      # stderr goes nowhere.
      def warn_undeclared_judgments
        @judgments.undeclared.each do |name|
          Log.warn(:config, "judgment_undeclared", judgment: name)
          hook_notify("system_one.judgments.#{name}: no loaded bundle declares it, so it does nothing", :warn, "config")
        end
      end
      private :warn_undeclared_judgments

      # Keep a plugin's new tool set (chi.replace_tools, from any thread)
      # for the turn thread (PluginTasks#stage_tools).
      def stage_tools(bundle, specs, context)
        @plugin_tasks.stage_tools(bundle, specs, context)
      end
      private :stage_tools

      # Apply the staged tool sets, on the turn thread, before the turn's
      # system prompt is built (PluginTasks#apply_staged_tools!). A changed
      # set may change the chi group the search tool's description counts
      # (a plugin tool the toolkit leaves out). Publishes the Registry it
      # leaves (#publish_tools!).
      # @return [Boolean] whether the tools changed
      def apply_staged_tools!
        changed = @plugin_tasks.apply_staged_tools!
        @tool_index.refresh! if changed
        publish_tools!
        changed
      end
      public :apply_staged_tools!

      # The tools changed (a plugin's chi.tools_changed!): the system prompts,
      # which declare them, are built again on the next turn.
      def tools_changed!
        prompt_changed!
      end

      # A plugin's prompt section would give other text now
      # (chi.prompt_changed!): the system prompts are built again at their
      # next build (the next turn's start; a running turn keeps the prompt it
      # started with). One cache restart: the plugin's command asked first
      # (Plugin::Context#cache_confirm).
      def prompt_changed!
        @prompt_builder&.reset!
      end
      public :prompt_changed!

      # What a Plugin::Context reads and calls: the session now, and the
      # hook runtime's notify and ask_user.
      def plugin_host
        Plugin::Host.new(
          session_id: -> { @session&.id },
          cwd: -> { @session&.working_directory },
          messages: -> { plugin_messages },
          messages_partial: -> { turn_running? && @running_turn_messages.nil? },
          turn_running: -> { turn_running? },
          notify: ->(text, level, label, fallback_for: nil) { hook_notify(text, level, label, fallback_for: fallback_for) },
          ask_user: ->(question) { hook_ask_user(question) },
          # An init task's is its own (a Ctrl-C ends a turn, not the task).
          cancelled: lambda {
            (task = current_init_task) ? task.cancelled? : active_cancel_controller&.cancelled?
          },
          card: ->(**card) { show_card(**card) },
          steer: ->(text, label) { steer(text, source: hook_source(label)) },
          stop_turn: ->(reason, label) { hook_stop_turn(reason, label) },
          stop_generation: ->(reason, label) { hook_stop_generation(reason, label) },
          toolkit: -> { @toolkit_binding.name },
          declared_tools: -> { toolkit_explained.declared.map(&:name) },
          use_toolkit: ->(name) { use_toolkit(name) },
          load_tools: ->(names, bundle) { load_tools(names, bundle) },
          cancel_controller: ->(handler: false) { plugin_cancel_controller(handler: handler) },
          ask_model: lambda { |request, timeout:, max_tokens:, cancel_controller:, model: nil, source: nil|
            ask_side_model(request, timeout: timeout, max_tokens: max_tokens, cancel_controller: cancel_controller,
                                    model: model, source: source)
          },
          model_name: -> { effective_model_ref },
          model_key: -> { @model_binding.model_key },
          # The names a models: map looks the model up under; [] when it doesn't resolve.
          model_names: lambda do
            effective_model.names
          rescue StandardError
            []
          end,
          state_dir: -> { session_state_dir },
          scratch: -> { @scratch },
          setup: -> { SessionSetup.of(@session, forked: true) },
          # The files whose text the built system prompt holds; [] until a
          # build and after a rebuild that drops them (SystemPrompt#prompt_files
          # returns [] itself: the || keeps a nil builder safe).
          prompt_files: -> { @prompt_builder&.prompt_files || [] },
          frontend: -> { interface },
          cost: -> { @metrics.cost },
          usage: -> { @metrics.usage },
          turn_author: -> { turn_author },
          # A plugin's prompt section is in the stable part: a full re-read.
          cache_confirm: ->(line, changed) { CacheConfirm.ask(line: line, cost: :full, changed: changed, engine: self) },
          candidate_proposed: ->(_candidate) { judge_late_candidates },
          judgments: -> { @judgments }
        )
      end

      # The controller a plugin's ctx.http call without cancel: stops with
      # (docs/plugins.md): an init task's own, else the running turn's for the
      # turn's own work until the turn has ended (TurnState#own_controller); nil
      # for an anytime command, a service or a thread of the plugin's.
      def plugin_cancel_controller(handler:)
        (task = current_init_task) ? task.cancel : @turn_state.own_controller(handler: handler)
      end
      private :plugin_cancel_controller

      # A plugin's ctx.messages: the conversation without the system prompt
      # (a session saved by an older chi's REPL may start with it), and,
      # while a turn runs, the turn so far from the Bridge (plan O1). Read
      # with the event log held, so a turn is in exactly one of the two.
      def plugin_messages
        synchronize_events do
          messages = AnswerDisplay.strip_all(messages_checkpoint)
          first = messages.first
          messages = messages.drop(1) if first && first[:role].to_s == "system" && first[:kind].to_s.empty?
          running = turn_running? && @running_turn_messages ? Array(@running_turn_messages.call) : []
          messages + running
        end
      end
      private :plugin_messages
    end
  end
end
