# frozen_string_literal: true

module Samagotchi
  # The tools plugins load (ctx.load_tools), staged until a turn's messages
  # are built (Engine#turn_messages): then each bundle's names go into the
  # conversation as one system entry of kind KIND, which a host that takes
  # tool changes (LLM::AnthropicMessages#tool_changes?) receives as a
  # tool_addition by reference. The names are wire names a request declares
  # deferred (Tools::DeferredTools): a built-in's, a source tool's acts_as.
  # Staging is idempotent: a name already staged is staged once.
  class ToolLoads
    KIND = "tool_change"
    # The entry's key for what it adds: {add: [names], by: bundle}.
    KEY = :tool_change

    def initialize
      @mutex = Mutex.new
      @staged = {}
    end

    # Stage +names+ for bundle +by+.
    # @return [Array<String>] the names newly staged
    def stage(names, by:)
      @mutex.synchronize do
        taken = @staged.values.flatten
        fresh = names.uniq - taken
        (@staged[by.to_s] ||= []).concat(fresh) unless fresh.empty?
        fresh
      end
    end

    def any? = @mutex.synchronize { @staged.any? }

    # The staged names per bundle, cleared.
    # @return [Hash{String => Array<String>}]
    def take
      @mutex.synchronize do
        staged = @staged
        @staged = {}
        staged
      end
    end

    # The conversation entry for bundle +by+'s +names+.
    def self.entry(names, by:)
      { role: "system", kind: KIND, content: "[tools loaded: #{names.join(", ")} (#{by})]",
        KEY => { add: names, by: by } }
    end

    # Whether +entry+ is one of #entry's (string or symbol keys).
    def self.entry?(entry) = entry.is_a?(Hash) && (entry[:kind] || entry["kind"]).to_s == KIND

    # The names +messages+' tool change entries added.
    # @return [Array<String>]
    def self.added(messages)
      Array(messages).select { |entry| entry?(entry) }.flat_map do |entry|
        change = entry[KEY] || entry[KEY.to_s] || {}
        Array(change[:add] || change["add"]).map(&:to_s)
      end
    end
  end
end
