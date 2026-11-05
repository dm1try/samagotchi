# frozen_string_literal: true

module Samagotchi
  # Bundler's variables, in one place. Every chi spawn that must not carry a
  # `bundle exec` around it takes its names from here.
  module BundlerEnv
    # All Bundler's own and its settings (BUNDLE_PATH, BUNDLE_WITHOUT, ...), for
    # what must take none: a pattern's start (ChiShim, ProjectEnv::RESTORE_NEVER).
    PREFIX = "BUNDLE"
    # What `bundle exec` sets for a child (Bundler::SharedHelpers#set_bundle_variables;
    # bundler_env_spec asks it). Without them, and without Bundler's RUBYOPT, a
    # child ruby is free of the bundle; BUNDLER_SETUP on its own isn't: RubyGems
    # requires what it names at boot, and a Gemfile it then finds writes its lock
    # to BUNDLE_LOCKFILE, the bundle's. A project's own settings (BUNDLE_PATH and
    # the like) aren't here: its `bundle` keeps them. Nor is BUNDLER_ORIG_*, which
    # also reaches a tool: a project's `bundle exec` there reads it, for
    # Bundler.original_env and with_unbundled_env, whose children get the PATH and
    # GEM_* chi's own `bundle exec` started from.
    VARS = %w[BUNDLE_BIN_PATH BUNDLE_GEMFILE BUNDLE_LOCKFILE BUNDLER_SETUP BUNDLER_VERSION].freeze
    # With what else `bundle exec` steers a child ruby by: what a command that
    # isn't the bundle's runs without (TaskRuntime, ProjectEnv, ChiHome.probe).
    CHILD_RUBY = (%w[RUBYOPT RUBYLIB] + VARS).freeze
  end
end
