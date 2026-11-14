# frozen_string_literal: true

require "json"
require_relative "bundler_env"
require_relative "child_env"

module Samagotchi
  # The env a command chi spawns for the model gets: chi's own Ruby/Bundler
  # setup kept out (execute, task_create, and through ProjectEnv.spawn_env
  # the MCP servers and context sources), and the checks on task_create's
  # +env+ argument. No process code: Tools::TaskRuntime runs the task.
  #
  # ProjectEnv.spawn_env requires this file when it is called, never as it
  # loads: child_env requires project_env.
  module SpawnEnv
    SANITIZED_ENV_KEYS = BundlerEnv::CHILD_RUBY
    # Set by chi (Builtins.parent_env); the model's env can't change it.
    MARKER_ENV_KEYS = ChildEnv::SESSION_MARKERS

    module_function

    # chi's own Ruby/Bundler setup, kept out of a command's environment
    # (execute and task_create both spawn with it): run under `bundle
    # exec`, chi would otherwise hand a project's `ruby -e` or
    # `bundle exec` its Gemfile (RUBYOPT=-rbundler/setup, BUNDLE_GEMFILE,
    # BUNDLER_SETUP) and lockfile.
    def sanitized_spawn_env
      SANITIZED_ENV_KEYS.to_h { |key| [key, nil] }.merge("RUBYOPT" => sanitized_rubyopt)
    end

    # The model's way out: a Ruby or Bundler variable it does want, for one command.
    def sanitized_key_error(key)
      "Error: env key is reserved: #{key} (chi clears it for every command; to set it for this one, " \
        "put it in the command: #{key}=value cmd)"
    end

    # task_create's env: the scrub, then the model's +overrides+ (a Hash or
    # a JSON object string), refused when they name a key chi sets.
    # @return [Array(Hash, nil), Array(nil, String)] the env, or an error
    def spawn_env_for(overrides)
      return [sanitized_spawn_env, nil] if overrides.nil? || overrides.to_s.empty?

      overrides = JSON.parse(overrides) if overrides.is_a?(String)
      return [nil, "Error: env must be an object"] unless overrides.is_a?(Hash)

      normalized = {}
      overrides.each do |key, value|
        return [nil, "Error: env keys and values must be strings"] unless key.is_a?(String) && value.is_a?(String)
        return [nil, "Error: env keys and values cannot contain NUL bytes"] if key.include?("\0") || value.include?("\0")
        return [nil, "Error: env key is reserved: #{key}"] if MARKER_ENV_KEYS.include?(key)
        return [nil, sanitized_key_error(key)] if SANITIZED_ENV_KEYS.include?(key)

        normalized[key] = value
      end

      [sanitized_spawn_env.merge(normalized), nil]
    rescue JSON::ParserError
      [nil, "Error: env must be a JSON object"]
    end

    def sanitized_rubyopt
      rubyopt = ENV["RUBYOPT"].to_s
      return nil if rubyopt.empty?

      filtered = rubyopt.split(/\s+/).reject do |arg|
        arg == "-rbundler/setup" || arg.match?(%r{\A-r.*bundler/setup\z})
      end
      return nil if filtered.empty?

      filtered.join(" ")
    end

    private_class_method :sanitized_key_error, :sanitized_rubyopt
  end
end
