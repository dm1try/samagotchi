# frozen_string_literal: true

module Samagotchi
  # The variables that tell a git which repo to act on. A process started by
  # git (`rebase --exec`, `bisect run`, a hook) inherits them, and then its
  # `git -C dir ...`, or a clone into a temp dir, reads or writes that repo
  # instead of dir. chi's own git calls on a path chi chose spawn with UNSET;
  # git then finds the repo from its cwd or -C. A model's and a user's commands
  # (execute, tasks, !cmd) are theirs: they keep what chi was given.
  module GitEnv
    # `git rev-parse --local-env-vars` (git_env_spec checks it) less
    # GIT_CONFIG_COUNT, which only adds settings and which git never sets for
    # a child: like ~/.gitconfig it is the user's (a CI's clone credentials),
    # and the suite's own (spec_helper). spec/e2e/support/env.js asks git for
    # the same list.
    VARS = %w[
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_DIR GIT_GRAFT_FILE
      GIT_IMPLICIT_WORK_TREE GIT_INDEX_FILE GIT_NO_REPLACE_OBJECTS GIT_OBJECT_DIRECTORY GIT_PREFIX
      GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_WORK_TREE
    ].freeze

    # What a spawn takes as its env: Process.spawn unsets a key mapped to nil.
    UNSET = VARS.to_h { |name| [name, nil] }.freeze

    module_function

    # For a test run, as spec_helper and the kit's adapters load: its specs'
    # `git -C tmp init` must not reach the real repo. Clears them for this
    # process and all it starts, also from the copy Bundler keeps of the
    # environment it started in: Bundler.with_unbundled_env and
    # InstalledGem.unbundled_env_changes would put them back in a child.
    def scrub!
      clear(ENV)
      clear(::Bundler::ORIGINAL_ENV) if defined?(::Bundler::ORIGINAL_ENV)
    end

    # @param env [#delete] ENV or a Hash
    def clear(env) = VARS.each { |name| env.delete(name) }
  end
end
