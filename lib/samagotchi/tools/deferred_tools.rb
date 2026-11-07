# frozen_string_literal: true

require "json"
require_relative "../tool_declarations"

module Samagotchi
  module Tools
    # The tools a request declares deferred (defer_loading: true) on a host
    # that loads tools (LLM::AnthropicMessages#loads_tools?): every tool the
    # session reaches but doesn't declare, so a find_tools hit can load it
    # and the model calls it by its own name. In order:
    # 1. the chi tools (built-ins and plugin tools) the toolkit leaves out
    #    but doesn't remove (ToolSurface#index_only), in registry order;
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

      # @param surface [ToolSurface] the turn's (ToolSurface#deferred_for)
      # @param conversation [Array<Hash>, nil] the request's (engine format)
      # @return [Array<Deferred>]
      def list(surface, conversation)
        deferred = builtins(surface) + sourced(surface)
        taken = deferred.map(&:name)
        loaded_names(conversation).each do |name|
          next if taken.include?(name) || surface.declared_entry(name)

          taken << name
          deferred << Deferred.new(name: name, description: stub_description(surface, name), schema: STUB_SCHEMA)
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

      def builtins(surface)
        surface.index_only.map do |entry|
          schema = ToolDeclarations.chat_schemas([entry.schema]).first
          Deferred.new(name: entry.name, description: schema[:description].to_s, schema: schema[:parameters])
        end
      end

      def sourced(surface)
        index = surface.index
        return [] unless index&.deferrable && surface.declared_entry(index.call_name)

        index.deferrable.call(surface).map do |tool|
          Deferred.new(name: tool.acts_as, description: tool.description, schema: tool.schema)
        end
      end

      def stub_description(surface, name)
        tool = surface.index&.unreached_tool(name, surface)
        return STUB_DESCRIPTION unless tool

        ToolIndex::ToolkitGroupRefusal.for(tool, surface).stub_description
      end

      private_class_method :builtins, :sourced, :stub_description
    end
  end
end
