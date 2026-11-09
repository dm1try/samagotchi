# frozen_string_literal: true

require "fileutils"
require_relative "atomic_file"
require_relative "context_sources"
require_relative "guardrails/path_resolve"
require_relative "memory_orphans"
require_relative "memory_paths"
require_relative "paths"
require_relative "project_id"
require_relative "session_paths"

module Samagotchi
  # The shared decisions for `chi project init` and chi web's project picker,
  # and every text they refuse or report with (the CLI prints them). A new
  # marker gets an id (ProjectId); #adopt gives an older marker one, #new_id
  # a copied folder its own.
  module ProjectInit
    # +id+: the project's id (ProjectId), nil for none (a git repository, a
    # marker without one, a refusal).
    Outcome = Data.define(:kind, :reason, :root, :top, :nested_in, :message, :id) do
      def initialize(kind:, reason:, root:, top:, nested_in:, message:, id: nil) = super
    end

    # A folder keyed by the project key (MemoryPaths.key_for): under +base+,
    # named +prefix+ + the key.
    Place = Data.define(:base, :prefix) do
      def path(key) = File.join(base, "#{prefix}#{key}")
    end

    MARKER_TEXT = "# chi project marker: this folder is a chi project (docs/memory.md)\n"

    module_function

    # Marks +dir+ (a new marker gets an id), or says why not. A folder whose
    # path key already names a folder (memories kept while it was no
    # project, keyed by the same path) is marked without an id, so nothing
    # it has goes out of reach: #adopt moves those and writes the id.
    # @param state_dir [String, nil] the sessions dir (SessionPaths.default_state_dir)
    def call(dir, home:, env: ENV, state_dir: nil)
      dir = File.expand_path(dir.to_s)
      found = MemoryPaths.lookup(dir, home: home)
      if found.git?
        message = "#{Paths.tilde(dir)} is in the git repository #{Paths.tilde(found.top)}: the repository already is " \
                  "the project, nothing written"
        return Outcome.new(kind: :git, reason: nil, root: found.root, top: found.top, nested_in: nil, message: message)
      end
      if MemoryPaths.above_home?(dir, home: home)
        message = "#{Paths.tilde(dir)} is $HOME, a folder above it or /: it can't be a chi project " \
                  "(every folder under it would be one); mark a folder inside it"
        return Outcome.new(kind: :refused, reason: :above_home, root: found.root, top: found.top, nested_in: nil,
                           message: message)
      end

      # The marked project this folder sits in, if any: the folder itself (already marked) or its parent project.
      enclosing = found.marker? ? found.root : nil
      if enclosing == Guardrails::PathResolve.real(dir)
        id_part = found.id ? " (id #{found.id})" : ""
        return Outcome.new(kind: :already_marked, reason: nil, root: enclosing, top: found.top, nested_in: nil,
                           message: "#{Paths.tilde(enclosing)} is already a chi project#{id_part}", id: found.id)
      end

      id = write_marker(dir, places(env: env, state_dir: state_dir || SessionPaths.default_state_dir(env: env)))
      root = File.realpath(dir)
      # No message: each surface words its own success (the CLI's report, the web's navigation).
      Outcome.new(kind: :created, reason: nil, root: root, top: root, nested_in: enclosing, message: nil, id: id)
    rescue SystemCallError => e
      marker = File.join(dir, MemoryPaths::MARKER)
      write_failed("couldn't write #{Paths.tilde(marker)}: #{e.message}")
    end

    # `chi project init` (the CLI only: chi web's New-project row calls
    # #call, which never moves folders): #call, and for a marked folder
    # with no valid id, its adoption of one. The folders keyed by its path
    # key (its memories, its project context sources, the skills bundle's
    # kept versions) move to the id, each leaving a link by its old name so
    # an older chi, keying by path, finds the same folder; then the id is
    # written (a crash before that leaves the path key reaching the moved
    # folders through the links, and a rerun finishes with the same id).
    # Refused while a running session belongs to the project: its worker
    # could write a memory under the old name between a move and its link.
    # @param state_dir [String, nil] the sessions dir (SessionPaths.default_state_dir)
    # @param sessions [Array<SessionRow>] this machine's sessions (+live+, +project+, +id+)
    # A folder #call marked without an id is adopted the same way.
    # @param sessions [Array<SessionRow>] this machine's sessions (+live+,
    #   +project+, +cwd+, +id+): a running one in the project (by the root it
    #   stored, else its folder's) refuses
    # @return [Outcome] :adopted (its message the report), :created (its
    #   message what moved, nil when nothing did) or #call's
    def adopt(dir, home:, env: ENV, state_dir: nil, sessions: [])
      state_dir ||= SessionPaths.default_state_dir(env: env)
      outcome = call(dir, home: home, env: env, state_dir: state_dir)
      return outcome unless %i[already_marked created].include?(outcome.kind) && outcome.id.nil?

      root = outcome.root
      running = Array(sessions).select do |row|
        row.live && (row.project ? row.project == root : MemoryPaths.lookup(row.cwd.to_s, home: home).root == root)
      end
      unless running.empty?
        return refused(:running, root, "#{Paths.tilde(root)} has running sessions " \
                                       "(#{running.map { |row| row.id[0, 8] }.join(", ")}): stop them " \
                                       "(chi sessions stop ID) and rerun chi project init, which moves the " \
                                       "project's folders while no session can write to them")
      end

      adopted = adopt_id(root, env: env, state_dir: state_dir)
      return adopted unless outcome.kind == :created && adopted.kind == :adopted

      # A new project: the CLI words its success; the report keeps what moved.
      moved = adopted.message.lines.drop(1).join.chomp
      outcome.with(id: adopted.id, message: moved.empty? ? nil : moved)
    rescue SystemCallError => e
      write_failed("couldn't adopt an id for #{Paths.tilde(outcome&.root || dir.to_s)}: #{e.message}")
    end

    # `chi project init --new-id`: a fresh id for a marked folder (a copied
    # one, going its own way), its folders copied from the key it had to the
    # new id (the copy keeps what it had; the other folder keeps its own).
    # @return [Outcome] :new_id (its message the report) or :refused
    def new_id(dir, home:, env: ENV, state_dir: nil)
      dir = File.expand_path(dir.to_s)
      found = MemoryPaths.lookup(dir, home: home)
      unless found.marker? && found.root == Guardrails::PathResolve.real(dir)
        return refused(:not_marked, nil, "#{Paths.tilde(dir)} is not a marked chi project folder: --new-id gives " \
                                         "one (made with chi project init) an id of its own")
      end

      root = found.root
      old_key = MemoryPaths.key_for(root: root, id: found.id)
      id = ProjectId.generate(File.basename(root))
      lines = ["#{Paths.tilde(root)} has a chi project id of its own now: #{id} (was #{found.id || "none: keyed by its path"})"]
      places(env: env, state_dir: state_dir || SessionPaths.default_state_dir(env: env)).each do |place|
        from = place.path(old_key)
        next unless File.directory?(from)

        to = place.path(id)
        copy_folder(File.realpath(from), to)
        lines << "copied #{Paths.tilde(from)} to #{Paths.tilde(to)}"
      end
      write_id(root, id)
      Outcome.new(kind: :new_id, reason: nil, root: root, top: root, nested_in: nil, message: lines.join("\n"), id: id)
    rescue SystemCallError => e
      write_failed("couldn't give #{Paths.tilde(dir)} a new id: #{e.message}")
    end

    # chi web opens a folder in a git repository without marking it, so the folder has to exist.
    # @return [Outcome, nil] a refused (:write_failed) outcome when it can't be made, else nil
    def ensure_folder(dir)
      FileUtils.mkdir_p(dir) unless File.directory?(dir)
      nil
    rescue SystemCallError => e
      write_failed("couldn't create #{Paths.tilde(dir)}: #{e.message}")
    end

    # The folders a project key names: its memories, its project context
    # sources (where the workers keep them: ContextSources.root), and the
    # skills bundle's kept versions of its project skills (history/
    # project-<key>, the bundle's own data dir).
    # @return [Array<Place>]
    def places(env:, state_dir:)
      [Place.new(base: MemoryPaths.projects_dir(env: env), prefix: ""),
       Place.new(base: File.join(ContextSources.root(state_dir: state_dir), "projects"), prefix: ""),
       Place.new(base: File.join(File.dirname(state_dir), "plugins", "skills", "history"), prefix: "project-")]
    end

    def adopt_id(root, env:, state_dir:)
      problem = ProjectId.read(root).problem
      path_key = MemoryPaths.key_for_root(root)
      # Before the id: what MemoryOrphans finds for the project keyed by its path.
      orphans = MemoryOrphans.find(env: env, cwd: root)
      list = places(env: env, state_dir: state_dir)
      id = resumed_id(list.first, path_key) || ProjectId.generate(File.basename(root))
      taken = list.map { |place| [place.path(path_key), place.path(id)] }
                  .find { |from, to| real_dir?(from) && (File.exist?(to) || File.symlink?(to)) }
      if taken
        return refused(:id_taken, root, "#{Paths.tilde(taken[1])} already exists: chi project init can't move " \
                                        "#{Paths.tilde(taken[0])} there; nothing moved")
      end

      lines = ["#{Paths.tilde(root)} now has the chi project id #{id}: its memories and project context stay " \
               "with it when the folder moves or is renamed"]
      lines << "#{problem}: replaced" if problem
      list.each { |place| lines.concat(move_folder(place.path(path_key), place.path(id))) }
      write_id(root, id)
      if orphans
        keys = orphans.candidates.map { |candidate| "#{Paths.tilde(candidate)} (#{MemoryOrphans.key_note(candidate)})" }
        lines << "memories with this folder's name under another key: #{keys.join(", ")}; if they are this " \
                 "project's, move their files into #{Paths.tilde(list.first.path(id))}"
      end
      Outcome.new(kind: :adopted, reason: nil, root: root, top: root, nested_in: nil, message: lines.join("\n"), id: id)
    end

    # The id an adoption that crashed before writing it chose: the path
    # key already a link to an id folder beside it.
    def resumed_id(place, path_key)
      link = place.path(path_key)
      return nil unless File.symlink?(link)

      target = File.readlink(link)
      target if target.match?(ProjectId::PATTERN) && File.directory?(place.path(target))
    end

    def real_dir?(path) = File.directory?(path) && !File.symlink?(path)

    # Move +from+ to +to+ and leave a link named +from+ (relative: the
    # folder may move with its parent). Nothing to move (no folder, or a
    # link already): no move and no link. A folder made again at +from+
    # between the move and the link has its files moved over (none
    # replaced), then gives way to the link; what was in both stays.
    # @return [Array<String>] the report's lines
    def move_folder(from, to)
      return [] unless real_dir?(from)

      File.rename(from, to)
      begin
        File.symlink(File.basename(to), from)
      rescue Errno::EEXIST
        Dir.children(from).each do |name|
          File.rename(File.join(from, name), File.join(to, name)) unless File.exist?(File.join(to, name))
        end
        unless Dir.empty?(from)
          return ["moved #{Paths.tilde(from)} to #{Paths.tilde(to)}; files written to the old folder meanwhile " \
                  "that #{Paths.tilde(to)} has too stay in #{Paths.tilde(from)}"]
        end

        Dir.rmdir(from)
        File.symlink(File.basename(to), from)
      end
      ["moved #{Paths.tilde(from)} to #{Paths.tilde(to)} (the old name links to it, for an older chi)"]
    end

    # +to+ made a copy of +from+'s files, without the copied project's
    # claim (.root: ProjectIdClash).
    def copy_folder(from, to)
      FileUtils.mkdir_p(to)
      FileUtils.cp_r(File.join(from, "."), to)
      FileUtils.rm_f(File.join(to, ".root"))
    end

    def write_id(root, id)
      marker = File.join(root, MemoryPaths::MARKER)
      AtomicFile.write(marker, ProjectId.with_id(File.read(marker), id))
    end

    def refused(reason, root, message)
      Outcome.new(kind: :refused, reason: reason, root: root, top: root, nested_in: nil, message: message)
    end

    def write_failed(message)
      Outcome.new(kind: :refused, reason: :write_failed, root: nil, top: nil, nested_in: nil, message: message)
    end

    # @param places [Array<Place>] the folders a key names (#places)
    # @return [String, nil] the new marker's id; nil when a folder already
    #   has the path key (#call)
    def write_marker(dir, places)
      marker = File.join(dir, MemoryPaths::MARKER)
      FileUtils.mkdir_p(File.dirname(marker))
      root = File.realpath(dir)
      key = MemoryPaths.key_for_root(root)
      if places.any? { |place| File.exist?(place.path(key)) || File.symlink?(place.path(key)) }
        File.write(marker, MARKER_TEXT)
        return nil
      end

      id = ProjectId.generate(File.basename(root))
      File.write(marker, ProjectId.with_id(MARKER_TEXT, id))
      id
    end
    private_class_method :write_failed, :write_marker, :refused, :adopt_id, :resumed_id, :real_dir?, :move_folder,
                         :copy_folder, :write_id
  end
end
