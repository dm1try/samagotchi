# frozen_string_literal: true

require "open3"

module Samagotchi
  module Guardrails
    # Where a tool call runs and on whose behalf: the process cwd, the
    # session, the host (interface) and who queued the turn (origin). Repo
    # root and branch come from git, asked once per directory per turn.
    class Context
      # :repl — the plain REPL answers on the turn thread;
      # :worker — a shared-session worker (attached TUI / web answer);
      # :non_interactive — nobody can answer (-p --non-interactive, specs).
      INTERFACES = %i[repl worker non_interactive].freeze

      attr_reader :cwd, :session_id, :interface, :origin

      def initialize(cwd: Dir.pwd, session_id: nil, interface: :non_interactive, origin: nil, git: GitInfo.new)
        @cwd = cwd
        @session_id = session_id
        @interface = interface
        @origin = origin
        @git = git
      end

      def repo_root(dir = @cwd) = @git.root(dir)
      # The git hooks dir of +dir+'s repo (core.hooksPath honoured), or nil.
      def hooks_dir(dir = @cwd) = @git.hooks(dir)
      def branch(dir = @cwd) = @git.branch(dir)

      # The hook event's context: hash.
      def to_h
        { cwd: @cwd, repo_root: repo_root, branch: branch, session_id: @session_id,
          interface: @interface, origin: @origin }
      end
    end

    # `git rev-parse` per directory, memoized (one GitInfo per turn).
    class GitInfo
      def initialize
        @cache = {}
        @mutex = Mutex.new
      end

      def root(dir) = info(dir)[:root]
      def hooks(dir) = info(dir)[:hooks]
      def branch(dir) = info(dir)[:branch]

      private

      def info(dir)
        dir = File.expand_path(dir.to_s)
        @mutex.synchronize { @cache[dir] ||= probe(dir) }
      end

      def probe(dir)
        return {} unless File.directory?(dir)

        paths = ["--show-toplevel", "--git-path", "hooks"]
        out, status = Open3.capture2e("git", "-C", dir, "rev-parse", *paths, "--abbrev-ref", "HEAD")
        # A repo with no commits yet has no HEAD: only the paths answer.
        out, status = Open3.capture2e("git", "-C", dir, "rev-parse", *paths) unless status.success?
        return {} unless status.success?

        lines = out.lines.map(&:strip)
        # --git-path is relative to dir (core.hooksPath too).
        { root: lines[0], hooks: lines[1] && File.expand_path(lines[1], dir), branch: lines[2] }
      rescue SystemCallError
        {}
      end
    end
  end
end
