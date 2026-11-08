# frozen_string_literal: true

require "digest"
require_relative "config"
require_relative "guardrails/path_resolve"

module Samagotchi
  # Where memories live: <config dir>/memories, i.e. $XDG_CONFIG_HOME/samagotchi/memories
  # or ~/.config/samagotchi/memories. Resolved on every call, like
  # ConfigFile.global_path, so an XDG_CONFIG_HOME set after load (specs, smoke runs,
  # a fixture chi) moves memories together with config.yml.
  #
  # Project memories are keyed by the project root (see #lookup): one folder
  # per project root, a git repository (every worktree and subdirectory of it
  # shares one folder) or a folder marked by `chi project init` (and its
  # subfolders).
  module MemoryPaths
    # The file that makes a folder in no git repository a chi project
    # (`chi project init`). The file, not the bare .chi/ dir, is the marker.
    MARKER = File.join(".chi", "project.yml").freeze

    # How a folder's project was found (#lookup): +kind+ is :git, :marker or
    # :none; +root+ is what memories are keyed on (#project_root: git's
    # common-dir checkout, the marked folder's realpath, or the folder
    # itself); +top+ is the folder a session reads its AGENTS.md chain from
    # (the work tree's top, the marked root; nil for :none).
    ProjectLookup = Data.define(:kind, :root, :top) do
      def project? = kind != :none
      def git? = kind == :git
      def marker? = kind == :marker
    end

    module_function

    # The project +cwd+ belongs to, looked up once: a .git above it wins
    # (git is the identity wherever it exists); only when there is none, the
    # nearest MARKER above it, ignoring one in $HOME or any folder above it
    # (and /), so a marker in ~ never makes every folder under home one
    # project. The marker walk starts from +cwd+'s real path and the marked
    # root is a realpath, as git's root is, so every spelling of a folder
    # (/tmp, /var on macOS, a symlink into or out of a marked tree) gets the
    # answer the worker's physical Dir.pwd gets.
    # @param home [String, nil] $HOME by default; nil or blank ignores only /
    # @return [ProjectLookup]
    def lookup(cwd = Dir.pwd, home: default_home)
      dot_git = find_dot_git(cwd)
      return ProjectLookup.new(kind: :git, root: git_root(dot_git), top: File.dirname(dot_git)) if dot_git

      marked = nearest_marker(cwd, home: home)
      return ProjectLookup.new(kind: :marker, root: marked, top: marked) if marked

      ProjectLookup.new(kind: :none, root: cwd, top: nil)
    end

    # Whether a marker at +dir+ is ignored: +dir+ is / or holds $HOME (both
    # resolved; Guardrails::PathResolve.home_root?).
    def above_home?(dir, home: default_home)
      Guardrails::PathResolve.real(dir) == "/" || Guardrails::PathResolve.home_root?(dir, home)
    end

    # $HOME, or nil when it can't be found (no HOME, no passwd entry).
    def default_home
      Dir.home
    rescue ArgumentError
      nil
    end

    def system_dir(env: ENV)
      File.join(ConfigFile.config_dir(env: env), "memories")
    end

    def projects_dir(env: ENV)
      File.join(system_dir(env: env), "projects")
    end

    # One folder per project root: basename + 8 hex chars of MD5(full root path).
    def project_key(cwd = Dir.pwd) = key_for_root(project_root(cwd))

    # #project_key for a root already resolved (a session's project_root).
    def key_for_root(root) = "#{File.basename(root)}_#{Digest::MD5.hexdigest(root)[0..7]}"

    # The project root (#lookup): in a repository, its common git directory
    # identifies the project; every linked worktree shares it. Returns the
    # checkout holding it when it is named .git, otherwise the git dir itself
    # (a bare repo, a proj/.bare layout, --separate-git-dir, a submodule's
    # .git/modules/<name>), so for those layouts the "project root" is a git
    # dir, not a checkout. Outside any repository, the marked folder holding
    # +cwd+, else cwd. No git subprocess: at most two small files are read.
    def project_root(cwd = Dir.pwd) = lookup(cwd).root

    # Is +cwd+ in a project: a git repository or a marked folder?
    def in_project?(cwd = Dir.pwd) = lookup(cwd).project?

    # The marked folder (realpath) +cwd+'s project is, or nil (in a git
    # repository, or in no project).
    def marked_root(cwd = Dir.pwd)
      found = lookup(cwd)
      found.marker? ? found.root : nil
    end

    # The top of +cwd+'s project: the git work tree's top (#work_tree_root) or
    # the marked root; nil in no project.
    def project_top(cwd = Dir.pwd) = lookup(cwd).top

    # The project root of the checkout whose .git is +dot_git+ (#project_root).
    def git_root(dot_git)
      holder = File.dirname(dot_git)
      gitdir = File.directory?(dot_git) ? dot_git : gitdir_from_file(dot_git)
      return holder unless gitdir

      common = common_dir(gitdir)
      common = begin
        File.realpath(common)
      rescue SystemCallError
        common
      end
      File.basename(common) == ".git" ? File.dirname(common) : common
    end

    # The repository's common git dir of +cwd+ as an absolute real path (the
    # same for every worktree of it), or nil outside any repository. Reads
    # files only, no git process; #project_root turns it into a checkout
    # folder, which a bare layout's container is not.
    def common_git_dir(cwd = Dir.pwd)
      gitdir = git_dir(cwd)
      gitdir && File.realpath(common_dir(gitdir))
    end

    # The top of the git work tree holding +cwd+: the directory with the
    # nearest .git (a linked worktree's own checkout, unlike #project_root);
    # nil outside any repository.
    def work_tree_root(cwd = Dir.pwd)
      dot_git = find_dot_git(cwd)
      dot_git && File.dirname(dot_git)
    end

    # The git dir of the work tree holding +cwd+: .git itself in a main
    # checkout, the worktree's own dir under .git/worktrees in a linked one
    # (where HEAD is that worktree's); nil outside any repository.
    def git_dir(cwd = Dir.pwd)
      dot_git = find_dot_git(cwd)
      return nil unless dot_git

      File.directory?(dot_git) ? dot_git : gitdir_from_file(dot_git)
    end

    # Is +cwd+ inside a git repository (a .git somewhere above it)? Git only:
    # a marked folder is not a repository (#in_project?).
    def in_repo?(cwd = Dir.pwd)
      !find_dot_git(cwd).nil?
    end

    def find_dot_git(start)
      dir = File.expand_path(start)
      loop do
        candidate = File.join(dir, ".git")
        return candidate if File.exist?(candidate)

        parent = File.dirname(dir)
        return nil if parent == dir

        dir = parent
      end
    end

    # The realpath of the nearest folder at or above +start+ holding MARKER,
    # git or not (#lookup asks only outside a repository; `chi project` tells
    # of one a repository makes ignored), or nil. A marker at or above +home+
    # (#above_home?) ends the walk with nil: every folder above it is above
    # home too.
    def nearest_marker(start, home: default_home)
      dir = Guardrails::PathResolve.real(start)
      loop do
        if File.file?(File.join(dir, MARKER))
          return nil if above_home?(dir, home: home)

          return File.realpath(dir)
        end
        parent = File.dirname(dir)
        return nil if parent == dir

        dir = parent
      end
    rescue SystemCallError
      nil
    end

    # A ".git" file holds "gitdir: <path>", relative to the file's directory.
    def gitdir_from_file(path)
      line = File.read(path, 4096).to_s[/\Agitdir:\s*(.+)$/, 1]&.strip
      return nil if line.nil? || line.empty?

      File.expand_path(line, File.dirname(path))
    rescue SystemCallError, ArgumentError
      nil
    end

    def common_dir(gitdir)
      file = File.join(gitdir, "commondir")
      return gitdir unless File.file?(file)

      rel = File.read(file).strip
      rel.empty? ? gitdir : File.expand_path(rel, gitdir)
    rescue SystemCallError
      gitdir
    end
    private_class_method :find_dot_git, :git_root, :gitdir_from_file, :common_dir

    def project_dir(env: ENV, cwd: Dir.pwd)
      File.join(projects_dir(env: env), project_key(cwd))
    end

    # The folder of a memory scope: "system" (or blank) or "project"; nil for
    # anything else. Every scope→folder lookup (bundle install/uninstall/build/
    # status, index.md updates, the memory tools) resolves here.
    def scope_dir(scope, env: ENV, cwd: Dir.pwd)
      case scope.to_s
      when "system", "" then system_dir(env: env)
      when "project" then project_dir(env: env, cwd: cwd)
      end
    end

    # scope_dir, or ArgumentError ("invalid scope: team") for a scope it
    # doesn't know: for a caller that must not guess a folder.
    def scope_dir!(scope, env: ENV, cwd: Dir.pwd)
      scope_dir(scope, env: env, cwd: cwd) or raise ArgumentError, "invalid scope: #{scope}"
    end

    def bundles_dir(env: ENV)
      File.join(system_dir(env: env), ".bundles")
    end
  end
end
