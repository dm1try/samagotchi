# frozen_string_literal: true

require "json"
require_relative "../tool_declarations"

module Samagotchi
  module Tools
    # The tools a request declares deferred (defer_loading: true) on a host
    # that loads tools (LLM::AnthropicMessages#loads_tools?): every tool the
    # session reaches but doesn't declare, so a find_tools hit can load it
    # and the model calls it by its own name. In order:
    # 1. the built-ins the toolkit leaves out but doesn't remove
    #    (Registry#reachable_names), in registry order;
    # 2. the tool index's source tools (an MCP server's, by acts_as), only
    #    while call_tool is declared (ToolIndex#deferrable: sorted by name);
    # 3. every other name the conversation loaded (a find result's
    #    loaded:, a tool change's add:) that isn't declared: a stub (its
    #    source is gone, or hasn't published yet), so the reference in the
    #    history stays valid. The runner refuses its calls as any other.
    # The list goes after the declared tools, outside the cached prefix's
    # marks: a tool joining it (a late server) keeps the cache.
    module DeferredTools
      # One deferred tool: its wire name, description and input schema.
      Deferred = Data.define(:name, :description, :schema)

      STUB_DESCRIPTION = "Not available right now; find_tools finds it when it is."
      STUB_SCHEMA = { "type" => "object", "properties" => {} }.freeze

      module_function

      # @param registry [Registry]
      # @param conversation [Array<Hash>, nil] the request's (engine format)
      # @param layers [Array<Symbol>] the turn's LLM context layers
      # @return [Array<Deferred>]
      def list(registry, conversation, layers: [])
        deferred = builtins(registry, layers) + sourced(registry, layers)
        taken = deferred.map(&:name)
        loaded_names(conversation).each do |name|
          next if taken.include?(name) || registry.offered(name, layers: layers)

          taken << name
          deferred << Deferred.new(name: name, description: STUB_DESCRIPTION, schema: STUB_SCHEMA)
        end
        deferred
      end

      # The names +conversation+ loaded, first reference first: a find
      # result's loaded: (ToolResponse::LOADED), a tool change's add:.
      # @return [Array<String>]
      def loaded_names(conversation)
        Array(conversation).flat_map do |entry|
          names = entry[:loaded] || entry["loaded"]
          change = entry[:tool_change] || entry["tool_change"]
          names = change[:add] || change["add"] if change.is_a?(Hash)
          Array(names).map(&:to_s)
        end.uniq
      end

      def builtins(registry, layers)
        return [] unless registry.respond_to?(:reachable_names)

        registry.reachable_names(layers: layers).map do |name|
          schema = ToolDeclarations.chat_schemas([registry[name].schema]).first
          Deferred.new(name: name, description: schema[:description].to_s, schema: schema[:parameters])
        end
      end

      def sourced(registry, layers)
        index = registry.respond_to?(:index) ? registry.index : nil
        return [] unless index&.deferrable && registry.offered(index.call_name, layers: layers)

        index.deferrable.call.map do |tool|
          Deferred.new(name: tool.acts_as, description: tool.description, schema: tool.schema)
        end
      end

      private_class_method :builtins, :sourced
    end
  end
end
