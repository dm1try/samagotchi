# frozen_string_literal: true

require "tmpdir"
require "samagotchi/guardrails"
require "samagotchi/hooks"
require "samagotchi/session"

RSpec.describe Samagotchi::Guardrails::Approvals do
  let(:state) { Dir.mktmpdir("guard-store") }
  let(:warnings) { [] }
  let(:store) { described_class.new(dir: File.join(state, "guardrails"), warn: ->(m) { warnings << m }) }
  let(:repo) { File.join(state, "repo").tap { |d| FileUtils.mkdir_p(d) } }
  let(:other_repo) { File.join(state, "other").tap { |d| FileUtils.mkdir_p(d) } }

  after { FileUtils.rm_rf(state) }

  def ask(command: "git push  origin main", cwd: repo, session: "s1", rule: "git-push", source: "config", tool: "execute")
    call = { name: tool, content: command }
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

  it "matches a repo entry in that repo (the cwd outside one) from any session" do
    store.add(ask, "repo")
    expect(store.match(ask(session: "s9"))).to include("scope" => "repo", "repo_root" => repo)
    expect(store.match(ask(cwd: other_repo))).to be_nil
  end

  it "matches a rule entry for any call that rule asks about in the repo, from the same source" do
    store.add(ask, "rule")
    expect(store.match(ask(command: "git push --force"))).to include("scope" => "rule", "rule" => "git-push")
    expect(store.match(ask(command: "git push", source: "bundle guardrails"))).to be_nil
    expect(store.match(ask(cwd: other_repo))).to be_nil
    expect(store.match(ask(rule: nil))).to be_nil
  end

  it "keys file tools by their paths" do
    v = ask(tool: "write", command: nil)
    v.targets = Samagotchi::Guardrails::Targets.for({ name: "write", path: "a.txt" }, v.context)
    store.add(v, "repo")
    expect(store.entries.first["key"]).to eq("write:#{repo}/a.txt")
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
    pids = 4.times.map do |i|
      fork do
        s = described_class.new(dir: File.join(state, "guardrails"))
        5.times { |j| s.add(ask(command: "cmd #{i}-#{j}"), "repo") }
        exit!(0)
      end
    end
    pids.each { |pid| Process.wait(pid) }
    expect(store.entries.size).to eq(20)
  end

  it "treats a corrupt file as empty, with one warning" do
    FileUtils.mkdir_p(File.join(state, "guardrails"))
    File.write(store.path, "{not json")
    expect(store.match(ask)).to be_nil
    expect(store.entries).to eq([])
    expect(warnings.size).to eq(1)
    expect(warnings.first).to include("unreadable")
  end
end

RSpec.describe Samagotchi::Guardrails::Gate, "with an approval store" do
  let(:state) { Dir.mktmpdir("guard-gate-store") }
  let(:store) { Samagotchi::Guardrails::Approvals.new(dir: File.join(state, "guardrails")) }
  let(:hooks) { Samagotchi::Hooks::Registry.new }
  let(:asked) { [] }
  let(:pick) { "repo" }
  let(:gate) do
    approver = lambda do |v|
      asked << v.call[:content]
      v.settle!(:allow)
      v.scope = pick
      v
    end
    ctx = Samagotchi::Guardrails::Context.new(cwd: state, session_id: "s1")
    described_class.new(-> { hooks }, context_lookup: -> { ctx }, approver: approver, approvals_lookup: -> { store })
  end

  before { hooks.register(:before_tool_call) { |e| e[:guardrail].ask!("sure?", rule: "r", source: "config") } }
  after { FileUtils.rm_rf(state) }

  def settle(content)
    v = gate.evaluate({ name: "execute", content: content }, iteration: 1, params: "")
    gate.settle_ask(v)
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
    v = gate.evaluate({ name: "execute", content: "git push" }, iteration: 1, params: "")
    expect(v).to be_deny
  end
end
