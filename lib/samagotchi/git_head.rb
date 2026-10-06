# frozen_string_literal: true

require_relative "memory_paths"

module Samagotchi
  # What a folder has checked out, read from its HEAD file without running
  # git (cheap enough for a list of sessions).
  module GitHead
    module_function

    # The branch checked out in +dir+'s repository (a linked worktree's own
    # HEAD is under .git/worktrees/<name>), a short sha when detached.
    # @return [String, nil] nil outside git or for an unreadable HEAD
    def branch(dir)
      git_dir = MemoryPaths.git_dir(dir.to_s)
      head = git_dir && File.read(File.join(git_dir, "HEAD"), 512).to_s.strip
      return nil if head.nil? || head.empty?

      head.start_with?("ref:") ? head.delete_prefix("ref:").strip.delete_prefix("refs/heads/") : head[0, 8]
    rescue SystemCallError
      nil
    end
  end
end
