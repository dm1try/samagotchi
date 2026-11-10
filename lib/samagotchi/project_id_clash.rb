# frozen_string_literal: true

require "fileutils"
require_relative "atomic_file"
require_relative "memory_paths"
require_relative "paths"

module Samagotchi
  # Two folders with one chi project id: a marked folder copied (cp -R)
  # keeps its marker, so the copy shares the original's memories. Told at
  # session start (Engine#announce_load_events!, label "memory", beside
  # MemoryOrphans), at every session start while it lasts.
  #
  # The claim: an id-keyed memories folder's `.root` names the folder that
  # owns it (one line; a dotfile, so no *.md glob lists it). A new folder is
  # claimed before use; init also claims folders it moves or copies.
  ProjectIdClash = Data.define(:root, :other, :id, :folder) do
    def initialize(root:, other:, id:, folder: File.join(MemoryPaths.projects_dir, id))
      super
    end

    # The one text for the condition.
    def message
      if other.empty?
        "#{folder} already exists and is not claimed by #{Paths.tilde(root)}; run `chi project init --new-id` " \
          "to give this project its own id"
      else
        "#{Paths.tilde(root)} and #{Paths.tilde(other)} share chi project id #{id} (a copied folder?): " \
          "#{folder} is already in use. Run `chi project init --new-id` in the copy to give it its own."
      end
    end
  end

  class ProjectIdClash
    CLAIM = MemoryPaths::CLAIM

    # +cwd+'s project, when a marked one with an id: a clash when the id
    # folder is already taken; otherwise the folder is claimed for this root
    # (a moved folder just takes it over).
    # @return [ProjectIdClash, nil]
    def self.check(env: ENV, cwd: Dir.pwd, home: MemoryPaths.default_home)
      found = MemoryPaths.lookup(cwd, home: home)
      return nil unless found.id

      dir = File.join(MemoryPaths.projects_dir(env: env), found.id)
      unless File.exist?(dir) || File.symlink?(dir)
        FileUtils.mkdir_p(File.dirname(dir))
        created = begin
          Dir.mkdir(dir)
          true
        rescue Errno::EEXIST
          false
        end
        if created
          AtomicFile.write(File.join(dir, CLAIM), "#{found.root}\n")
          return nil
        end
      end

      claim = File.join(dir, CLAIM)
      other = File.file?(claim) ? File.read(claim, 4096).to_s.lines.first.to_s.strip : ""
      conflict = MemoryPaths.project_id_conflict(root: found.root, id: found.id, env: env, home: home)
      return new(root: found.root, other: other, id: found.id, folder: dir) if conflict

      AtomicFile.write(claim, "#{found.root}\n") unless other == found.root
      nil
    rescue SystemCallError
      # Session start goes on: a memories folder chi can't make or claim
      # is no clash to warn about.
      nil
    end
  end
end
