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

  it "offers no delegate tools (a child would outlive it); memory_write is still declared" do
    names = Samagotchi::Engine.new(client: client, scratch: true).instance_variable_get(:@tools).names
    expect(names).not_to include("delegate", "delegate_result")
    expect(names).to include("memory_write", "memory_read")
    expect(Samagotchi::Engine.new(client: client).instance_variable_get(:@tools).names).to include("delegate")
  end
end
