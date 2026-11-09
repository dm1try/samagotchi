# frozen_string_literal: true

require_relative "memory_paths"

module Samagotchi
  # A project memory folder left behind by a move: memories copied to a
  # machine (or a path) where the project root differs, so its key
  # (MemoryPaths.project_key: basename + MD5 of the root) differs too, and
  # chi finds no project memories without a word about why. A marked
  # project with an id is keyed by the id (`<basename>-<8 hex>`, which the
  # pattern never takes for a path key): it is asked about only while its
  # id folder holds no *.md, like any other (memories moved before it had
  # an id). An id folder is a candidate itself for a project keyed by path
  # with the same basename: a marked folder that `git init` made a
  # repository.
  #
  # Pure: one listing of the projects dir, no git subprocess. Said at
  # session start (Engine#announce_load_events!, label "memory") and under a
  # memory_read miss (Tools::MemoryRead); never in the system prompt.
  module MemoryOrphans
    # @!attribute computed [String] the folder chi reads (this project's key)
    # @!attribute candidates [Array<String>] same-basename folders keyed by
    #   another path's hash or by a project id
    # @!attribute computed_exists [Boolean] whether +computed+ is a folder (empty of memories)
    Found = Data.define(:computed, :candidates, :computed_exists)

    # A project keyed by its path is <name>_<8 hex>; a marked project's folder is
    # its id, <name>-<8 hex>.
    PATH_HASH = /_\h{8}\z/

    module_function

    # A candidate folder's key, in words: an earlier path's hash, or a chi project
    # id (a folder marked by `chi project init`, left behind when `git init` makes
    # it a repository). +candidate+ is a folder path.
    def key_note(candidate)
      hash_keyed?(candidate) ? "another path's hash" : "project id #{File.basename(candidate)}"
    end

    # Internal: is this candidate keyed by its path rather than by a project id?
    def hash_keyed?(candidate) = File.basename(candidate).match?(PATH_HASH)
    private_class_method :hash_keyed?

    # The orphan candidates for +cwd+'s project, or nil: only inside a
    # project, a git repository or a marked folder (outside both the root is
    # cwd, and every src/ or tmp/ would match), and only while the computed folder holds no *.md (a
    # memory_write's mkdir_p or a project-scope bundle install alone must
    # not silence it).
    # @return [Found, nil]
    def find(env: ENV, cwd: Dir.pwd)
      return nil unless MemoryPaths.in_project?(cwd)

      projects = MemoryPaths.projects_dir(env: env)
      computed = MemoryPaths.project_dir(env: env, cwd: cwd)
      return nil if File.directory?(computed) && Dir.children(computed).any? { |name| name.end_with?(".md") }

      key = File.basename(computed)
      # The root's basename, never a split of a key on "_" (a basename may hold one): another path's key
      # (<basename>_<8 hex>), or a marked project's id folder (<basename>-<8 hex>, ProjectId) a `git init`
      # in the marked folder (git wins: keyed by its path again) left behind.
      pattern = /\A#{Regexp.escape(File.basename(MemoryPaths.project_root(cwd)))}[_-]\h{8}\z/
      names = Dir.children(projects).select { |name| name != key && name.match?(pattern) }
      # A link is an adopted project's old name (ProjectInit.adopt), never an orphan.
      candidates = names.sort.map { |name| File.join(projects, name) }
                        .select { |path| File.directory?(path) && !File.symlink?(path) }
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

    # A model-facing hint: report the name collision without giving the model
    # a command that could move another live clone's memories.
    def model_message(env: ENV, cwd: Dir.pwd)
      found = find(env: env, cwd: cwd)
      return unless found

      # The project's name is its root folder's basename: splitting the key would
      # print a project id as the name when this project is keyed by one.
      name = File.basename(MemoryPaths.project_root(cwd))
      if found.candidates.size == 1
        candidate = found.candidates.first
        key = if hash_keyed?(candidate)
                "exists with another path's hash"
              else
                "exists, keyed by a project id (#{File.basename(candidate)})"
              end
        "a folder with the same project name (#{name}) #{key}; ask the user whether its memories belong to this " \
          "project before using them."
      else
        list = found.candidates.map { |candidate| "#{candidate} (#{key_note(candidate)})" }.join(", ")
        "folders with the same project name (#{name}) exist under other keys (#{list}); ask the user whether their " \
          "memories belong to this project before using them."
      end
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
        why = if hash_keyed?(candidate)
                "has the same project name with #{key_note(candidate)} (memories moved from another machine or " \
                  "path?)"
              else
                "has the same project name keyed by a project id (#{File.basename(candidate)}): the folder " \
                "chi project init marked, keyed by its id instead of its path"
              end
        "#{lead}, but #{candidate} #{why}. A name match can't prove it's this project; if it is, #{fix}."
      else
        fix = found.computed_exists ? "move its files into #{computed}" : "`mv <that folder> #{computed}`"
        list = found.candidates.map { |candidate| "#{candidate} (#{key_note(candidate)})" }.join(", ")
        "#{lead}, but these have the same project name (memories moved from another machine or path?): " \
          "#{list}. A name match can't prove one is this project; if one is, #{fix}."
      end
    end
  end
end
