# frozen_string_literal: true

require_relative "installed_gem"
require_relative "installed_versions"
require_relative "project_env"

module Samagotchi
  # What a chi process another chi starts must not take from its spawner's
  # environment, in one place: a session's worker (SessionManager's
  # spawn_options) and `chi bundle try`'s sandboxed child
  # (BundleCommand::Try::Sandbox) both scrub these. Each adds its own policy
  # on top (the worker passes the CLI settings and the log file; try drops
  # the user's config sections too).
  module ChildEnv
    # The spawner's guardrails settings: never a child's (docs/guardrails.md).
    GUARDRAILS_PREFIX = "SAMAGOTCHI_GUARDRAILS_"
    # A worker's own markers (SessionManager::WORKER_PROCESS_ENV, ...).
    WORKER_PREFIX = "SAMAGOTCHI_WORKER_"
    # The markers a session's execute and tasks export
    # (Tools::Builtins.parent_env): that session's, not a child chi's.
    SESSION_MARKERS = %w[SAMAGOTCHI_PARENT_SESSION SAMAGOTCHI_SESSION_MODEL SAMAGOTCHI_SESSION_THINKING
                         SAMAGOTCHI_SESSION_REASONING_HISTORY].freeze
    # "1" in the chi update an automatic run starts (Web::UpdateOps): no person
    # reads its rows. An env marker, so it reaches the chi a hand-over or the home
    # execs, and an older chi that doesn't know it simply ignores it.
    UNATTENDED_UPDATE = "SAMAGOTCHI_UPDATE_UNATTENDED"

    module_function

    # The keys of +env+ a child chi must not inherit: the guardrails
    # settings, the session markers, a smoke's fake "newest installed"
    # (InstalledVersions::ENV_KEY, for the spawner's notices only), the
    # worker's project env marker and record (a child worker applies its own) and
    # an automatic update's marker (a session someone starts from one isn't it; the
    # update's own hand-over execs, which this doesn't touch).
    # @return [Array<String>]
    def spawner_keys(env = ENV)
      env.each_key.select { |key| key.start_with?(GUARDRAILS_PREFIX) } + SESSION_MARKERS +
        [InstalledVersions::ENV_KEY, ProjectEnv::MARKER_ENV, ProjectEnv::ORIG_ENV, UNATTENDED_UPDATE]
    end

    # #spawner_keys mapped to nil: Process.spawn unsets a key mapped to nil.
    # @return [Hash{String=>nil}]
    def unset(env = ENV) = spawner_keys(env).to_h { |key| [key, nil] }

    # +env+ without #spawner_keys (a copy).
    # @param env [Hash]
    # @return [Hash]
    def scrub(env) = env.except(*spawner_keys(env))

    # +env+ as a spawn argument that really removes what it leaves out. A Hash
    # given to Process.spawn, Open3 or exec is merged onto the spawner's
    # environment: a key only deleted from it is still inherited by the child.
    # Every key +spawner+ has and +env+ doesn't is mapped to nil, which
    # Process.spawn unsets, so the child sees exactly +env+ (and #scrub is
    # safe to use with it). +env+ is not changed.
    # @param env [Hash]
    # @param spawner [Hash] the spawner's environment (default: ENV)
    # @return [Hash]
    def spawn_env(env, spawner: ENV)
      out = env.dup
      spawner.each_key { |key| out[key] = nil unless out.key?(key) }
      out
    end

    # In gem mode, what Bundler changed in +env+ mapped back
    # (InstalledGem.unbundled_env_changes): a child activates the installed
    # gem itself rather than inherit this app's bundle. {} in a checkout.
    # @return [Hash{String=>String, nil}]
    def unbundled(env = ENV.to_h)
      InstalledGem.spec ? InstalledGem.unbundled_env_changes(env) : {}
    end
  end
end
