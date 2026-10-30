# frozen_string_literal: true

require "pathname"
require_relative "path_resolve"
require_relative "../memory_bundle/index_sync"

module Samagotchi
  module Guardrails
    # What `outside_repo` means (a rule's path: and git:): a path is outside
    # when it isn't in the session's repo root (the cwd outside a repo),
    # with symlinks resolved on both sides. Never outside:
    # - a memory's file (MemoryBundle::IndexSync.memory_scope): write/edit
    #   there is what memory_write does; index.md, the bundles dir and the
    #   rest of chi's config dir still count;
    # - a tmp dir (Dir.tmpdir, /tmp, /var/tmp), unless the session's root
    #   is itself in that tmp dir (a sandbox there still gets the check
    #   between its siblings).
    # chi's state dir is not special: nothing there is the model's to write.
    # A path whose landing place resolving can't tell (.resolve: a dangling
    # symlink, a file with another hard link) is always outside.
    module Outside
      TMP_DIRS = PathResolve::TMP_DIRS

      # @param path [String] absolute
      # @param root [String] the session's repo root (or cwd)
      def self.outside?(path, root:)
        reals = resolve(path) or return true
        session = PathResolve.real(root)
        tmp = nil
        reals.any? do |real|
          next false if under_folding_existing?(real, session)
          next false if MemoryBundle::IndexSync.memory_scope(path)
          next false if (tmp ||= session_tmp_roots(session)).any? { |dir| under_folding_existing?(real, dir) }

          true
        end
      end

      # Whether +path+ lands in the session's root every way it resolves
      # (.resolve: never a dangling symlink, nor a file with another hard
      # link). A pair turn's test for a path its command may name
      # (PairCommand), with .tmp_write? for the rest.
      # @param path [String] absolute
      # @param root [String] the session's project root
      def self.inside?(path, root:)
        reals = resolve(path) or return false
        session = PathResolve.real(root)
        reals.all? { |real| under_folding_existing?(real, session) }
      end

      # Whether a shell command may write +path+ as a tmp file (the child
      # boundary's tmp writes): it resolves (.resolve, every way) into a tmp
      # dir the session's root isn't in.
      # @param path [String] absolute
      # @param root [String] the session's repo root (or cwd)
      def self.tmp_write?(path, root:)
        reals = resolve(path) or return false
        session = PathResolve.real(root)
        tmp = session_tmp_roots(session)
        reals.all? { |real| tmp.any? { |dir| under_folding_existing?(real, dir) } }
      end

      # +path+ resolved (PathResolve.reals: the lexical answer and where
      # the kernel lands, a `..` after a symlinked dir climbing out of its
      # target), or nil when that doesn't say where a write lands: the path
      # is or goes through a dangling symlink (a write would create its
      # target; PathResolve.real follows it, the lexical answer stops at
      # it, and either way the link's own place doesn't count as where the
      # file is), or is a file with another hard link (a write would change
      # that file too). Both outside? and tmp_write? read it, so neither
      # counts such a path as inside or in tmp.
      # @param path [String] absolute
      # @return [Array<String>, nil]
      def self.resolve(path)
        reals = PathResolve.reals(path)
        return nil if reals.any? { |real| Pathname.new(real).ascend.any?(&:symlink?) }
        return nil if reals.any? { |real| File.file?(real) && File.stat(real).nlink > 1 }

        reals
      rescue SystemCallError
        nil
      end

      # The tmp dirs that exist, resolved (PathResolve.tmp_roots).
      def self.tmp_roots = PathResolve.tmp_roots

      # The tmp dirs +session+ (resolved) isn't in (PathResolve.tmp_roots).
      def self.session_tmp_roots(session) = PathResolve.tmp_roots(session: session, roots: tmp_roots)

      # Whether +path+ is +root+ or in it (PathResolve.under?): cased alike
      # on a disk that folds case when +root+ exists (resolved, it has its
      # on-disk case), by their exact text when it doesn't (a missing root
      # keeps the case it was typed in).
      def self.under_folding_existing?(path, root) = PathResolve.under?(path, root, fold: File.exist?(root))
    end
  end
end
