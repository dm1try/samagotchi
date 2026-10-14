# frozen_string_literal: true

require_relative "errors"
require_relative "../host_keys"

module Samagotchi
  module LLM
    # A host's API key: the environment variable its api_key_env: names
    # (else, on macOS, the login Keychain's item for that name: HostKeys),
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
        where = HostKeys.available? ? "an environment variable (or the Keychain)" : "an environment variable"
        "the server may want an API key: put it in #{where} and name it with api_key_env: on host #{host}"
      end

      # Sets the scheme's header (exactly one of the two), or raises
      # AuthError when neither the variable nor the Keychain has the key.
      def authorize(request)
        key = HostKeys.fetch(env_name, env: env)
        raise AuthError.new(unset_message, host: host) unless key

        if scheme == :x_api_key
          request.delete("Authorization")
          request["x-api-key"] = key
        else
          request.delete("x-api-key")
          request["Authorization"] = "Bearer #{key}"
        end
      end

      # What to try after a 401/403 with the key sent, and where it came
      # from (a Keychain key is a cache hit by then).
      def hint
        from = HostKeys.source(env_name, env: env) == :keychain ? " (from the Keychain)" : ""
        "check #{env_name}#{from} (the API key for host #{host})"
      end

      # Without the environment: it holds this key and every other secret.
      def inspect = "#<#{self.class.name} #{env_name} host=#{host}#{" scheme=#{scheme}" unless scheme == :bearer}>"
      alias_method :to_s, :inspect

      def pretty_print(printer) = printer.text(inspect)

      private

      def unset_message
        message = "#{host}: set #{env_name} (the API key for host #{host})"
        return message unless HostKeys.available?

        "#{message} or store it in the Keychain: #{HostKeys.store_command(env_name)}"
      end
    end
    ApiKey::SCHEMES = %i[bearer x_api_key].freeze
  end
end
