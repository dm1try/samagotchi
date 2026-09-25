# frozen_string_literal: true

require_relative "memory_paths"

module Samagotchi
  # Which project a folder belongs to, for scoping session lists (web and
  # terminal alike): the project root memories use (MemoryPaths.project_root),
  # so every worktree and subfolder of one repository is one project. A
  # folder in no git repository has no project (nil): its scope is "all".
  module ProjectScope
    module_function

    # @param cache [Hash, nil] folder → root, reused across one listing
    # @return [String, nil]
    def root_for(dir, cache: nil)
      dir = dir.to_s
      return nil if dir.empty?
      return cache[dir] if cache&.key?(dir)

      root = MemoryPaths.in_repo?(dir) ? MemoryPaths.project_root(File.expand_path(dir)) : nil
      cache[dir] = root if cache
      root
    end
  end
end
