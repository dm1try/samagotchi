# frozen_string_literal: true

module Samagotchi
  class Engine
    # The session's toolkit: the kits and what a turn declares
    # (ToolkitBinding, forwarded), ctx.load_tools and the staged loads a turn
    # appends, and System 1's toolkit suggestion (TurnStages::ToolkitSuggestion,
    # forwarded). Reads @toolkit_binding, @tools, @tool_index, @tool_loads,
    # @toolkit_suggestion, @session.
    module ToolkitPart
      private

      # The session's toolkit (ToolkitBinding): the kits, what its next turn
      # declares, ctx.use_toolkit and the turn-start apply.
      def toolkit_kits(errors = []) = @toolkit_binding.kits(errors)
      def resolved_toolkit(session, errors = []) = @toolkit_binding.resolved(session, errors)
      def toolkit_explained(toolkit = nil) = @toolkit_binding.explained(toolkit)
      def toolkit_summary = @toolkit_binding.summary

      # The tools this session registered (Tools::Registry), declared or not.
      attr_reader :tools

      public :tools, :toolkit_kits, :resolved_toolkit, :toolkit_explained, :toolkit_summary

      # A plugin's ctx.load_tools: stage the reachable tools +names+ names
      # (Tools::ToolIndex#deferred_name) that the session neither declares
      # nor loaded with an earlier tool change, for bundle +bundle+. A name
      # that names no tool at all is logged; a declared or removed one is
      # skipped quietly.
      # @return [Array<String>] the wire names staged
      def load_tools(names, bundle)
        added = ToolLoads.added(@session&.messages)
        wanted = names.filter_map do |name|
          wire = @tool_index.deferred_name(name)
          Log.info(:plugins, "load_tools_skipped", bundle: bundle, tool: name) unless wire || @tools.key?(name)
          wire
        end
        @tool_loads.stage(wanted - added, by: bundle)
      end
      public :load_tools

      # The staged tool loads, appended to +turn+'s messages (after its user
      # message, or the trailing results and notes of a turn with none) as
      # one ToolLoads entry per bundle, when the turn's host takes tool
      # changes (ChatLoop#tool_changes?). Elsewhere they are dropped, logged.
      # A conversation that ends with a reply keeps them staged (a system
      # change must follow a user turn).
      def append_tool_loads(turn)
        return unless @tool_loads.any?
        return if turn.messages.last&.dig(:role).to_s == "model"

        model = effective_model
        host = backend(model)
        staged = @tool_loads.take
        added = ToolLoads.added(turn.messages)
        unless host.respond_to?(:tool_changes?) && host.tool_changes?(bare_model_name(model.name))
          Log.info(:plugins, "tool_loads_not_sent", tools: staged.values.flatten.join(","), model: model.name.to_s)
          return
        end

        staged.each do |bundle, names|
          names -= added
          next if names.empty?

          turn.messages << ToolLoads.entry(names, by: bundle)
          hook_notify("tools loaded: #{names.join(", ")}", :info, bundle)
        end
      end
      private :append_tool_loads

      # A plugin's ctx.use_toolkit (ToolkitBinding#use).
      # @return [Boolean] whether it was staged
      # @raise [ArgumentError] an unknown toolkit
      def use_toolkit(name) = @toolkit_binding.use(name)
      public :use_toolkit

      # At a turn's start (ToolkitBinding#apply!).
      # @return [Boolean] whether the declared tools changed
      def apply_toolkit!(session, on_event = nil) = @toolkit_binding.apply!(session, on_event)
      private :apply_toolkit!

      # System 1's toolkit suggestion (TurnStages::ToolkitSuggestion):
      # prepare_turn starts, settles and abandons it; the Worker warms it.
      attr_reader :toolkit_suggestion
      private :toolkit_suggestion

      # On mode, as an idle worker starts (Worker#start_background): the
      # warm-up ask (TurnStages::ToolkitSuggestion#warm!).
      def warm_toolkit_suggestion! = @toolkit_suggestion.warm!(@session)
      public :warm_toolkit_suggestion!

      # The stage over this Engine's side asks, binding and tools (built in
      # #build_tools_and_plugins, before the plugins load).
      def build_toolkit_suggestion
        TurnStages::ToolkitSuggestion.new(
          side_judgments: @side_judgments, host_registry: @host_registry, toolkit_binding: @toolkit_binding,
          tools: @tools, state_dir: -> { session_state_dir },
          recording: ->(client, judgment, session, mode:) { system_one_recording(client, judgment, session, mode: mode) },
          runs: -> { system_one_runs }
        )
      end
      private :build_toolkit_suggestion
    end
  end
end
