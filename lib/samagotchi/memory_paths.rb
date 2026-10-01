# frozen_string_literal: true

require "digest"
require_relative "config"

module Samagotchi
  # Where memories live: <config dir>/memories, i.e. $XDG_CONFIG_HOME/samagotchi/memories
  # or ~/.config/samagotchi/memories. Resolved on every call, like
  # ConfigFile.global_path, so an XDG_CONFIG_HOME set after load (specs, smoke runs,
  # a fixture chi) moves memories together with config.yml.
  #
  # Project memories are keyed by the project root (see project_root), so every
  # worktree and subdirectory of one git repository shares one folder.
  module MemoryPaths
    module_function

    def system_dir(env: ENV)
      File.join(ConfigFile.config_dir(env: env), "memories")
    end

    def projects_dir(env: ENV)
      File.join(system_dir(env: env), "projects")
    end

    # One folder per project root: basename + 8 hex chars of MD5(full root path).
    def project_key(cwd = Dir.pwd)
      root = project_root(cwd)
      "#{File.basename(root)}_#{Digest::MD5.hexdigest(root)[0..7]}"
    end

    # The repository's common git directory identifies the project; every linked
    # worktree shares it. Returns the checkout holding it when it is named .git,
    # otherwise the git dir itself (a bare repo, a proj/.bare layout,
    # --separate-git-dir, a submodule's .git/modules/<name>), so for those layouts
    # the "project root" is a git dir, not a checkout. Outside any repository the
    # root is cwd. No git subprocess: at most two small files are read.
    def project_root(cwd = Dir.pwd)
      dot_git = find_dot_git(cwd)
      return cwd unless dot_git

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

    # Is +cwd+ inside a git repository (a .git somewhere above it)?
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
    private_class_method :find_dot_git, :gitdir_from_file, :common_dir

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

    def bundles_dir(env: ENV)
      File.join(system_dir(env: env), ".bundles")
    end
  end
end
