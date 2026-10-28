# frozen_string_literal: true

require "pathname"
require "tmpdir"
require_relative "protected_paths"
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
    module Outside
      TMP_DIRS = %w[/tmp /var/tmp].freeze

      # @param path [String] absolute
      # @param root [String] the session's repo root (or cwd)
      def self.outside?(path, root:)
        real = ProtectedPaths.real(path)
        session = ProtectedPaths.real(root)
        return false if within?(real, session)
        return false if MemoryBundle::IndexSync.memory_scope(path)
        return false if tmp_roots.any? { |tmp| within?(real, tmp) && !within?(session, tmp) }

        true
      end

      # Whether a shell command may write +path+ as a tmp file (the child
      # boundary's tmp writes): resolved, it is in a tmp dir the session's
      # root isn't in, and it is neither a dangling symlink (a write would
      # create its target) nor a file with another hard link (a write would
      # change that file too).
      # @param path [String] absolute
      # @param root [String] the session's repo root (or cwd)
      def self.tmp_write?(path, root:)
        real = ProtectedPaths.real(path)
        session = ProtectedPaths.real(root)
        return false unless tmp_roots.any? { |tmp| within?(real, tmp) && !within?(session, tmp) }
        return false if Pathname.new(real).ascend.any?(&:symlink?)

        !(File.file?(real) && File.stat(real).nlink > 1)
      rescue SystemCallError
        false
      end

      # The tmp dirs that exist, resolved.
      def self.tmp_roots
        [Dir.tmpdir, *TMP_DIRS].filter_map do |dir|
          File.realpath(dir) if File.directory?(dir)
        rescue SystemCallError
          nil
        end.uniq
      end

      def self.within?(path, root) = path == root || path.start_with?(File.join(root, ""))
    end
  end
end
