# frozen_string_literal: true

require_relative "../config"
require_relative "../paths"
require_relative "../memory_paths"
require_relative "../hooks/loader"
require_relative "path_resolve"

module Samagotchi
  module Guardrails
    # chi's own dirs, the sets the guardrails judge a path or a command's
    # words against, as this process's environment and config.yml name them
    # (read each call). Each surface keeps its set:
    #   .protected     the config dir, the hooks dir, the approval store's
    #                  dir, the installed bundles' dir, attached context: an
    #                  ask only the user may answer (ParentApprovals.chi_files?)
    #   .touches       .protected and the session repo's git hooks dir: a
    #                  rule's touches: chi_dirs (Targets#touches_chi?)
    #   .self_protect  .protected and the whole state dir, resolved: what
    #                  System 1 never answers for (SelfProtect)
    #   .review        the state dir, the config dir and a hooks dir
    #                  configured outside it: what a participant's turn never
    #                  reads (ReviewPaths)
    # ProtectedPaths' deny/ask lists and ScratchWrites' memories dir are
    # built by the wiring from the same places.
    module ChiDirs
      module_function

      # chi's config dir, the hooks dir, the approval store's dir, the
      # installed bundles' dir and attached context.
      def protected
        hooks = begin Hooks::Loader.hooks_dir rescue nil end
        bundles = begin MemoryPaths.bundles_dir rescue nil end
        [ConfigFile.config_dir, hooks, File.join(Paths.state_dir, "guardrails"), bundles, File.join(Paths.state_dir, "context")]
          .compact.map { |dir| dir.to_s.chomp("/") }.reject(&:empty?).uniq
      end

      # .protected (as ParentApprovals.chi_dirs, the name its callers and
      # specs know) and the git hooks dir of +base+'s repo (+context+).
      def touches(context, base)
        require_relative "parent_approvals"
        ParentApprovals.chi_dirs + [context.hooks_dir(base)].compact
      end

      # .protected (as ParentApprovals.chi_dirs) and the whole state dir,
      # resolved.
      def self_protect
        require_relative "parent_approvals"
        [*ParentApprovals.chi_dirs, Paths.state_dir]
          .map { |dir| PathResolve.real(dir.to_s.chomp("/")) }.reject(&:empty?).uniq
      end

      # chi's state dir and config dir, as Paths has them now, and the hooks
      # dir when config.yml puts it outside the config dir (hooks run as the
      # owner: a participant reads none of them).
      def review
        config = File.join(Paths.config_home, Paths::APP_DIR)
        hooks = begin Hooks::Loader.hooks_dir rescue nil end
        hooks = nil if hooks.to_s.empty? || PathResolve.reals(hooks).any? { |real| PathResolve.within?(real, config) }
        [Paths.state_dir, config, hooks].compact
      end
    end
  end
end
