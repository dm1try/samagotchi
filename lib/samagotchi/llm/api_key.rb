# frozen_string_literal: true

require_relative "errors"

module Samagotchi
  module LLM
    # A host's API key: the environment variable its api_key_env: names,
    # sent as `Authorization: Bearer <key>` on every request LLM::HTTP makes
    # for the host (llama.cpp started with --api-key, or a provider). The
    # key itself never goes into a message.
    ApiKey = Data.define(:env_name, :host, :env) do
      # nil for a host without api_key_env: its requests carry no header.
      def self.for(env_name, host:, env: ENV)
        name = env_name.to_s.strip
        name.empty? ? nil : new(env_name: name, host: host.to_s, env: env)
      end

      # What to try after a 401/403 from a host that has no api_key_env.
      def self.missing_hint(host)
        "the server may want an API key: put it in an environment variable and name it with api_key_env: on host #{host}"
      end

      # Sets the header, or raises AuthError when the variable is not set.
      def authorize(request)
        key = env[env_name].to_s
        raise AuthError.new("#{host}: set #{env_name} (the API key for host #{host})", host: host) if key.strip.empty?

        request["Authorization"] = "Bearer #{key}"
      end

      # What to try after a 401/403 with the key sent.
      def hint = "check #{env_name} (the API key for host #{host})"
    end
  end
end
