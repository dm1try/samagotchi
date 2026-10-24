# frozen_string_literal: true

require_relative "memory_paths"

module Samagotchi
  # A project memory folder left behind by a move: memories copied to a
  # machine (or a path) where the project root differs, so its key
  # (MemoryPaths.project_key: basename + MD5 of the root) differs too, and
  # chi finds no project memories without a word about why.
  #
  # Pure: one listing of the projects dir, no git subprocess. Said at
  # session start (Engine#announce_load_events!, label "memory") and under a
  # memory_read miss (Tools::MemoryRead); never in the system prompt.
  module MemoryOrphans
    # @!attribute computed [String] the folder chi reads (this project's key)
    # @!attribute candidates [Array<String>] same-basename folders, other hashes
    # @!attribute computed_exists [Boolean] whether +computed+ is a folder (empty of memories)
    Found = Data.define(:computed, :candidates, :computed_exists)

    module_function

    # The orphan candidates for +cwd+'s project, or nil: only inside a git
    # repository (outside one the root is cwd, and every src/ or tmp/ would
    # match), and only while the computed folder holds no *.md (a
    # memory_write's mkdir_p or a project-scope bundle install alone must
    # not silence it).
    # @return [Found, nil]
    def find(env: ENV, cwd: Dir.pwd)
      return nil unless MemoryPaths.in_repo?(cwd)

      projects = MemoryPaths.projects_dir(env: env)
      computed = MemoryPaths.project_dir(env: env, cwd: cwd)
      return nil if File.directory?(computed) && Dir.children(computed).any? { |name| name.end_with?(".md") }

      key = File.basename(computed)
      # The root's basename, never a split of a key on "_" (a basename may hold one).
      pattern = /\A#{Regexp.escape(File.basename(MemoryPaths.project_root(cwd)))}_\h{8}\z/
      names = Dir.children(projects).select { |name| name != key && name.match?(pattern) }
      candidates = names.sort.map { |name| File.join(projects, name) }.select { |path| File.directory?(path) }
      return nil if candidates.empty?

      Found.new(computed: computed, candidates: candidates, computed_exists: File.directory?(computed))
    rescue SystemCallError
      nil
    end

    # The one text for the condition (the startup warning and the
    # memory_read hint both say it), or nil when there is none.
    def message(env: ENV, cwd: Dir.pwd)
      found = find(env: env, cwd: cwd)
      found && text(found)
    end

    def text(found)
      computed = found.computed
      lead = "no project memories in #{computed}"
      if found.candidates.size == 1
        candidate = found.candidates.first
        fix = if found.computed_exists
                "move its files into #{computed} (e.g. `mv #{candidate}/* #{computed}/`)"
              else
                "`mv #{candidate} #{computed}`"
              end
        "#{lead}, but #{candidate} has the same project name with another path's hash (memories moved from " \
          "another machine or path?). A name match can't prove it's this project; if it is, #{fix}."
      else
        fix = found.computed_exists ? "move its files into #{computed}" : "`mv <that folder> #{computed}`"
        "#{lead}, but these have the same project name with another path's hash (memories moved from another " \
          "machine or path?): #{found.candidates.join(", ")}. A name match can't prove one is this project; if one " \
          "is, #{fix}."
      end
    end
  end
end
