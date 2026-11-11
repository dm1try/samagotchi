# frozen_string_literal: true

require "samagotchi/turn_context"
require "yaml"

require "tmpdir"
require "samagotchi/guardrails"
require "samagotchi/hooks"
require "samagotchi/session"
require "samagotchi/tools/registry"

RSpec.describe Samagotchi::Guardrails::Approvals do
  let(:state) { Dir.mktmpdir("guard-store") }
  let(:warnings) { [] }
  let(:store) { described_class.new(dir: File.join(state, "guardrails"), warn: ->(m) { warnings << m }) }
  let(:repo) { File.join(state, "repo").tap { |d| FileUtils.mkdir_p(d) } }
  let(:other_repo) { File.join(state, "other").tap { |d| FileUtils.mkdir_p(d) } }

  after { FileUtils.rm_rf(state) }

  def ask(command: "git push  origin main", cwd: repo, session: "s1", rule: "git-push", source: "config", tool: "execute", env: nil)
    call = { name: tool, content: command }
    call[:env] = env if env
    ctx = Samagotchi::Guardrails::Context.new(cwd: cwd, session_id: session)
    v = Samagotchi::Guardrails::Verdict.new(call: call).ask!("pushes", rule: rule, source: source)
    v.context = ctx
    v.targets = Samagotchi::Guardrails::Targets.for(call, ctx)
    v
  end

  it "lives beside the sessions dir, not in it" do
    expect(described_class.dir_for("/s/samagotchi/sessions")).to eq("/s/samagotchi/guardrails")
    expect(described_class.dir_for(Samagotchi::Session.default_state_dir))
      .to eq(File.join(ENV["XDG_STATE_HOME"], "samagotchi", "guardrails"))
  end

  it "never stores once" do
    expect(store.add(ask, "once")).to be_nil
    expect(store.entries).to eq([])
  end

  it "matches a session entry only in that session, for the same (normalized) call" do
    store.add(ask, "session")
    expect(store.match(ask(command: "git push origin   main"))).to include("scope" => "session")
    expect(store.match(ask(session: "s2"))).to be_nil
    expect(store.match(ask(command: "git push origin other"))).to be_nil
  end

  # The same command text acts on whatever its folder and env: point at.
  it "keeps a session entry of a command to the folder it was given in" do
    store.add(ask, "session")
    expect(store.entries.first).to include("scope" => "session", "repo_root" => repo)
    expect(store.match(ask)).to include("scope" => "session")
    expect(store.match(ask(cwd: other_repo))).to be_nil
  end

  it "keys a session entry of a command by a digest of its env:, never the env itself" do
    env = { "GIT_DIR" => "/elsewhere/.git", "TOKEN" => "s3cret" }
    entry = store.add(ask(env: env), "session")
    expect(entry["env"]).to match(/\A[0-9a-f]{64}\z/)
    expect(File.read(store.path)).not_to include("s3cret", "/elsewhere/.git")
    expect(store.match(ask(env: env.to_a.reverse.to_h))).to include("scope" => "session")
    expect(store.match(ask)).to be_nil
    expect(store.match(ask(env: { "GIT_DIR" => "/other/.git" }))).to be_nil

    store.revoke(0)
    store.add(ask, "session")
    expect(store.entries.first).not_to have_key("env")
    expect(store.match(ask(env: env))).to be_nil
  end

  it "no longer matches a session entry of a command from before the folder was kept (one more ask)" do
    old = { "scope" => "session", "tool" => "execute", "session_id" => "s1", "key" => "execute:git push origin main" }
    expect(described_class.find_in([old], ask)).to be_nil
  end

  it "keeps a session entry of a file tool's call as it was: its paths are its place" do
    v = ask(tool: "write", command: nil)
    v.targets = Samagotchi::Guardrails::Targets.for({ name: "write", path: "a.txt" }, v.context)
    store.add(v, "session")
    expect(store.entries.first.keys).not_to include("repo_root", "env")
    expect(store.match(v)).to include("scope" => "session")
  end

  it "matches a repo entry in that repo (the cwd outside one) from any session" do
    store.add(ask, "repo")
    expect(store.match(ask(session: "s9"))).to include("scope" => "repo", "repo_root" => repo)
    expect(store.match(ask(cwd: other_repo))).to be_nil
  end

  it "lets a child-boundary ask through only on a session entry, not a repo or rule one" do
    store.add(ask, "repo")
    store.add(ask(rule: "child-boundary", source: "core", session: "s0"), "rule")
    expect(store.match(ask(rule: "child-boundary", source: "core"))).to be_nil
    store.add(ask(rule: "git-push"), "session")
    expect(store.match(ask(rule: "child-boundary", source: "core"))).to include("scope" => "session")
    expect(store.match(ask(rule: "child-boundary", source: "core", session: "s2"))).to be_nil
  end

  it "matches a rule entry for any call that rule asks about in the repo, from the same source" do
    store.add(ask, "rule")
    expect(store.match(ask(command: "git push --force"))).to include("scope" => "rule", "rule" => "git-push")
    expect(store.match(ask(command: "git push", source: "bundle guardrails"))).to be_nil
    expect(store.match(ask(cwd: other_repo))).to be_nil
    expect(store.match(ask(rule: nil))).to be_nil
  end

  describe "in a git repository with worktrees" do
    let(:main) { File.realpath(File.join(state, "main").tap { |d| FileUtils.mkdir_p(d) }) }
    let(:wt1) { File.join(File.realpath(state), "wt1") }
    let(:wt2) { File.join(File.realpath(state), "wt2") }
    let(:elsewhere) { File.realpath(File.join(state, "elsewhere").tap { |d| FileUtils.mkdir_p(d) }) }

    def git(dir, *args) = system("git", "-C", dir, *args, out: File::NULL, err: File::NULL)

    before do
      [main, elsewhere].each do |dir|
        git(dir, "init", "-q")
        git(dir, "-c", "user.email=a@b", "-c", "user.name=a", "commit", "-q", "--allow-empty", "-m", "x")
      end
      git(main, "worktree", "add", "-q", "-b", "one", wt1)
      git(main, "worktree", "add", "-q", "-b", "two", wt2)
    end

    it "keeps a repo or rule approval from one worktree for the others, not for another repo" do
      %w[repo rule].each do |scope|
        store.add(ask(cwd: wt1), scope)
        expect(store.match(ask(cwd: wt2, session: "s2"))).to include("scope" => scope), scope
        expect(store.match(ask(cwd: main, session: "s3"))).to include("scope" => scope), scope
        expect(store.match(ask(cwd: elsewhere))).to be_nil
        store.revoke(0)
      end
    end

    # A session entry is the worktree's, not the repository's: another
    # checkout of it is another place for the same command.
    it "keeps a session approval of a command to its worktree, not the repository's others" do
      store.add(ask(cwd: wt1), "session")
      expect(store.match(ask(cwd: wt1))).to include("scope" => "session", "repo_root" => wt1)
      expect(store.match(ask(cwd: wt2))).to be_nil
      expect(store.match(ask(cwd: main))).to be_nil
    end

    it "stores the repository and the worktree it was given in" do
      store.add(ask(cwd: wt1), "repo")
      expect(store.entries.first).to include("repo" => File.join(main, ".git"), "repo_root" => wt1)
    end

    it "still matches an entry from before repo: by its exact folder" do
      old = { "scope" => "rule", "tool" => "execute", "rule" => "git-push", "source" => "config", "repo_root" => wt1 }
      expect(described_class.find_in([old], ask(cwd: wt1))).to eq(old)
      expect(described_class.find_in([old], ask(cwd: wt2))).to be_nil
    end
  end

  it "keys file tools by their paths" do
    v = ask(tool: "write", command: nil)
    v.targets = Samagotchi::Guardrails::Targets.for({ name: "write", path: "a.txt" }, v.context)
    store.add(v, "repo")
    expect(store.entries.first["key"]).to eq("write:#{repo}/a.txt")
  end

  it "keys a plugin tool with no targets (an MCP tool) by its arguments, and chi's own tools as before" do
    registry = Samagotchi::Tools::Registry.new
    registry.register("mcp_x_sum", schema: { name: "mcp_x_sum" }, handler: ->(*) { "" }, source: "mcp")
    ctx = Samagotchi::Guardrails::Context.new(cwd: repo, session_id: "s1")
    verdict = lambda do |call, reg = registry|
      v = Samagotchi::Guardrails::Verdict.new(call: call).ask!("mcp", rule: "mcp-ask", source: "config")
      v.context = ctx
      v.targets = Samagotchi::Guardrails::Targets.for(call, ctx, registry: reg)
      v
    end
    store.add(verdict.call({ name: "mcp_x_sum", args: { "b" => 22, "a" => 20 } }), "session")
    expect(store.entries.first["key"]).to eq("mcp_x_sum:a=20 b=22")
    expect(store.match(verdict.call({ name: "mcp_x_sum", args: { "a" => 20, "b" => 22 } }))).not_to be_nil
    expect(store.match(verdict.call({ name: "mcp_x_sum", args: { "a" => 1, "b" => 2 } }))).to be_nil
    web = verdict.call({ name: "web_fetch", content: "https://x", args: { "url" => "https://x" } })
    expect(described_class.key_for(web)).to eq("web_fetch:")
  end

  it "keys a call that acts as another tool by its real name, the alias and the inner args, and stores acts_as" do
    registry = Samagotchi::Tools::Registry.new
    registry.register("call_tool", schema: { name: "call_tool" }, handler: ->(*) { "" }, source: "mcp",
                                  targets: lambda { |call|
                                    { acts_as: call[:args]["tool"], args: call[:args]["args"], label: call[:args]["label"] }
                                  })
    registry.register("mcp_github_x", schema: { name: "mcp_github_x" }, handler: ->(*) { "" }, source: "mcp")
    ctx = Samagotchi::Guardrails::Context.new(cwd: repo, session_id: "s1")
    verdict = lambda do |call|
      v = Samagotchi::Guardrails::Verdict.new(call: call).ask!("mcp", rule: "mcp-ask", source: "config")
      v.context = ctx
      v.targets = Samagotchi::Guardrails::Targets.for(call, ctx, registry: registry)
      v
    end
    via = ->(args) { verdict.call({ name: "call_tool", args: { "tool" => "mcp_github_x", "args" => args } }) }
    entry = store.add(via.call({ "b" => 2, "a" => 1 }), "session")
    expect(entry).to include("tool" => "call_tool", "acts_as" => "mcp_github_x", "key" => "call_tool>mcp_github_x:a=1 b=2")
    expect(store.match(via.call({ "a" => 1, "b" => 2 }))).not_to be_nil
    expect(store.match(via.call({ "a" => 9 }))).to be_nil
    # label: is display only: it doesn't change the key.
    labelled = verdict.call({ name: "call_tool", args: { "tool" => "mcp_github_x", "args" => { "a" => 1, "b" => 2 },
                                                         "label" => "github: x" } })
    expect(described_class.key_for(labelled)).to eq("call_tool>mcp_github_x:a=1 b=2")
    # The tool's own approval and the alias's don't stand in for each other.
    expect(store.match(verdict.call({ name: "mcp_github_x", args: { "a" => 1, "b" => 2 } }))).to be_nil
    store.add(verdict.call({ name: "mcp_github_x", args: { "a" => 5 } }), "session")
    expect(store.entries.last).not_to have_key("acts_as")
    expect(store.match(via.call({ "a" => 5 }))).to be_nil
  end

  it "stores an entry once, and revokes by index" do
    2.times { store.add(ask, "repo") }
    store.add(ask, "session")
    expect(store.entries.map { |e| e["scope"] }).to eq(%w[repo session])
    expect(store.revoke(0)).to include("scope" => "repo")
    expect(store.entries.map { |e| e["scope"] }).to eq(%w[session])
    expect(store.revoke(5)).to be_nil
  end

  it "keeps every entry from concurrent writers (processes)" do
    store && repo # memoized before the forks share them
    pids = Array.new(4) do |i|
      fork do
        s = described_class.new(dir: File.join(state, "guardrails"))
        5.times { |j| s.add(ask(command: "cmd #{i}-#{j}"), "repo") }
        exit!(0)
      end
    end
    pids.each { |pid| Process.wait(pid) }
    expect(store.entries.size).to eq(20)
  end

  it "moves a corrupt file aside, with one warning, and starts empty" do
    FileUtils.mkdir_p(File.join(state, "guardrails"))
    File.write(store.path, "{not json")
    expect(store.match(ask)).to be_nil
    expect(store.entries).to eq([])
    expect(warnings.size).to eq(1)
    expect(warnings.first).to include("unreadable")

    aside = Dir[File.join(state, "guardrails", "approvals.json.corrupt-*")]
    expect(aside.size).to eq(1)
    expect(File.basename(aside.first)).to match(/\Aapprovals\.json\.corrupt-\d{8}T\d{6}Z\z/)
    expect(File.read(aside.first)).to eq("{not json")
    expect(warnings.first).to include(aside.first)
  end

  it "keeps both corrupt files set aside within the same second" do
    allow(Time).to receive(:now).and_return(Time.utc(2026, 9, 25, 3, 0, 0))
    FileUtils.mkdir_p(File.join(state, "guardrails"))
    File.write(store.path, "{first")
    store.entries
    File.write(store.path, "{second")
    store.entries

    aside = Dir[File.join(state, "guardrails", "approvals.json.corrupt-*")].sort
    expect(aside.map { |f| File.basename(f) })
      .to eq(%w[approvals.json.corrupt-20260925T030000Z approvals.json.corrupt-20260925T030000Z-2])
    expect(aside.map { |f| File.read(f) }).to eq(["{first", "{second"])
  end

  it "keeps the corrupt file when a new approval is stored" do
    FileUtils.mkdir_p(File.join(state, "guardrails"))
    File.write(store.path, "[1,")
    store.add(ask, "repo")
    expect(store.entries.size).to eq(1)
    aside = Dir[File.join(state, "guardrails", "approvals.json.corrupt-*")]
    expect(aside.map { |f| File.read(f) }).to eq(["[1,"])
    expect(warnings.size).to eq(1)
  end

  describe "the store's shape" do
    let(:entry) do
      { "scope" => "session", "tool" => "execute", "rule" => "git-push", "source" => "config", "session_id" => "s1",
        "key" => "execute:git push origin main", "repo_root" => repo }
    end

    def write_store(data)
      FileUtils.mkdir_p(File.dirname(store.path))
      File.write(store.path, JSON.generate(data))
    end

    def stored = JSON.parse(File.read(store.path))

    it "reads a versioned store and matches its entries" do
      write_store("version" => 1, "approvals" => [entry])
      expect(store.entries).to eq([entry])
      expect(store.match(ask)).to include("scope" => "session")
      expect(warnings).to be_empty
    end

    it "reads approvals from an unversioned object" do
      approval = entry.merge("scope" => "once")
      write_store("approvals" => [approval])
      expect(store.entries).to eq([approval])
      expect(warnings).to be_empty
    end

    it "keeps a versioned store versioned through #add, with its version and the keys it doesn't know" do
      write_store("version" => 2, "approvals" => [entry], "later" => { "a" => 1 })
      store.add(ask(command: "git push origin other"), "session")
      expect(stored).to include("version" => 2, "later" => { "a" => 1 })
      expect(stored["approvals"].map { |e| e["key"] }).to eq(["execute:git push origin main", "execute:git push origin other"])
      expect(warnings).to be_empty
    end

    it "keeps a versioned store versioned through #revoke" do
      write_store("version" => 1, "approvals" => [entry, entry.merge("session_id" => "s2")])
      expect(store.revoke(0)).to include("session_id" => "s1")
      expect(stored).to include("version" => 1)
      expect(stored["approvals"].map { |e| e["session_id"] }).to eq(%w[s2])
    end

    it "keeps an entry it can't read (no scope) through a write, matching nothing" do
      odd = { "tool" => "execute", "later" => true }
      write_store("version" => 1, "approvals" => [odd])
      expect(store.match(ask)).to be_nil
      store.add(ask, "session")
      expect(stored["approvals"].first).to eq(odd)
      expect(stored["approvals"].size).to eq(2)
    end

    it "sets aside a versioned store whose approvals isn't a list, once" do
      write_store("version" => 1, "approvals" => { "scope" => "session" })
      expect(store.entries).to eq([])
      expect(store.entries).to eq([])
      expect(warnings.size).to eq(1)
      expect(Dir[File.join(state, "guardrails", "approvals.json.corrupt-*")].size).to eq(1)
    end

    it "writes a versioned store when there was none" do
      store.add(ask, "session")
      expect(stored).to include("version" => 1)
      expect(stored["approvals"].map { |e| e["key"] }).to eq(["execute:git push origin main"])
      expect(warnings).to be_empty
    end

    it "reads a bare list (0.166 and before) and writes it as a versioned store" do
      write_store([entry])
      expect(store.entries).to eq([entry])
      expect(warnings).to be_empty

      store.add(ask(command: "git push origin other"), "session")
      expect(stored).to include("version" => 1)
      expect(stored["approvals"].map { |approval| approval["key"] })
        .to eq([entry["key"], "execute:git push origin other"])
      expect(warnings).to be_empty
      expect(Dir[File.join(state, "guardrails", "approvals.json.corrupt-*")]).to be_empty
    end
  end
end

RSpec.describe Samagotchi::Guardrails::Gate, "with an approval store" do
  let(:state) { Dir.mktmpdir("guard-gate-store") }
  let(:store) { Samagotchi::Guardrails::Approvals.new(dir: File.join(state, "guardrails")) }
  let(:hooks) { Samagotchi::Hooks::Registry.new }
  let(:asked) { [] }
  let(:pick) { "repo" }
  let(:gate) do
    approver = lambda do |v, _turn|
      asked << v.call[:content]
      v.settle!(:allow)
      v.scope = pick
      v
    end
    ctx = Samagotchi::Guardrails::Context.new(cwd: state, session_id: "s1")
    described_class.new(hooks: hooks, context_for: ->(_turn) { ctx }, approver: approver, approvals_lookup: -> { store })
  end

  before { hooks.register(:before_tool_call) { |e| e[:guardrail].ask!("sure?", rule: "r", source: "config") } }
  after { FileUtils.rm_rf(state) }

  def settle(content)
    v = gate.evaluate({ name: "execute", content: content }, context: Samagotchi::TurnContext.none, iteration: 1, params: "")
    gate.settle_ask(v, context: Samagotchi::TurnContext.none)
  end

  it "stores an answer beyond once, and doesn't ask for that call again" do
    first = settle("git push")
    second = settle("git push")
    expect(asked).to eq(["git push"])
    expect([first.decided_by, second.decided_by, second.scope]).to eq(%w[user approval repo])
    expect(second.to_activity).to include(note: "approved earlier (repo)")
  end

  context "when the user allows once" do
    let(:pick) { "once" }

    it "asks again next time" do
      2.times { settle("git push") }
      expect(asked.size).to eq(2)
      expect(store.entries).to eq([])
    end
  end

  it "never relaxes a deny" do
    settle("git push")
    hooks.register(:before_tool_call) { |e| e[:guardrail].deny!("no") }
    v = gate.evaluate({ name: "execute", content: "git push" }, context: Samagotchi::TurnContext.none, iteration: 1, params: "")
    expect(v).to be_deny
  end
end

# The guardrails bundle's git-outside-repo rule through the Gate: the ask
# reaches the approver, and "rule in this repo" stops later asks there.
RSpec.describe Samagotchi::Guardrails::Gate, "with the bundle's git-outside-repo rule" do
  let(:base) { File.realpath(Dir.mktmpdir("guard-gate-outside")) }
  let(:repo) { File.join(base, "wt").tap { |d| FileUtils.mkdir_p(d) && system("git", "-C", d, "init", "-q") } }
  let(:main) { File.join(base, "main").tap { |d| FileUtils.mkdir_p(d) } }
  let(:store) { Samagotchi::Guardrails::Approvals.new(dir: File.join(base, "state", "guardrails")) }
  let(:asked) { [] }
  let(:rules) do
    file = File.expand_path("../../lib/samagotchi/bundles/guardrails/guardrails/rules.yml", __dir__)
    Samagotchi::Guardrails::Rules.new(
      Samagotchi::Guardrails::Rules.parse(YAML.safe_load_file(file)["rules"], source: "bundle guardrails"),
      mode: "strict" # git-outside-repo is strict only
    )
  end
  let(:gate) do
    approver = lambda do |v, _turn|
      asked << [v.call[:content], v.rule, v.scopes]
      v.settle!(:allow)
      v.scope = "rule"
      v
    end
    ctx = Samagotchi::Guardrails::Context.new(cwd: repo, session_id: "s1")
    described_class.new(context_for: ->(_turn) { ctx }, approver: approver, approvals_lookup: -> { store },
                        checks_for: ->(_turn) { [rules] })
  end

  after { FileUtils.rm_rf(base) }

  def settle(content)
    v = gate.evaluate({ name: "execute", content: content }, context: Samagotchi::TurnContext.none, iteration: 1, params: "")
    v.ask? ? gate.settle_ask(v, context: Samagotchi::TurnContext.none) : v
  end

  it "asks once; after rule in this repo, later git there runs unasked" do
    first = settle("cd #{main} && git add a.rb && git commit -m one")
    second = settle("cd #{main} && git commit -m two")
    expect(asked).to eq([["cd #{main} && git add a.rb && git commit -m one", "git-outside-repo", %w[once session rule]]])
    expect([first.decision, second.decision, second.decided_by]).to eq([:allow, :allow, "approval"])
    expect(store.entries).to contain_exactly(include("scope" => "rule", "rule" => "git-outside-repo", "repo_root" => repo))
  end
end
