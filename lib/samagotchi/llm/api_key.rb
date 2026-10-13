# frozen_string_literal: true

require_relative "errors"

module Samagotchi
  module LLM
    # A host's API key: the environment variable its api_key_env: names,
    # sent on every request LLM::HTTP makes for the host (llama.cpp started
    # with --api-key, or a provider) in the header its +scheme+ names:
    # :bearer `Authorization: Bearer <key>`, :x_api_key `x-api-key: <key>`
    # (Anthropic's Messages API, which refuses a request carrying both).
    # The key itself never goes into a message.
    ApiKey = Data.define(:env_name, :host, :env, :scheme) do
      # nil for a host without api_key_env: its requests carry no header.
      # @param scheme [Symbol, nil] one of ApiKey::SCHEMES; nil is :bearer
      def self.for(env_name, host:, env: ENV, scheme: nil)
        name = env_name.to_s.strip
        name.empty? ? nil : new(env_name: name, host: host.to_s, env: env, scheme: scheme || :bearer)
      end

      def initialize(env_name:, host:, env:, scheme: :bearer)
        raise ArgumentError, "unknown auth scheme #{scheme.inspect}" unless self.class::SCHEMES.include?(scheme)

        super
      end

      # What to try after a 401/403 from a host that has no api_key_env.
      def self.missing_hint(host)
        "the server may want an API key: put it in an environment variable and name it with api_key_env: on host #{host}"
      end

      # Sets the scheme's header (exactly one of the two), or raises
      # AuthError when the variable is not set.
      def authorize(request)
        key = env[env_name].to_s
        raise AuthError.new("#{host}: set #{env_name} (the API key for host #{host})", host: host) if key.strip.empty?

        if scheme == :x_api_key
          request.delete("Authorization")
          request["x-api-key"] = key
        else
          request.delete("x-api-key")
          request["Authorization"] = "Bearer #{key}"
        end
      end

      # What to try after a 401/403 with the key sent.
      def hint = "check #{env_name} (the API key for host #{host})"

      # Without the environment: it holds this key and every other secret.
      def inspect = "#<#{self.class.name} #{env_name} host=#{host}#{" scheme=#{scheme}" unless scheme == :bearer}>"
      alias_method :to_s, :inspect

      def pretty_print(printer) = printer.text(inspect)
    end
    ApiKey::SCHEMES = %i[bearer x_api_key].freeze
  end
end
