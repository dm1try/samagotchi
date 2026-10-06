# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"
require "samagotchi/guardrails"
require "samagotchi/guardrail_wiring"
require "samagotchi/tools/memory"

RSpec.describe Samagotchi::Guardrails::ChildBoundary do
  # A tmp repository: main (the main checkout), with linked worktrees
  # child and sibling beside it.
  let(:base) { File.realpath(Dir.mktmpdir("child-boundary")) }
  let(:main) { File.join(base, "main") }
  let(:child) { File.join(base, "child") }
  let(:sibling) { File.join(base, "sibling") }
  let(:git) { Samagotchi::Guardrails::GitInfo.new }

  def sh(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(" ")}: #{out}" unless status.success?

    out
  end

  def init_repo(dir)
    FileUtils.mkdir_p(dir)
    sh(dir, "init", "-q", "-b", "main")
    File.write(File.join(dir, "a.txt"), "a\n")
    sh(dir, "add", ".")
    sh(dir, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init")
  end

  before do
    init_repo(main)
    sh(main, "worktree", "add", "-q", child, "-b", "feat")
    sh(main, "worktree", "add", "-q", sibling, "-b", "other")
  end

  after { FileUtils.rm_rf(base) }

  # The check as the wiring builds it, for a child whose folder is +root+.
  def boundary(root)
    Samagotchi::Guardrails::ChildBoundary.new(root: -> { git.root(root) || root }, worktrees: -> { git.worktrees(root) },
                                              common_dir: -> { git.common_dir(root) }, branch: -> { git.branch(root) })
  end

  # The verdict for +call+ in a child rooted at +root+, the process in +cwd+.
  def verdict_for(call = nil, root: child, cwd: root, **fields)
    call ||= fields
    context = Samagotchi::Guardrails::Context.new(cwd: cwd, git: git)
    v = Samagotchi::Guardrails::Verdict.new(call: call)
    v.context = context
    v.targets = Samagotchi::Guardrails::Targets.for(call, context)
    boundary(root).check(v)
  end

  def run(command, **opts) = verdict_for({ name: "execute", content: command }, **opts)

  describe "write and edit" do
    it "asks for the main checkout and a sibling, once or for the session, and not inside its folder" do
      v = verdict_for(name: "write", path: File.join(main, "a.txt"), content: "x")
      expect([v.decision, v.rule, v.source, v.decided_by, v.scopes]).to eq([:ask, "child-boundary", "core", "core", %w[once session]])
      expect(v.reason).to eq("a delegate child changes something outside its folder #{child}: ask the user")
      expect(verdict_for(name: "edit", path: "../sibling/a.txt", old_string: "a", new_string: "b")).to be_ask
      expect(verdict_for(name: "write", path: "lib/new.rb", content: "x")).to be_allow
      expect(verdict_for(name: "write", path: File.join(child, "a.txt"), content: "x")).to be_allow
    end

    it "leaves tmp dirs, memory files and reads alone" do
      expect(verdict_for(name: "write", path: "/tmp/child-boundary-x.txt", content: "x")).to be_allow
      memory = File.join(Samagotchi::Tools::MemoryRead.memories_dir("system"), "boundary-spec.md")
      expect(verdict_for(name: "write", path: memory, content: "x")).to be_allow
      expect(verdict_for(name: "read", content: File.join(main, "a.txt"))).to be_allow
    end

    it "takes the root from the child's folder while the process sits in the main checkout (cwd_gone)" do
      expect(verdict_for({ name: "write", path: File.join(main, "a.txt"), content: "x" }, cwd: main)).to be_ask
      expect(verdict_for({ name: "write", path: File.join(child, "a.txt"), content: "x" }, cwd: main)).to be_allow
    end

    it "still asks when the child's own worktree folder is gone" do
      FileUtils.rm_rf(child)
      expect(verdict_for({ name: "write", path: File.join(main, "a.txt"), content: "x" }, cwd: main)).to be_ask
      expect(run("make", cwd: main)).to be_ask
    end
  end

  describe "execute" do
    it "asks for mutating git in the main checkout, by -C or cd" do
      expect(run("git -C #{main} commit -am x")).to be_ask
      expect(run("cd ../main && git add .")).to be_ask
      expect(run("git -C ../sibling reset --hard")).to be_ask
      expect(run("git commit -am x")).to be_allow
    end

    it "doesn't ask for read-only git there" do
      expect(run("git -C #{main} log --oneline -3")).to be_allow
      expect(run("git -C ../main status")).to be_allow
      expect(run("git diff main...feat")).to be_allow
    end

    it "asks for a command that isn't read-only starting in the main checkout, not a read-only one" do
      expect(verdict_for({ name: "execute", content: "rake", cwd: main })).to be_ask
      expect(verdict_for({ name: "execute", content: "rake" }, cwd: child)).to be_allow
      expect(verdict_for({ name: "execute", content: "git status", cwd: main })).to be_allow
      expect(verdict_for({ name: "task_create", content: "bundle exec rspec", cwd: main })).to be_ask
    end

    it "asks when a command that isn't read-only names a path in another checkout" do
      expect(run("cp lib/x.rb ../main/lib/")).to be_ask
      expect(run("echo hi > #{sibling}/notes.txt")).to be_ask
      expect(run("cat ../main/a.txt")).to be_allow
      expect(run("cp a.txt b.txt")).to be_allow
      expect(run("cp a.txt /usr/local/share/elsewhere")).to be_allow
    end

    it "keeps a heredoc body naming the main checkout as data" do
      command = "cat > notes.md <<'EOF'\ncp x #{main}/y\nEOF"
      expect(run(command)).to be_allow
    end

    it "treats a worktree nested in the main checkout as inside its own folder" do
      nested = File.join(main, ".worktrees", "x")
      sh(main, "worktree", "add", "-q", nested, "-b", "nested")
      expect(run("touch lib/y.rb", root: nested)).to be_allow
      expect(run("touch #{nested}/y.rb", root: nested)).to be_allow
      expect(run("touch #{main}/y.rb", root: nested)).to be_ask
      expect(verdict_for({ name: "write", path: File.join(main, "y.rb"), content: "x" }, root: nested)).to be_ask
    end

    describe "git that changes what every checkout shares, run in its own worktree" do
      it "asks for a config write, not a read or a --worktree one" do
        v = run("git config core.hooksPath #{child}/h")
        expect([v.decision, v.rule, v.scopes]).to eq([:ask, "child-boundary", %w[once session]])
        expect(v.reason).to eq("a delegate child changes git state every checkout of the repository shares, from its folder #{child}: ask the user")
        expect(run("git config --unset core.hooksPath")).to be_ask
        expect(run("git config set user.name x")).to be_ask
        expect(run("git config --global user.name x")).to be_ask
        expect(run("git config core.hooksPath")).to be_allow
        expect(run("git config --get core.hooksPath")).to be_allow
        expect(run("git config --list")).to be_allow
        expect(run("git config -l")).to be_allow
        expect(run("git config get user.name")).to be_allow
        expect(run("git config --worktree core.hooksPath h")).to be_allow
      end

      it "asks for update-ref, worktree changes and stash drop/clear/pop" do
        expect(run("git update-ref refs/heads/main HEAD")).to be_ask
        expect(run("git worktree add -f ../evil main")).to be_ask
        expect(run("git worktree remove ../sibling")).to be_ask
        expect(run("git worktree prune")).to be_ask
        expect(run("git worktree list")).to be_allow
        expect(run("git stash clear")).to be_ask
        expect(run("git stash drop")).to be_ask
        expect(run("git stash pop")).to be_ask
        expect(run("git stash list")).to be_allow
        expect(run("git stash")).to be_allow
      end

      it "asks for creating or deleting a tag, not listing them" do
        expect(run("git tag v1")).to be_ask
        expect(run("git tag -d v1")).to be_ask
        expect(run("git tag -a v1 -m release")).to be_ask
        expect(run("git tag")).to be_allow
        expect(run("git tag -l 'v*'")).to be_allow
      end

      it "asks for deleting, forcing or overwriting another branch, not its own" do
        expect(run("git branch -D main")).to be_ask
        expect(run("git branch -d other")).to be_ask
        expect(run("git branch -f main HEAD")).to be_ask
        expect(run("git branch -M main")).to be_ask
        expect(run("git branch -m other renamed")).to be_ask
        expect(run("git branch -m feat-renamed")).to be_allow
        expect(run("git branch -f feat HEAD~1")).to be_allow
        expect(run("git branch new-one")).to be_allow
        expect(run("git branch --show-current")).to be_allow
      end

      it "asks for any of them when its own branch is unknown" do
        unknown = described_class.new(root: -> { child }, branch: -> {})
        v = Samagotchi::Guardrails::Verdict.new(call: { name: "execute", content: "git branch -f feat HEAD~1" })
        v.context = Samagotchi::Guardrails::Context.new(cwd: child, git: git)
        v.targets = Samagotchi::Guardrails::Targets.for(v.call, v.context)
        expect(unknown.check(v)).to be_ask
      end

      it "doesn't look into a heredoc body" do
        expect(run("cat > notes.md <<'EOF'\ngit config core.hooksPath h\nEOF")).to be_allow
      end
    end

    it "never asks about other tools" do
      expect(verdict_for(name: "memory_write", path: "x", scope: "system", content: "x")).to be_allow
    end
  end

  describe "with the guardrails bundle's strict rules" do
    let(:rules) do
      parsed = Samagotchi::Guardrails::Rules.parse(
        [{ "id" => "git-outside-repo", "tool" => "shell", "git" => "outside_repo", "modes" => ["strict"],
           "verdict" => "ask", "scopes" => %w[once session rule], "reason" => "outside" }], source: "bundle guardrails"
      )
      Samagotchi::Guardrails::Rules.new(parsed, mode: "strict")
    end

    it "keeps the child-boundary rule and its once/session scopes" do
      v = run("git -C #{main} commit -am x")
      rules.check(v)
      expect([v.rule, v.source, v.scopes]).to eq(["child-boundary", "core", %w[once session]])
    end
  end

  describe "GitInfo#worktrees" do
    it "lists the main checkout and the linked worktrees from the files, from any of them" do
      expect(git.worktrees(child)).to eq([main, child, sibling])
      expect(Samagotchi::Guardrails::GitInfo.new.worktrees(main)).to eq([main, child, sibling])
      expect(git.worktrees(base)).to eq([])
    end

    it "sees a worktree added after the first look, in the same turn" do
      expect(git.worktrees(child)).to eq([main, child, sibling])
      late = File.join(base, "late")
      sh(main, "worktree", "add", "-q", late, "-b", "late")
      expect(git.worktrees(child)).to eq([main, child, sibling, late].sort_by { |d| d == main ? "" : File.basename(d) })
      expect(run("cp a.txt #{late}/")).to be_ask
    end

    it "leaves out a worktree whose folder is gone and reads a relative gitdir" do
      FileUtils.rm_rf(sibling)
      admin = File.join(main, ".git", "worktrees", "child")
      File.write(File.join(admin, "gitdir"), "../../../../child/.git\n")
      expect(Samagotchi::Guardrails::GitInfo.checkouts(File.join(main, ".git"))).to eq([main, child])
    end

    it "has no main checkout in a bare layout" do
      bare = File.join(base, "proj", ".bare")
      sh(base, "clone", "-q", "--bare", main, bare)
      linked = File.join(base, "proj", "wt")
      sh(bare, "worktree", "add", "-q", linked, "-b", "x")
      expect(git.worktrees(linked)).to eq([linked])
      expect(run("echo x > ../.bare/config", root: linked)).to be_ask
      expect(run("cp hook ../.bare/hooks/post-merge", root: linked)).to be_ask
      expect(run("cat ../.bare/config", root: linked)).to be_allow
      expect(verdict_for({ name: "write", path: File.join(main, "a.txt"), content: "x" }, root: linked)).to be_ask
    end
  end
end

RSpec.describe "GuardrailWiring: the child boundary" do
  let(:dir) { File.realpath(Dir.mktmpdir("child-boundary-wiring")) }
  let(:session) { nil }
  let(:wiring) do
    s = session
    Samagotchi::GuardrailWiring.new(scratch: false, hooks: -> {}, tools: -> {}, session: -> { s }, model_key: -> {},
                                    cancelled: -> { false }, ask: ->(_) {}).tap { |w| w.state_dir = File.join(dir, "sessions") }
  end

  after { FileUtils.rm_rf(dir) }

  def new_session(**opts)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: dir, **opts)
  end

  def boundary? = wiring.checks.any?(Samagotchi::Guardrails::ChildBoundary)

  context "in a delegate child" do
    let(:session) { new_session(parent_id: "p", delegate: true) }

    it "gets the check, before the rules" do
      checks = wiring.checks
      expect(checks.index { |c| c.is_a?(Samagotchi::Guardrails::ChildBoundary) })
        .to be < checks.index { |c| c.is_a?(Samagotchi::Guardrails::Rules) }
    end

    it "keeps it with guardrails.enabled: false, and asks about a write outside its folder" do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("guardrails.enabled").and_return(false)
      expect(wiring.rules.enabled?).to be(false)
      v = Samagotchi::Guardrails::Verdict.new(call: { name: "write", path: "/elsewhere/x.rb", content: "x" })
      v.context = wiring.context
      v.targets = Samagotchi::Guardrails::Targets.for(v.call, v.context)
      wiring.checks.each { |c| c.check(v) }
      expect([v.decision, v.rule]).to eq([:ask, "child-boundary"])
    end
  end

  context "in a plain session" do
    let(:session) { new_session }

    it("doesn't get it") { expect(boundary?).to be(false) }

    it "lets a parent's own flows through: an ff-only merge, a worktree removal, a write in a child's worktree" do
      calls = [{ name: "execute", content: "git merge --ff-only feat" },
               { name: "execute", content: "git worktree remove ../child && git branch -d feat" },
               { name: "execute", content: "git -C ../child log --oneline main..feat" },
               { name: "write", path: "/elsewhere/child/x.rb", content: "x" }]
      calls.each do |call|
        v = Samagotchi::Guardrails::Verdict.new(call: call)
        v.context = wiring.context
        v.targets = Samagotchi::Guardrails::Targets.for(call, v.context)
        wiring.checks.each { |c| c.check(v) }
        expect(v.rule).not_to eq("child-boundary")
      end
    end
  end

  context "in a fork (a parent, not a delegate)" do
    let(:session) { new_session(parent_id: "p") }

    it("doesn't get it") { expect(boundary?).to be(false) }
  end
end
