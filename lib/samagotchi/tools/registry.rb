# frozen_string_literal: true

module Samagotchi
  module Tools
    # The tools a session offers the model, in declaration order: the
    # built-ins (Tools::Builtins) as registered, then the ones bundles add,
    # by bundle and name. That order doesn't depend on which plugin
    # finished its init first or re-registered a changed tool, so the
    # tool list (part of the prompt's cached prefix) is the same in every
    # session with the same tools. The
    # native prompts and the chat path's tools: are rendered from #schemas,
    # and KernelLoop#dispatch runs a call through its entry's handler.
    class Registry
      # @!attribute name [String]
      # @!attribute schema [Hash] {name:, description:, parameters:}, as in
      #   ToolDeclarations::TOOL_SCHEMAS
      # @!attribute handler [#call] (call, kctx) → the result (a String;
      #   "Error: …" marks a failure); kctx is the KernelLoop's ToolContext
      # @!attribute label [String, nil] the activity line's action ("calling
      #   tool" when nil); ToolActivity knows the built-ins' own
      # @!attribute preview [#call, nil] call → the activity line's params
      # @!attribute targets [#call, nil] call → what guardrail rules match
      # @!attribute refs [#call, nil] call → the row's refs (a plugin's
      #   refs:, RowRefs checks what it gives)
      # @!attribute source [String] "core", or the bundle that added it
      # @!attribute layer [Symbol, nil] the LLM context layer the tool
      #   belongs to (LLMContextStrategy): offered only in a turn running
      #   under it (forget_outputs, :forget); nil: always
      Entry = Struct.new(:name, :schema, :handler, :label, :preview, :targets, :refs, :source, :layer, keyword_init: true) do
        def core? = source == "core"

        # Offered in a turn under +layers+ (the turn's LLM context layers).
        def offered?(layers) = layer.nil? || Array(layers).include?(layer)
      end

      def initialize
        @entries = {}
        @toolkit = nil
      end

      # The session's resolved toolkit (Toolkit::Resolved), which the lists
      # below and #offered filter by; nil declares every tool (full). The
      # Engine sets it at a turn's start, before the prompt is built, and
      # only there: a request's declared tools never change mid-turn.
      attr_accessor :toolkit

      # @return [Entry]
      def register(name, schema:, handler:, label: nil, preview: nil, targets: nil, refs: nil, source: "core", layer: nil)
        raise ArgumentError, "tool #{name} is already registered" if @entries.key?(name)

        @entries[name] = Entry.new(name: name, schema: schema, handler: handler, label: label, preview: preview,
                                   targets: targets, refs: refs, source: source, layer: layer)
      end

      # Remove a tool (a plugin's tool set changed after load).
      # @return [Entry, nil] the removed entry
      def unregister(name) = @entries.delete(name.to_s)

      # @return [Entry, nil] whatever the turn offers
      def [](name) = @entries[name.to_s]

      def key?(name) = @entries.key?(name.to_s)

      # The entry +name+ names when a turn under +layers+ offers it (the
      # one a call dispatches to).
      # @return [Entry, nil]
      def offered(name, layers: [])
        entry = self[name]
        entry if entry&.offered?(layers) && declared?(entry)
      end

      # The entry +name+ names when the session's toolkit leaves it out (a
      # real tool the model can't call here), nil otherwise.
      # @return [Entry, nil]
      def left_out(name, layers: [])
        entry = self[name]
        entry if entry&.offered?(layers) && !declared?(entry)
      end

      # The tools +toolkit+ (the session's by default) leaves out of a turn
      # under +layers+.
      # @return [Array<String>] in declaration order
      def left_out_names(layers: [], toolkit: @toolkit)
        ordered(@entries.values.select { |entry| entry.offered?(layers) && !declared?(entry, toolkit) }).map(&:name)
      end

      # Every tool +source+ registered, declared or not (a plugin's tool set
      # changing: Plugin::ToolSpec.apply).
      # @return [Array<Entry>]
      def by_source(source) = @entries.values.select { |entry| entry.source == source }

      # The tools a turn offers is per turn: +layers+, the turn's LLM
      # context layers (LLMContextStrategy), adds the tools gated by them.
      # Without layers (none, the default) the list is what it always was.
      # @return [Array<String>] in declaration order
      def names(layers: [], toolkit: @toolkit) = entries(layers: layers, toolkit: toolkit).map(&:name)

      # @return [Array<Entry>] in declaration order: the ones the turn's
      #   layers offer and the session's toolkit declares
      #   (+toolkit+: another one's, for what a change would declare)
      def entries(layers: [], toolkit: @toolkit)
        ordered(@entries.values.select { |entry| entry.offered?(layers) && declared?(entry, toolkit) })
      end

      # @return [Array<Hash>] the schemas, in declaration order
      def schemas(layers: []) = entries(layers: layers).map(&:schema)

      def freeze
        @entries.freeze
        super
      end

      private

      def declared?(entry, toolkit = @toolkit) = toolkit.nil? || toolkit.declares?(entry)

      def ordered(entries)
        core, added = entries.partition(&:core?)
        core + added.sort_by { |entry| [entry.source.to_s, entry.name] }
      end
    end
  end
end
