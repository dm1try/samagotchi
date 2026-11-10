# frozen_string_literal: true

require "fileutils"
require_relative "guardrails/path_resolve"
require_relative "memory_paths"
require_relative "paths"

module Samagotchi
  # Memories saved from a subfolder of a marked project before
  # `chi project init`: a session there keyed them by its own path
  # (MemoryPaths.lookup was :none, the root its cwd), and after init the
  # subfolder resolves to the project, so that folder is out of reach.
  #
  # A path key can't be reversed, so the candidates come only from this
  # machine's session rows (each stores the root it keyed by: a project-less
  # session's is its cwd); memories older than the sessions kept are not
  # found (docs/memory.md: move them by hand). No directory walk: one
  # listing of the sessions, one stat per row. Memories only: a subfolder's
  # project context sources and skills history stay where they are.
  #
  # The one text for the condition is #message (`chi project init`'s report
  # and `chi project`'s note); #merge (`chi project init --merge-subfolders`)
  # moves them, #running_message refuses while a session could write.
  module ProjectSubfolders
    # +path+: the subfolder a session keyed its memories by; +dir+: that
    # memories folder; +count+: the memories in it.
    Found = Data.define(:path, :dir, :count)

    FLAG = "--merge-subfolders"
    INDEX = "index.md"
    # What an emptied folder may still hold, none of it moved: the index
    # (removed only when #hand_written? says it holds nothing of the user's),
    # IndexUpdater's lock, and .root: ProjectIdClash's claim, written only in
    # an id folder, so in a path-keyed one it is a copy's stray (a copied
    # id folder renamed by hand) that names no folder this key belongs to.
    LEFTOVERS = [INDEX, ".index.lock", ".root"].freeze

    module_function

    # The subfolders of +root+ (a marked project's realpath) whose
    # path-keyed memories folder exists: a row's stored root under +root+
    # that resolves to +root+ now (a nested git repository or marked folder
    # is its own project; a symlink out of +root+ resolves elsewhere).
    # @param sessions [Array<SessionRow>] this machine's sessions (+project+, +cwd+)
    # @return [Array<Found>] sorted by path
    def find(root, sessions:, env: ENV, home: MemoryPaths.default_home)
      projects = MemoryPaths.projects_dir(env: env)
      seen = {}
      Array(sessions).each do |row|
        path = (row.project || row.cwd).to_s
        next if path.empty? || seen.key?(path)

        seen[path] = nil
        real = Guardrails::PathResolve.real(path)
        next if real == root || !Guardrails::PathResolve.under?(real, root)
        next unless MemoryPaths.lookup(path, home: home).root == root

        dir = File.join(projects, MemoryPaths.key_for_root(path))
        next unless File.directory?(dir) && !File.symlink?(dir)

        count = entries(dir).size
        seen[path] = Found.new(path: path, dir: dir, count: count) if count.positive?
      end
      seen.values.compact.uniq(&:dir).sort_by(&:path)
    end

    # The one text for found subfolder memories, or nil for none.
    def message(found)
      return nil if found.empty?

      list = found.map { |item| "#{Paths.tilde(item.path)} (#{item.count} #{item.count == 1 ? "memory" : "memories"})" }
      "memories saved from subfolders before init: #{list.join(", ")}; move them into the project with " \
        "chi project init #{FLAG}"
    end

    # The running sessions that refuse a merge: under +root+ by the root
    # they stored or by their folder (a live pre-init session stored its cwd).
    def running(root, sessions:, home: MemoryPaths.default_home)
      Array(sessions).select do |row|
        next false unless row.live

        [row.project, row.cwd].compact.map(&:to_s).reject(&:empty?).any? do |path|
          Guardrails::PathResolve.under?(Guardrails::PathResolve.real(path), root) ||
            MemoryPaths.lookup(path, home: home).root == root
        end
      end
    end

    def running_message(root, rows)
      "#{Paths.tilde(root)} has running sessions (#{rows.map { |row| row.id[0, 8] }.join(", ")}): stop them " \
        "(chi sessions stop ID) and rerun chi project init #{FLAG}, which moves the subfolders' memories while " \
        "no session can write to them"
    end

    # Moves each found folder's memories (the file, its model overlays,
    # its index line) into +target+ (the project's memories folder). One
    # the project has by that name, or a bundle owns, stays and is named;
    # an emptied folder is removed, with no link: every chi that knows
    # markers resolves the subfolder to the project, and a link would hide
    # a folder made there again from #find.
    # @return [Array<String>] the report's lines
    def merge(found, target:, env: ENV)
      require_relative "memory_bundle/index_updater"
      require_relative "memory_bundle/provenance"
      require_relative "tools/memory"
      lines = []
      found.each { |item| lines.concat(merge_one(item, target, env)) }
      lines << "no memories saved from subfolders before init to move" if lines.empty?
      lines
    end

    # The entries of a memories folder: each <name>.md but the index and
    # the model overlays of another entry (Tools::MemoryWrite.overlay_files),
    # with its managed index line (or nil).
    # @return [Hash{String => String, nil}] name → line
    def entries(dir)
      index_text = index_text(dir)
      names = Dir.children(dir).select { |name| name.end_with?(".md") && name != INDEX && File.file?(File.join(dir, name)) }
                 .map { |name| name.delete_suffix(".md") }.sort
      require_relative "tools/memory"
      overlays = names.flat_map { |name| Tools::MemoryWrite.overlay_files(dir, name, index_text) }
                      .map { |path| File.basename(path, ".md") }
      (names - overlays).to_h { |name| [name, index_text[Tools::MemoryWrite.managed_pattern(name)]&.chomp] }
    end

    def index_text(dir)
      path = File.join(dir, INDEX)
      File.file?(path) ? File.read(path, encoding: "UTF-8") : ""
    end

    def merge_one(item, target, env)
      from = item.dir
      index_text = index_text(from)
      moved = []
      kept = []
      entries(from).each do |name, line|
        files = [File.join(from, "#{name}.md")] + Tools::MemoryWrite.overlay_files(from, name, index_text)
        owner = MemoryBundle::Provenance.claimants("#{name}.md", scope: "project",
                                                                 dir: MemoryPaths.bundles_dir(env: env)).first ||
                (line && MemoryBundle::IndexUpdater.extract_source(line))
        next kept << "#{name} (from bundle #{owner})" if owner
        next kept << "#{name} (the project has one by that name)" if files.any? { |path| File.exist?(File.join(target, File.basename(path))) }

        FileUtils.mkdir_p(target)
        bytes = File.size(files.first)
        files.each { |path| File.rename(path, File.join(target, File.basename(path))) }
        description = line && MemoryBundle::IndexUpdater.extract_description(line)
        MemoryBundle::IndexUpdater.update_index("project", name, bytes, description, target_dir: target)
        MemoryBundle::IndexUpdater.remove_index("project", name, target_dir: from)
        moved << name
      end

      lines = []
      unless moved.empty?
        lines << "moved #{moved.size} #{moved.size == 1 ? "memory" : "memories"} saved from " \
                 "#{Paths.tilde(item.path)} into #{Paths.tilde(target)}: #{moved.join(", ")}"
      end
      lines << "kept in #{Paths.tilde(from)}: #{kept.join(", ")}" unless kept.empty?
      rest = Dir.children(from) - LEFTOVERS
      if rest.empty? && hand_written?(index_text(from))
        lines << "#{Paths.tilde(from)} keeps its index.md: it has lines written by hand"
      elsif rest.empty?
        FileUtils.rm_rf(from)
        lines << "removed the emptied #{Paths.tilde(from)}"
      else
        left = index_text(from)
        memory_files = entries(from).keys.flat_map do |name|
          ["#{name}.md"] + Tools::MemoryWrite.overlay_files(from, name, left).map { |path| File.basename(path) }
        end
        others = (rest - memory_files).sort
        lines << "#{Paths.tilde(from)} keeps files that aren't memories: #{others.join(", ")}" unless others.empty?
      end
      lines
    end

    # Whether an index holds a line that isn't the auto header, blank or a
    # managed line (memory_write keeps every other line byte for byte; a
    # dangling managed line, its file gone, may go with the folder).
    def hand_written?(text)
      header = MemoryBundle::IndexUpdater.auto_index_header.lines.map(&:strip)
      text.each_line.any? do |line|
        line = line.strip
        !(line.empty? || header.include?(line) || line.match?(/\A- \*\*[^*]+\*\*[ \t]*(?:[·•].*|:.*)?\z/))
      end
    end
    private_class_method :index_text, :merge_one, :hand_written?
  end
end
