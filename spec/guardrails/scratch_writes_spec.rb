# frozen_string_literal: true

require "tmpdir"
require "samagotchi/guardrails"
require "samagotchi/engine"
require "samagotchi/tool_runner"

RSpec.describe Samagotchi::Guardrails::ScratchWrites do
  let(:root) { File.realpath(Dir.mktmpdir("guard-scratch")) }
  let(:memories) { File.join(root, "memories").tap { |d| FileUtils.mkdir_p(d) } }
  let(:checks) { described_class.new(memories_dir: -> { memories }) }
  let(:context) { Samagotchi::Guardrails::Context.new(cwd: root) }

  after { FileUtils.rm_rf(root) }

  def verdict_for(call)
    v = Samagotchi::Guardrails::Verdict.new(call: call)
    v.context = context
    v.targets = Samagotchi::Guardrails::Targets.for(call, context)
    checks.check(v)
  end

  it "denies write and edit under the memories folder, and nothing else" do
    v = verdict_for(name: "write", path: "memories/projects/p/notes.md", content: "x")
    expect([v.decision, v.reason, v.rule]).to eq([:deny, "scratch session: nothing is saved", "scratch-session"])
    expect(verdict_for(name: "edit", path: "memories/index.md", content: "x")).to be_deny
    expect(verdict_for(name: "read", content: "memories/index.md")).to be_allow
    expect(verdict_for(name: "write", path: "src/a.rb", content: "x")).to be_allow
    expect(verdict_for(name: "write", path: "memories-old/a.md", content: "x")).to be_allow
  end
end

RSpec.describe "Engine: a scratch session" do
  let(:client) { instance_double(Samagotchi::Client) }
  let(:memories) { Samagotchi::Tools::MemoryRead.memories_dir("system") }
  let(:entry) { File.join(memories, "scratch-spec-entry.md") }

  after { FileUtils.rm_f(entry) }

  def run_call(engine, call)
    kernel = engine.instance_variable_get(:@kernel)
    Samagotchi::ToolRunner.new(kernel).run(call, iteration: 1, call_index: 1, call_count: 1,
                                                 on_stream_event: nil, max_tool_output_chars: nil)[:output]
  end

  it "refuses memory_write with a short tool result and saves nothing" do
    engine = Samagotchi::Engine.new(client: client, scratch: true)
    output = run_call(engine, name: "memory_write", path: "scratch-spec-entry", scope: "system", content: "remember me")
    expect(output).to eq("[memory_write]\nError: scratch session: nothing is saved")
    expect(File.exist?(entry)).to be(false)
  end

  it "refuses a write into the memories folder, not one elsewhere" do
    engine = Samagotchi::Engine.new(client: client, scratch: true)
    expect(run_call(engine, name: "write", path: entry, content: "sneaky")).to include("scratch session: nothing is saved")
    expect(File.exist?(entry)).to be(false)
  end

  it "writes memories as usual when not scratch" do
    engine = Samagotchi::Engine.new(client: client)
    run_call(engine, name: "memory_write", path: "scratch-spec-entry", scope: "system", content: "remember me")
    expect(File.read(entry)).to include("remember me")
  end

  it "offers no delegate tools (a child would outlive it) and no send_note (the note would); memory_write is still declared" do
    names = Samagotchi::Engine.new(client: client, scratch: true).instance_variable_get(:@tools).names
    expect(names).not_to include("delegate", "delegate_result", "send_note")
    expect(names).to include("memory_write", "memory_read")
    expect(Samagotchi::Engine.new(client: client).instance_variable_get(:@tools).names).to include("delegate", "send_note")
  end
end

RSpec.describe "Engine: a scratch session's approvals" do
  let(:client) { instance_double(Samagotchi::Client) }
  let(:state) { Dir.mktmpdir("scratch-approvals") }
  let(:sessions_dir) { File.join(state, "sessions") }
  let(:store_path) { File.join(Samagotchi::Guardrails::Approvals.dir_for(sessions_dir), "approvals.json") }

  after { FileUtils.rm_rf(state) }

  def engine_for(scratch:, scopes: nil)
    Samagotchi::Engine.new(client: client, scratch: scratch).tap do |e|
      e.guardrail_state_dir = sessions_dir
      e.interface = :worker
      e.session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd)
      e.register_hook(:before_tool_call) { |ev| ev[:guardrail].ask!("pushes", rule: "git-push", source: "config", scopes: scopes) }
    end
  end

  def gate(engine) = engine.instance_variable_get(:@kernel).guardrail_gate

  # Evaluates the call on a thread, answers its approval with the option
  # for +scope+ (nil: no question expected) and returns [verdict, offered].
  def evaluate(engine, scope)
    verdict = nil
    thread = Thread.new do
      verdict = gate(engine).evaluate({ name: "execute", content: "git push" }, iteration: 1, params: "")
      gate(engine).settle_ask(verdict)
    end
    offered = nil
    if scope
      wait_until(timeout: 2, interval: 0.005) { engine.pending_question }
      pending = engine.pending_question
      offered = pending[:approval][:scopes]
      engine.answer_question(id: pending[:id], selected: [pending[:options][offered.index(scope)]])
    end
    thread.join(2)
    [verdict, offered]
  end

  it "offers only once and session, and keeps a session approval in memory, not in the store" do
    engine = engine_for(scratch: true)
    verdict, offered = evaluate(engine, "session")
    expect(offered).to eq(%w[once session])
    expect([verdict.decision, verdict.scope]).to eq([:allow, "session"])
    expect(File.exist?(store_path)).to be(false)

    verdict, = evaluate(engine, nil)
    expect([verdict.decision, verdict.decided_by]).to eq([:allow, "approval"])
    expect(File.exist?(store_path)).to be(false)
  end

  it "still honors an approval stored before (a repo one)" do
    plain = engine_for(scratch: false)
    _, offered = evaluate(plain, "repo")
    expect(offered).to eq(%w[once session repo rule])
    expect(File.exist?(store_path)).to be(true)

    verdict, = evaluate(engine_for(scratch: true), nil)
    expect([verdict.decision, verdict.scope]).to eq([:allow, "repo"])
  end

  it "offers once when the rule offers only wider scopes" do
    verdict, offered = evaluate(engine_for(scratch: true, scopes: %w[repo]), "once")
    expect(offered).to eq(%w[once])
    expect(verdict).to be_allow
  end
end
