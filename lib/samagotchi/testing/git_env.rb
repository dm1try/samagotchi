# frozen_string_literal: true

module Samagotchi
  module Testing
    # The variables that tell a git which repo to act on. A test run started
    # by git (`rebase --exec`, `bisect run`, a hook) inherits them, and then a
    # test's `git -C tmp init`, or `git -C tmp config user.name`, acts on the
    # real repo, not on its temp one. spec_helper and the kit's adapters clear
    # them as they load; plain git then finds the repo from its cwd or -C.
    module GitEnv
      # `git rev-parse --local-env-vars` (git_env_spec checks it) less
      # GIT_CONFIG_COUNT, which only adds settings: spec_helper sets its own.
      VARS = %w[
        GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_DIR GIT_GRAFT_FILE
        GIT_IMPLICIT_WORK_TREE GIT_INDEX_FILE GIT_NO_REPLACE_OBJECTS GIT_OBJECT_DIRECTORY GIT_PREFIX
        GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_WORK_TREE
      ].freeze

      module_function

      # Clear them for this process and all it starts, also from the copy
      # Bundler keeps of the environment it started in: Bundler.with_unbundled_env
      # and InstalledGem.unbundled_env_changes would put them back in a child.
      def scrub!
        clear(ENV)
        clear(::Bundler::ORIGINAL_ENV) if defined?(::Bundler::ORIGINAL_ENV)
      end

      # @param env [#delete] ENV or a Hash
      def clear(env) = VARS.each { |name| env.delete(name) }
    end
  end
end
