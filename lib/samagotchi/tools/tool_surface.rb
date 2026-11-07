# frozen_string_literal: true

require_relative "builtin_calls"
require_relative "deferred_tools"
require_relative "registry"

module Samagotchi
  module Tools
    # What one turn's loops see of the session's tools, as one frozen value:
    # what the request declares, what call_tool reaches, what the toolkit
    # leaves out (and why), and the dispatch decision for a call. Built once
    # per turn in Engine#generate from the Registry (its only input), where
    # the turn's LLM context layers and its host's loads_tools are known,
    # and carried as TurnContext#surface: KernelLoop#dispatch, ChatLoop's
    # tool_definitions/deferred_tools and ToolRunner's left-out, unwrap
    # and refusal checks read it. A change made while the turn runs (a
    # /toolkit change, chi.replace_tools: staged anyway) shapes the next
    # turn's surface only. Outside a turn a caller builds one (.for): a bare
    # kernel or loop at its own context (KernelLoop#own_context), the tool
    # index at load and at #refresh!, the readers off the turn thread from
    # ToolkitBinding#published.
    #
    # +declared+    the entries the request declares, in prompt order (Registry#entries)
    # +index_only+  the entries the toolkit leaves out that call_tool reaches (Registry#reachable_names)
    # +left_out+    {name => why} for every tool the toolkit leaves out (Registry#left_out_names),
    #               in declaration order: :indexed (call_tool reaches it) or :user_only (only
    #               /toolkit add brings it back: removed, or nothing reaches it)
    # +removed+     the names the toolkit removes (Registry#removed_names: remove:, --no-tool,
    #               /toolkit remove), in declaration order
    # +stranded+    the names of the plugin tools registered after the index was declared that
    #               the toolkit leaves out and nothing reaches (Registry#stranded_names)
    # +registered+  {name => entry} of every registered tool, declared or not
    # +toolkit+     the session's Toolkit::Resolved (nil: full)
    # +reaching_kit+ group → the kit that reaches it (Registry#reaching_kit), for a refusal's hint
    # +index+       the tool index's declaration (Registry::Index), nil without one
    # +layers+      the turn's LLM context layers
    # +loads_tools+ whether the turn's host loads tools (TurnSettings#loads_tools)
    class ToolSurface < Data.define(:declared, :index_only, :left_out, :removed, :stranded, :registered, :toolkit,
                                    :reaching_kit, :index, :layers, :loads_tools)
      # @param registry [Registry, nil] nil: no tools at all
      # @param layers [Array<Symbol>] the turn's LLM context layers
      # @param loads_tools [Boolean] the turn's host's (TurnSettings#loads_tools)
      # @param toolkit [Toolkit::Resolved, nil] the toolkit to read the
      #   Registry under: its own (the session's) by default; another one
      #   for what a change would declare (ToolkitBinding#explained)
      # @return [ToolSurface]
      def self.for(registry, layers: [], loads_tools: false, toolkit: registry&.toolkit)
        layers = Array(layers)
        return empty(layers, loads_tools) if registry.nil?

        reachable = registry.reachable_names(layers: layers, toolkit: toolkit)
        new(declared: registry.entries(layers: layers, toolkit: toolkit),
            index_only: reachable.map { |name| registry[name] },
            left_out: registry.left_out_names(layers: layers, toolkit: toolkit)
                              .to_h { |name| [name, reachable.include?(name) ? :indexed : :user_only] },
            removed: registry.removed_names(layers: layers, toolkit: toolkit),
            stranded: registry.stranded_names(layers: layers, toolkit: toolkit),
            registered: registry.registered.to_h { |entry| [entry.name, entry] },
            toolkit: toolkit, reaching_kit: registry.reaching_kit, index: registry.index,
            layers: layers, loads_tools: loads_tools == true)
      end

      # Its lists frozen (copies of the ones given), whichever way it is
      # made (.for, .new, #with): no reader can change a turn's surface.
      # The entries in them stay the Registry's own.
      def initialize(declared:, index_only:, left_out:, registered:, layers:, removed: [], stranded: [], **)
        super(declared: frozen_copy(Array(declared)), index_only: frozen_copy(Array(index_only)),
              left_out: frozen_copy(left_out.to_h), removed: frozen_copy(Array(removed)),
              stranded: frozen_copy(Array(stranded)), registered: frozen_copy(registered.to_h),
              layers: frozen_copy(Array(layers)), **)
      end

      # The turn's surface (+context+'s: an Engine turn's, or a bare kernel's
      # or loop's own, KernelLoop#own_context); a context without one raises
      # MissingSurface (no reader falls back to the Registry as it is now).
      # @param context [TurnContext]
      # @return [ToolSurface]
      def self.of(context) = context.surface || raise(MissingSurface)

      # A bare kernel's or loop's own +context+ (no Engine turn: a spec, a
      # bench) with a surface: its own, else one built now from +registry+
      # under its layers and loads_tools. Only their own default context
      # goes through here (KernelLoop#own_context, ChatLoop#turn_context);
      # a context handed down is read as it is (.of).
      # @param context [TurnContext]
      # @return [TurnContext]
      def self.bare(context, registry)
        return context if context.surface

        context.with(surface: self.for(registry, layers: context.llm_context_layers,
                                                 loads_tools: context.settings&.loads_tools == true))
      end

      def self.empty(layers, loads_tools)
        new(declared: [], index_only: [], left_out: {}, removed: [], stranded: [], registered: {}, toolkit: nil,
            reaching_kit: nil, index: nil, layers: layers, loads_tools: loads_tools == true)
      end
      private_class_method :empty

      # @return [Array<String>] the declared tools' names, in prompt order
      def declared_names = declared.map(&:name)

      # @return [Array<Hash>] the declared tools' schemas, in prompt order
      def schemas = declared.map(&:schema)

      # The declared entry +name+ names (the one a call dispatches to), nil
      # otherwise.
      # @return [Registry::Entry, nil]
      def declared_entry(name) = declared.find { |entry| entry.name == name.to_s }

      # The entry +name+ names when call_tool reaches it (#index_only).
      # @return [Registry::Entry, nil]
      def indexed_entry(name) = index_only.find { |entry| entry.name == name.to_s }

      # Whether the toolkit leaves +name+'s real tool out (#left_out).
      def left_out?(name) = left_out.key?(name.to_s)

      # Whether any tool, declared or not, is registered as +name+.
      def registered?(name) = registered.key?(name.to_s)

      # The entry a call runs on, nil when it can't run in this turn: one
      # reached through call_tool (via:) only while the toolkit reaches it
      # that way; any other by its name when declared, or, on a host that
      # loads tools, when call_tool reaches it.
      # @param call [Hash] the normalized call ({name:, via:, …})
      # @return [Registry::Entry, nil]
      def entry_for(call)
        name = call[:name]
        return indexed_entry(name) if call[:via]

        declared_entry(name) || (loads_tools ? indexed_entry(name) : nil)
      end

      # Shell-like names (the harness's is `execute`). The unknown-tool error
      # never echoes the name the model used: a model that sees its own wrong
      # name again calls it again (a steer that named `bash` raised one
      # model's bash rate from 9% to 30%); the activity event and the logs
      # keep it.
      SHELL_LIKE_TOOL_NAMES = %w[
        bash sh zsh shell terminal cmd command run run_command run_shell exec execute_command
      ].freeze

      # The error a call #entry_for has no entry for gets back. A shell-like
      # name with `execute` declared points at `execute`; every other unknown
      # name lists what is declared. Neither echoes the wrong name.
      #
      # A tool the session's toolkit leaves out is a real one, so its error
      # does name it (deliberately, against the rule above): the model learns
      # it exists, and how to reach it (call_tool, when the toolkit reaches
      # it that way) or that only the user can load it. A call reached
      # through call_tool (+via+) of a tool the toolkit declares is told to
      # call it directly: the model's call_tool(tool: "chi/read") with read
      # declared, or a hook's rewrite (a direct call can't carry via:).
      # @return [String]
      def unknown_tool_error(name, via: nil)
        names = declared_names
        in_toolkit = " in this session#{" (toolkit #{toolkit.name})" if toolkit}"
        if via && declared_entry(name)
          "Error: #{name} is declared#{in_toolkit}; call it directly. Available: #{names.join(", ")}"
        elsif !via && indexed_entry(name)
          "Error: #{name} isn't declared#{in_toolkit}; call it with #{BuiltinCalls::VIA}(tool: \"chi/#{name}\", args: {…}) " \
            "(find_tools gives its inputSchema). Available: #{names.join(", ")}"
        elsif left_out?(name)
          "Error: #{name} isn't loaded#{in_toolkit} and can't be loaded from " \
            "here; only the user can (/toolkit add #{name}). Available: #{names.join(", ")}"
        elsif SHELL_LIKE_TOOL_NAMES.include?(name.to_s.downcase) && names.include?("execute")
          "Error: no such tool. Shell commands run with `execute` (same arguments)."
        else
          "Error: no such tool. Available: #{names.join(", ")}"
        end
      end

      # The tools a request on a host that loads tools declares deferred,
      # +conversation+ (the request's, engine format) naming the ones it
      # loaded (Tools::DeferredTools.list). The index's source tools are
      # asked now (a late MCP server joins the list mid-turn, as before).
      # @return [Array<DeferredTools::Deferred>]
      def deferred_for(conversation) = DeferredTools.list(self, conversation)

      private

      # +list+ itself when frozen, else a frozen copy (the caller's stays
      # as it is).
      def frozen_copy(list) = list.frozen? ? list : list.dup.freeze
    end
  end
end
