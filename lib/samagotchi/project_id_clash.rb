# frozen_string_literal: true

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
  # last started a session with it (one line; a dotfile, so no *.md glob
  # lists it). Written only here, at session start, never by the key
  # resolver: a read-only command or a memory call must not write.
  ProjectIdClash = Data.define(:root, :other, :id) do
    # The one text for the condition.
    def message
      "#{Paths.tilde(root)} and #{Paths.tilde(other)} share chi project id #{id} (a copied folder?): they share " \
        "memories; `chi project init --new-id` gives this one its own."
    end
  end

  class ProjectIdClash
    CLAIM = ".root"

    # +cwd+'s project, when a marked one with an id: a clash when the claim
    # names another folder that still has a marker with this id; otherwise
    # the claim is set to this root (when it changes; a moved folder just
    # takes it over). Only once the id folder exists: nothing is made for a
    # project with no memories yet.
    # @return [ProjectIdClash, nil]
    def self.check(env: ENV, cwd: Dir.pwd, home: MemoryPaths.default_home)
      found = MemoryPaths.lookup(cwd, home: home)
      return nil unless found.id

      dir = File.join(MemoryPaths.projects_dir(env: env), found.id)
      return nil unless File.directory?(dir)

      claim = File.join(dir, CLAIM)
      other = File.file?(claim) ? File.read(claim, 4096).to_s.lines.first.to_s.strip : ""
      return nil if other == found.root
      return new(root: found.root, other: other, id: found.id) if same_project?(other, found.id, home)

      AtomicFile.write(claim, "#{found.root}\n")
      nil
    rescue SystemCallError
      nil
    end

    # Whether +other+ still is a marked folder with +id+ (not gone, not
    # given another id).
    def self.same_project?(other, id, home)
      return false if other.empty? || !File.directory?(other)

      found = MemoryPaths.lookup(other, home: home)
      found.marker? && found.root == File.realpath(other) && found.id == id
    end
    private_class_method :same_project?
  end
end
