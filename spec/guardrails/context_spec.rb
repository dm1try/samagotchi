# frozen_string_literal: true

require "tmpdir"
require "samagotchi/guardrails"
require "samagotchi/tools/builtins"

RSpec.describe Samagotchi::Guardrails::Context do
  around do |example|
    Dir.mktmpdir("guard-ctx") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  def git(*args) = system("git", "-C", @dir, *args, out: File::NULL, err: File::NULL)

  it "has no repo root or branch outside a repo" do
    ctx = described_class.new(cwd: @dir)
    expect(ctx.repo_root).to be_nil
    expect(ctx.branch).to be_nil
  end

  it "finds the repo root and branch, also from a subdirectory" do
    git("init", "-q", "-b", "trunk")
    git("-c", "user.email=a@b", "-c", "user.name=a", "commit", "-q", "--allow-empty", "-m", "x")
    sub = File.join(@dir, "a", "b").tap { |d| FileUtils.mkdir_p(d) }
    ctx = described_class.new(cwd: sub)
    expect([ctx.repo_root, ctx.branch]).to eq([@dir, "trunk"])
  end

  it "finds the root of a repo with no commits yet" do
    git("init", "-q")
    expect(described_class.new(cwd: @dir).repo_root).to eq(@dir)
  end

  describe "hooks_dir" do
    def commit = git("-c", "user.email=a@b", "-c", "user.name=a", "commit", "-q", "--allow-empty", "-m", "x")

    it "is the repo's .git/hooks, from a subdirectory too, and nil outside a repo" do
      expect(described_class.new(cwd: @dir).hooks_dir).to be_nil
      git("init", "-q")
      sub = File.join(@dir, "a").tap { |d| FileUtils.mkdir_p(d) }
      expect(described_class.new(cwd: sub).hooks_dir).to eq(File.join(@dir, ".git", "hooks"))
    end

    it "is the main checkout's hooks in a linked worktree (.git is a file there)" do
      git("init", "-q")
      commit
      worktree = File.join(@dir, "wt")
      git("worktree", "add", "-q", worktree)
      expect(described_class.new(cwd: worktree).hooks_dir).to eq(File.join(@dir, ".git", "hooks"))
    end

    it "follows core.hooksPath" do
      git("init", "-q")
      git("config", "core.hooksPath", "my-hooks")
      expect(described_class.new(cwd: @dir).hooks_dir).to eq(File.join(@dir, "my-hooks"))
    end
  end

  it "asks git once per directory" do
    gitinfo = Samagotchi::Guardrails::GitInfo.new
    allow(Open3).to receive(:capture2e).and_call_original
    ctx = described_class.new(cwd: @dir, git: gitinfo)
    3.times { ctx.repo_root; ctx.branch }
    expect(Open3).to have_received(:capture2e).at_most(2).times
  end

  it "defaults to non_interactive and lists its fields in to_h" do
    ctx = described_class.new(cwd: @dir, session_id: "s1", origin: { client_id: "web:1" })
    expect(ctx.to_h).to eq(cwd: @dir, repo_root: nil, branch: nil, session_id: "s1",
                           interface: :non_interactive, origin: { client_id: "web:1" })
  end
end

RSpec.describe Samagotchi::Guardrails::Targets do
  around do |example|
    Dir.mktmpdir("guard-tgt") do |dir|
      @dir = File.realpath(dir)
      system("git", "-C", @dir, "init", "-q", out: File::NULL, err: File::NULL)
      example.run
    end
  end

  let(:context) { Samagotchi::Guardrails::Context.new(cwd: @dir) }

  def targets(call) = described_class.for(call, context)

  it "takes execute's command and resolves a relative cwd against the context cwd" do
    FileUtils.mkdir_p(File.join(@dir, "sub"))
    t = targets(name: "execute", content: "git push", cwd: "sub")
    expect([t.command, t.cwd, t.repo_root, t.paths]).to eq(["git push", File.join(@dir, "sub"), @dir, []])
    expect(t).to be_shell
  end

  describe "a plugin tool: its entry's targets:" do
    let(:registry) do
      Samagotchi::Tools::Builtins.registry.tap do |r|
        r.register("save_note", schema: {}, handler: ->(*) { "" }, source: "notes",
                                targets: ->(call) { { "paths" => [call[:args]["path"]], cwd: call[:args]["cwd"] } })
        r.register("run_it", schema: {}, handler: ->(*) { "" }, source: "runner",
                             targets: ->(call) { { command: call[:args]["cmd"] } })
        r.register("broken", schema: {}, handler: ->(*) { "" }, source: "x", targets: ->(_) { raise "nope" })
        r.register("plain", schema: {}, handler: ->(*) { "" }, source: "x")
      end
    end

    def targets(call) = described_class.for(call, context, registry: registry)

    it "resolves its paths against its cwd, or the context's" do
      FileUtils.mkdir_p(File.join(@dir, "sub"))
      t = targets(name: "save_note", args: { "path" => "n.md" })
      expect([t.paths, t.cwd, t.command]).to eq([[File.join(@dir, "n.md")], @dir, nil])
      t = targets(name: "save_note", args: { "path" => "n.md", "cwd" => "sub" })
      expect([t.paths, t.cwd]).to eq([[File.join(@dir, "sub", "n.md")], File.join(@dir, "sub")])
      expect(targets(name: "save_note", args: { "path" => "/etc/x" })).to be_outside_repo
    end

    it "takes a command, which command rules match (it is not a shell tool)" do
      t = targets(name: "run_it", args: { "cmd" => "git push" })
      expect([t.command, t.paths]).to eq(["git push", []])
      expect(t).not_to be_shell
    end

    it "is nothing for a tool without targets:, one that raises, or no registry" do
      [targets(name: "plain", args: {}), targets(name: "broken", args: {}),
       described_class.for({ name: "save_note", args: { "path" => "n.md" } }, context)].each do |t|
        expect([t.command, t.paths, t.cwd]).to eq([nil, [], @dir])
      end
    end
  end

  it "treats task_create as a shell tool, defaulting the cwd to the context's" do
    t = targets(name: "task_create", content: "sleep 1")
    expect([t.command, t.cwd]).to eq(["sleep 1", @dir])
    expect(t).to be_shell
  end

  it "resolves write/edit paths and read's content path like the tools do" do
    expect(targets(name: "write", path: "a/b.txt", content: "x").paths).to eq([File.join(@dir, "a/b.txt")])
    expect(targets(name: "edit", path: "~/x.txt", content: "x").paths).to eq([File.expand_path("~/x.txt")])
    expect(targets(name: "read", content: "../up.txt").paths).to eq([File.expand_path("../up.txt", @dir)])
  end

  it "says whether a path leaves the repo" do
    expect(targets(name: "write", path: "in.txt")).not_to be_outside_repo
    expect(targets(name: "write", path: "../out.txt")).to be_outside_repo
    expect(targets(name: "write", path: "#{@dir}-sibling/x")).to be_outside_repo
  end

  it "doesn't count a memory's file as leaving the repo (write/edit there is what memory_write does)" do
    project = Samagotchi::Tools::MemoryRead.memories_dir("project")
    system = Samagotchi::Tools::MemoryRead.memories_dir("system")
    expect(targets(name: "edit", path: File.join(project, "skill_release.md"))).not_to be_outside_repo
    expect(targets(name: "write", path: File.join(system, "notes.qwen.md"))).not_to be_outside_repo
    [File.join(project, "index.md"), File.join(system, ".bundles", "x", "manifest.md"),
     File.join(system, "notes.txt"), File.join(File.dirname(system), "config.yml")].each do |path|
      expect(targets(name: "write", path: path)).to be_outside_repo, path
    end
  end

  it "uses the cwd as the boundary outside a repo" do
    Dir.mktmpdir("guard-norepo") do |plain|
      plain = File.realpath(plain)
      ctx = Samagotchi::Guardrails::Context.new(cwd: plain)
      expect(described_class.for({ name: "write", path: "x" }, ctx)).not_to be_outside_repo
      expect(described_class.for({ name: "write", path: "/etc/x" }, ctx)).to be_outside_repo
    end
  end

  it "resolves memory_write to the .md file it writes, and an overlay's with the model key" do
    dir = Samagotchi::Tools::MemoryRead.memories_dir("project")
    t = described_class.for({ name: "memory_write", path: "notes", scope: "project" }, context)
    expect(t.paths).to eq([File.expand_path("notes.md", dir)])
    t = described_class.for({ name: "memory_write", path: "notes", scope: "project", current_model_only: "true" },
                            context, model_key: "qwen")
    expect(t.paths).to eq([File.expand_path("notes.qwen.md", dir)])
  end

  it "has no paths for an invalid memory_write" do
    expect(targets(name: "memory_write", path: "x", scope: "bogus").paths).to eq([])
  end
end
