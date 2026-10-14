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
      # @!attribute unwrap [#call, nil] (call, layers) → the call it stands
      #   for, run in its place before the guardrail gate (call_tool on one
      #   of chi's own tools: Tools::ToolIndex#unwrap), or nil to run it as
      #   it is; nil on every other tool
      Entry = Struct.new(:name, :schema, :handler, :label, :preview, :targets, :refs, :source, :layer, :unwrap,
                         keyword_init: true) do
        def core? = source == "core"

        # Offered in a turn under +layers+ (the turn's LLM context layers).
        def offered?(layers) = layer.nil? || Array(layers).include?(layer)
      end

      # What Tools::ToolIndex#declare registered: the entries of +source+
      # are the index's search and call tools, +call_name+ the call tool's
      # name, and +sourced+ whether a source (an MCP server's bundle)
      # registered when the plugins loaded.
      Index = Data.define(:source, :call_name, :sourced)

      def initialize
        @entries = {}
        @toolkit = nil
        @index = nil
      end

      # The tool index's declaration (Index), nil without one.
      attr_accessor :index

      # The session's resolved toolkit (Toolkit::Resolved), which the lists
      # below and #offered filter by; nil declares every tool (full). The
      # Engine sets it at a turn's start, before the prompt is built, and
      # only there: a request's declared tools never change mid-turn.
      attr_accessor :toolkit

      # @return [Entry]
      def register(name, schema:, handler:, label: nil, preview: nil, targets: nil, refs: nil, source: "core", layer: nil,
                   unwrap: nil)
        raise ArgumentError, "tool #{name} is already registered" if @entries.key?(name)

        @entries[name] = Entry.new(name: name, schema: schema, handler: handler, label: label, preview: preview,
                                   targets: targets, refs: refs, source: source, layer: layer, unwrap: unwrap)
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
      # real tool the model can't call here, by its name), nil otherwise.
      # @return [Entry, nil]
      def left_out(name, layers: [])
        entry = self[name]
        entry if entry && left_out?(entry, layers, @toolkit)
      end

      # The tools +toolkit+ (the session's by default) leaves out of a turn
      # under +layers+. The tool index's own aren't, unless it removes them:
      # they are declared when there is something to reach.
      # @return [Array<String>] in declaration order
      def left_out_names(layers: [], toolkit: @toolkit)
        ordered(@entries.values.select { |entry| left_out?(entry, layers, toolkit) }).map(&:name)
      end

      # The built-in +name+ names when the session's toolkit leaves it out
      # but the tool index reaches it (#reachable_names).
      # @return [Entry, nil]
      def indexed(name, layers: [], toolkit: @toolkit)
        entry = self[name]
        entry if entry && call_offered?(toolkit) && soft?(entry, layers, toolkit)
      end

      # The built-ins +toolkit+ leaves out of a turn under +layers+ that the
      # tool index reaches (call_tool): not in its kit's list, but not
      # removed either (remove:, --no-tool, /toolkit remove), with call_tool
      # itself declared.
      # @return [Array<String>] in declaration order
      def reachable_names(layers: [], toolkit: @toolkit)
        return [] unless call_offered?(toolkit)

        ordered(@entries.values.select { |entry| soft?(entry, layers, toolkit) }).map(&:name)
      end

      # The tools +toolkit+ removes from a turn under +layers+ (remove:,
      # --no-tool, /toolkit remove): only the user brings them back.
      # @return [Array<String>] in declaration order
      def removed_names(layers: [], toolkit: @toolkit)
        return [] if toolkit.nil?

        ordered(@entries.values.select { |entry| entry.offered?(layers) && toolkit.removed.include?(entry.name) })
          .map(&:name)
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

      # Declared by +toolkit+ (nil: every tool, full). The tool index's
      # tools are declared when they reach something, whatever the toolkit:
      # a source registered at load, or a built-in it leaves out but
      # doesn't remove (#index_needed?); unless it removes them.
      def declared?(entry, toolkit = @toolkit)
        if index_entry?(entry)
          !toolkit&.removed&.include?(entry.name) && index_needed?(toolkit)
        else
          toolkit.nil? || toolkit.declares?(entry)
        end
      end

      def index_entry?(entry) = !@index.nil? && entry.source == @index.source

      # From what the plugins registered at load and the toolkit alone, so
      # the declared tools stay the same for a session's life. A built-in
      # left out counts only while call_tool can reach it (not removed).
      def index_needed?(toolkit)
        return true if @index.sourced
        return false if toolkit&.removed&.include?(@index.call_name)

        @entries.each_value.any? { |entry| soft?(entry, [], toolkit) }
      end

      def left_out?(entry, layers, toolkit)
        return false unless entry.offered?(layers) && !declared?(entry, toolkit)

        !index_entry?(entry) || toolkit&.removed&.include?(entry.name) == true
      end

      # A built-in +toolkit+ leaves out of a turn under +layers+ without
      # removing it.
      def soft?(entry, layers, toolkit)
        !toolkit.nil? && entry.core? && entry.offered?(layers) && !toolkit.removed.include?(entry.name) &&
          !toolkit.declares?(entry)
      end

      # Whether +toolkit+ declares the index's call tool.
      def call_offered?(toolkit)
        entry = @index && self[@index.call_name]
        !entry.nil? && declared?(entry, toolkit)
      end

      def ordered(entries)
        core, added = entries.partition(&:core?)
        core + added.sort_by { |entry| [entry.source.to_s, entry.name] }
      end
    end
  end
end
