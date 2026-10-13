# frozen_string_literal: true

require_relative "openai_chat"

module Samagotchi
  module LLM
    # Which chat adapter talks a host's api: the one place that names the
    # adapter classes. A host whose api is a key of BY_API runs the chat loop
    # (HostRegistry::HostEntry#chat?); any other api (nil, raw) the
    # raw-prompt loop.
    module Adapters
      BY_API = { openai: OpenAIChat }.freeze

      # true when +api+ (a Symbol or String) has a chat adapter.
      def self.chat_api?(api) = !api.nil? && BY_API.key?(api.to_sym)

      # A host entry's adapter (its api, API base, name, key and remoteness).
      # @param entry [HostRegistry::HostEntry]
      # @param options [Hash] more adapter options (models_ttl:, first_token_timeout:, ...)
      # @raise [ArgumentError] the entry's api has no chat adapter
      def self.for(entry, **)
        adapter_class(entry.api).for(entry, **)
      end

      def self.adapter_class(api)
        BY_API.fetch(api&.to_sym) { raise ArgumentError, "no chat adapter for api #{api.inspect}" }
      end
      private_class_method :adapter_class
    end
  end
end
