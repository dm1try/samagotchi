# frozen_string_literal: true

require "samagotchi/memory_paths"
require "digest"
require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe Samagotchi::MemoryPaths do
  describe ".system_dir" do
    it "lives next to config.yml under XDG_CONFIG_HOME" do
      expect(described_class.system_dir(env: { "XDG_CONFIG_HOME" => "/xdg" })).to eq("/xdg/samagotchi/memories")
    end

    it "falls back to ~/.config when XDG_CONFIG_HOME is blank" do
      expect(described_class.system_dir(env: { "XDG_CONFIG_HOME" => " " }))
        .to eq(File.join(Dir.home, ".config", "samagotchi", "memories"))
    end

    it "reads ENV on every call, not once at load" do
      original = ENV["XDG_CONFIG_HOME"]
      ENV["XDG_CONFIG_HOME"] = "/first"
      first = described_class.system_dir
      ENV["XDG_CONFIG_HOME"] = "/second"
      expect([first, described_class.system_dir]).to eq(%w[/first/samagotchi/memories /second/samagotchi/memories])
    ensure
      ENV["XDG_CONFIG_HOME"] = original
    end
  end

  describe ".project_dir" do
    it "keys the folder by basename and MD5 of the project root" do
      Dir.mktmpdir do |tmp|
        root = File.realpath(tmp)
        key = "#{File.basename(root)}_#{Digest::MD5.hexdigest(root)[0..7]}"
        expect(described_class.project_dir(env: { "XDG_CONFIG_HOME" => "/xdg" }, cwd: root))
          .to eq("/xdg/samagotchi/memories/projects/#{key}")
      end
    end
  end

  describe ".project_root" do
    def git(*args)
      out, status = Open3.capture2e("git", "-c", "user.name=x", "-c", "user.email=x@x",
                                    "-c", "init.defaultBranch=main", *args)
      raise "git #{args.join(" ")} failed: #{out}" unless status.success?

      out
    end

    def repo_with_commit(dir)
      git("init", "-q", dir)
      git("-C", dir, "commit", "-q", "--allow-empty", "-m", "init")
    end

    around do |example|
      Dir.mktmpdir { |tmp| @tmp = tmp; example.run }
    end

    let(:real_tmp) { File.realpath(@tmp) }

    it "is the directory itself outside any git repository" do
      dir = File.join(@tmp, "plain")
      FileUtils.mkdir_p(dir)
      expect(described_class.project_root(dir)).to eq(dir)
      expect(described_class.project_key(dir)).to eq("plain_#{Digest::MD5.hexdigest(dir)[0..7]}")
    end

    it "is the checkout for the repo root and a nested subdirectory" do
      repo = File.join(real_tmp, "repo")
      git("init", "-q", repo)
      FileUtils.mkdir_p(File.join(repo, "lib", "deep"))

      expect(described_class.project_root(repo)).to eq(repo)
      expect(described_class.project_root(File.join(repo, "lib", "deep"))).to eq(repo)
      expect(described_class.project_key(File.join(repo, "lib", "deep"))).to eq(described_class.project_key(repo))
    end

    it "gives a linked worktree the main checkout's key, even through a symlinked tmp path" do
      # @tmp is not realpathed: on macOS it is /var/..., a symlink to /private/var/...,
      # while git writes the worktree's .git file with real paths.
      repo = File.join(@tmp, "repo")
      repo_with_commit(repo)
      tree = File.join(@tmp, "repo-feature")
      git("-C", repo, "worktree", "add", "-q", "-b", "feature", tree)

      expect(described_class.project_root(tree)).to eq(File.join(real_tmp, "repo"))
      expect(described_class.project_key(tree)).to eq(described_class.project_key(repo))
      expect(described_class.project_key(tree)).to start_with("repo_")
    end

    it "gives the git dir holding a folder's own HEAD: .git in the main checkout, the linked worktree's own, nil outside git" do
      repo = File.join(real_tmp, "repo")
      repo_with_commit(repo)
      tree = File.join(real_tmp, "repo-feature")
      git("-C", repo, "worktree", "add", "-q", "-b", "feature", tree)
      FileUtils.mkdir_p(File.join(tree, "lib"))
      FileUtils.mkdir_p(File.join(@tmp, "plain"))

      expect(described_class.git_dir(repo)).to eq(File.join(repo, ".git"))
      expect(described_class.git_dir(File.join(tree, "lib"))).to eq(File.join(repo, ".git", "worktrees", "repo-feature"))
      expect(described_class.git_dir(File.join(@tmp, "plain"))).to be_nil
    end

    it "keys a submodule-shaped .git file (no commondir) by that gitdir" do
      gitdir = File.join(real_tmp, "sup", ".git", "modules", "sub")
      FileUtils.mkdir_p(gitdir)
      sub = File.join(real_tmp, "sup", "sub")
      FileUtils.mkdir_p(sub)
      File.write(File.join(sub, ".git"), "gitdir: ../.git/modules/sub\n")

      expect(described_class.project_root(sub)).to eq(gitdir)
    end

    it "gives a ./.bare repo and its worktrees one key" do
      proj = File.join(real_tmp, "proj")
      bare = File.join(proj, ".bare")
      repo_with_commit(File.join(real_tmp, "src"))
      git("clone", "-q", "--bare", File.join(real_tmp, "src"), bare)
      File.write(File.join(proj, ".git"), "gitdir: ./.bare\n")
      git("-C", proj, "worktree", "add", "-q", File.join(proj, "main"), "main")

      expect(described_class.project_root(proj)).to eq(bare)
      expect(described_class.project_root(File.join(proj, "main"))).to eq(bare)
    end

    it "keys a worktree of a bare repository by the bare dir" do
      bare = File.join(real_tmp, "x.git")
      repo_with_commit(File.join(real_tmp, "src"))
      git("clone", "-q", "--bare", File.join(real_tmp, "src"), bare)
      tree = File.join(real_tmp, "x-main")
      git("-C", bare, "worktree", "add", "-q", tree, "main")

      expect(described_class.project_root(tree)).to eq(bare)
    end

    it "keys a malformed .git file by the directory holding it, without raising" do
      dir = File.join(real_tmp, "broken")
      FileUtils.mkdir_p(File.join(dir, "sub"))
      File.write(File.join(dir, ".git"), "not a gitdir line\n")

      expect(described_class.project_root(File.join(dir, "sub"))).to eq(dir)
    end
  end

  describe ".scope_dir" do
    let(:env) { { "XDG_CONFIG_HOME" => "/xdg" } }

    it "maps system (or no scope) to system_dir and project to project_dir; nil for anything else" do
      expect(%w[system project].push("", nil, " system", "other").map { |scope| described_class.scope_dir(scope, env: env, cwd: "/tmp") })
        .to eq(["/xdg/samagotchi/memories", described_class.project_dir(env: env, cwd: "/tmp"),
                "/xdg/samagotchi/memories", "/xdg/samagotchi/memories", nil, nil])
    end
  end

  describe ".scope_dir!" do
    let(:env) { { "XDG_CONFIG_HOME" => "/xdg" } }

    it "is scope_dir for a scope it knows" do
      expect(["system", "", "project"].map { |scope| described_class.scope_dir!(scope, env: env, cwd: "/tmp") })
        .to eq(["/xdg/samagotchi/memories", "/xdg/samagotchi/memories", described_class.project_dir(env: env, cwd: "/tmp")])
    end

    it "raises ArgumentError for any other scope" do
      expect { described_class.scope_dir!("team", env: env) }.to raise_error(ArgumentError, "invalid scope: team")
    end
  end

  describe ".bundles_dir" do
    it "sits inside the system memories dir" do
      expect(described_class.bundles_dir(env: { "XDG_CONFIG_HOME" => "/xdg" })).to eq("/xdg/samagotchi/memories/.bundles")
    end
  end
end
