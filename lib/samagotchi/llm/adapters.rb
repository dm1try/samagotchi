# frozen_string_literal: true

require_relative "openai_chat"
require_relative "anthropic_messages"

module Samagotchi
  module LLM
    # Which chat adapter talks a host's api: the one place that names the
    # adapter classes. A host whose api is a key of BY_API runs the chat loop
    # (HostRegistry::HostEntry#chat?); any other api (nil, raw) the
    # raw-prompt loop.
    module Adapters
      BY_API = { openai: OpenAIChat, anthropic: AnthropicMessages }.freeze

      # true when +api+ (a Symbol or String) has a chat adapter.
      def self.chat_api?(api) = !api.nil? && BY_API.key?(api.to_sym)

      # A host entry's adapter (its api, API base, name, key and remoteness).
      # @param entry [HostRegistry::HostEntry]
      # @param options [Hash] more adapter options (models_ttl:, first_token_timeout:, ...)
      # @raise [ArgumentError] the entry's api has no chat adapter
      def self.for(entry, **)
        adapter_class(entry.api).for(entry, **)
      end

      # An adapter by api, for a side request that has a url rather than a
      # host entry (IdleClient: a recap, ctx.ask_model, a broadcast's triage).
      # @param api [Symbol, String] a key of BY_API
      # @param options [Hash] more adapter options (stream:, retries:, timeout:, ...)
      # @raise [ArgumentError] +api+ has no chat adapter
      def self.build(api:, base_url:, host_name:, api_key_env: nil, **)
        adapter_class(api).new(base_url: base_url, host_name: host_name, api_key_env: api_key_env, **)
      end

      def self.adapter_class(api)
        BY_API.fetch(api&.to_sym) { raise ArgumentError, "no chat adapter for api #{api.inspect}" }
      end
      private_class_method :adapter_class
    end
  end
end
