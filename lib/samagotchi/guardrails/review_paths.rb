# frozen_string_literal: true

require_relative "protected_paths"
require_relative "shell_paths"
require_relative "../paths"

module Samagotchi
  module Guardrails
    # What a participant may read (the shared-sessions plan's §2): a file
    # under the session's project root that isn't on the read denylist
    # (chi's state and config dirs, home secret dirs, project secret files),
    # checked on the path as given and as it resolves (a symlink in the
    # project to ~/.ssh is ~/.ssh). ReviewBoundary asks it for every read of
    # a participant's turn; a review session's subjects (chi review, the
    # participant page's Plan) go through the same check.
    class ReviewPaths
      # Home folders that hold keys and tokens, never read in a review turn.
      HOME_SECRET_DIRS = %w[.ssh .gnupg .aws].freeze
      # Project files that hold secrets, by a path part's name: .env*,
      # netrc, keys and certificates, anything named credentials, package
      # registry tokens (.npmrc, .pypirc), ssh keys, terraform state, a
      # secrets file; and a git config (.git/config, a submodule's
      # .git/modules/x/config), checked apart.
      SECRET_FILE = /\A(?:\.env.*|[._]netrc|.*\.(?:pem|key|p12|pfx|tfstate(?:\.backup)?)|.*credentials.*|
                       \.npmrc|\.pypirc|\.git-credentials|id_(?:rsa|dsa|ecdsa|ed25519)(?:\.pub)?|secrets?\.(?:ya?ml|json))\z/xi
      # The .docker/config.json kind: a dot dir's config holding tokens.
      SECRET_DIR_FILES = { ".docker" => "config.json", ".kube" => "config" }.freeze
      GIT_DIR = ".git"

      # Why a path can't be read (#refusal).
      OUTSIDE = :outside
      SECRET = :secret
      HOME_ROOT = :home_root

      # chi's state dir and config dir, as Paths has them now.
      def self.chi_dirs = [Paths.state_dir, File.join(Paths.config_home, Paths::APP_DIR)]

      # @param root [String, nil] the session's project root (the work tree
      #   top of its folder); nil or blank refuses every path
      # @param denied_dirs [Array<String>] chi's own dirs (state, config:
      #   sessions, grants, the web token, memories and .bundles,
      #   config.yml, hooks)
      # @param home [String, nil]
      def initialize(root:, denied_dirs: ReviewPaths.chi_dirs, home: Dir.home)
        @root = root.to_s
        @denied_dirs = denied_dirs
        @home = home.to_s
      end

      # Why +paths+ can't all be read, or nil when they can: OUTSIDE (no
      # path, no root, or a path outside the root), HOME_ROOT (the root is
      # the home folder or above it) or SECRET.
      # @param paths [Array<String>] absolute, or relative to the cwd
      # @return [Symbol, nil]
      def refusal(paths)
        return OUTSIDE if paths.empty? || @root.empty?

        real_root = ProtectedPaths.real(@root)
        return HOME_ROOT if !@home.empty? && ShellPaths.within?(ProtectedPaths.real(@home), real_root)

        paths.each do |path|
          given = File.expand_path(path)
          real = ProtectedPaths.real(given)
          return OUTSIDE unless ShellPaths.within?(real, real_root)
          return SECRET if secret?(given) || secret?(real)
        end
        nil
      end

      # SECRET when one of +paths+ is on the read denylist (as given or as
      # it resolves), wherever it is; nil otherwise. A pair turn's check
      # (PairBoundary): it reads outside the project too, never these.
      # @param paths [Array<String>] absolute, or relative to the cwd
      # @return [Symbol, nil]
      def secret_refusal(paths)
        paths.each do |path|
          given = File.expand_path(path)
          return SECRET if secret?(given) || secret?(ProtectedPaths.real(given))
        end
        nil
      end

      # Whether +path+ (absolute) is on the read denylist.
      def secret?(path)
        dirs = @denied_dirs.compact.map { |dir| File.expand_path(dir) }
        dirs += dirs.map { |dir| ProtectedPaths.real(dir) }
        dirs += HOME_SECRET_DIRS.map { |dir| File.join(@home, dir) } unless @home.empty?
        return true if dirs.any? { |dir| ShellPaths.within?(path, dir) }

        parts = path.split(File::SEPARATOR)
        return true if parts.any? { |part| SECRET_FILE.match?(part) }
        return true if parts.each_cons(2).any? { |dir, file| SECRET_DIR_FILES[dir.downcase] == file.downcase }

        git_config?(parts)
      end

      private

      # A config file anywhere under a .git dir (.git/config,
      # .git/modules/<sub>/config, a worktree's config.worktree).
      def git_config?(parts)
        git = parts.index { |part| part.casecmp?(GIT_DIR) } or return false
        parts[(git + 1)..].any? { |part| part.downcase.start_with?("config") }
      end
    end
  end
end
