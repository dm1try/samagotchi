# frozen_string_literal: true

require_relative "memory_paths"

module Samagotchi
  # Which project a folder belongs to, for scoping session lists (web and
  # terminal alike): the project root memories use (MemoryPaths.lookup), so
  # every worktree and subfolder of one repository, or every subfolder of a
  # folder marked by `chi project init`, is one project. A folder in neither
  # has no project (nil): its scope is "all".
  module ProjectScope
    module_function

    # @param cache [Hash, nil] folder → root, reused across one listing
    # @return [String, nil]
    def root_for(dir, cache: nil)
      dir = dir.to_s
      return nil if dir.empty?
      return cache[dir] if cache&.key?(dir)

      found = MemoryPaths.lookup(File.expand_path(dir))
      root = found.project? ? found.root : nil
      cache[dir] = root if cache
      root
    end
  end
end
