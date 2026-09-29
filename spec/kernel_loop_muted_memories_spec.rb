# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/engine"
require "samagotchi/kernel_loop"

RSpec.describe "memory_read with muted memories" do
  let(:client) { instance_double(Samagotchi::Client) }
  let(:kernel) { Samagotchi::KernelLoop.new(client: client, profile: :gemma4) }
  let(:index) { "# Memory Index\n\n- **gh-helper** · system · 2026-09-01 · 120 — GitHub\n- **cli_usage** · system · 2026-09-01 · 80 — CLI\n" }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_call_original
    allow(Samagotchi::Tools::MemoryRead).to receive(:call) do |name, scope: nil, model_key: nil|
      names = Samagotchi::Tools::MemoryRead.parse_names(name.to_s)
      if names.empty?
        index
      else
        names.map { |n| "BODY-#{n}" }.join(Samagotchi::Tools::MemoryRead::SEPARATOR)
      end
    end
  end

  def read(content, scope: nil)
    kernel.dispatch_tool_call(name: "memory_read", content: content, scope: scope)[:output]
  end

  it "reads as usual when nothing is muted" do
    expect(read("gh-helper")).to eq("[memory_read]\nBODY-gh-helper")
    expect(read("")).to eq("[memory_read]\n#{index}")
  end

  it "refuses a muted name and reads the rest of a comma list" do
    kernel.muted_memory_names = ["gh-helper"]
    expect(read("gh-helper,cli_usage")).to eq(
      "[memory_read]\nBODY-cli_usage#{Samagotchi::Tools::MemoryRead::SEPARATOR}Error: memory 'gh-helper' is muted for this session"
    )
    expect(Samagotchi::Tools::MemoryRead).to have_received(:call).with("cli_usage", scope: nil, model_key: nil)
  end

  it "answers a lone muted name with the error only, without reading" do
    kernel.muted_memory_names = ["gh-helper"]
    expect(read("gh-helper", scope: "system")).to eq("[memory_read]\nError: memory 'gh-helper' is muted for this session")
    expect(Samagotchi::Tools::MemoryRead).not_to have_received(:call)
  end

  it "filters the muted line out of the blank-name index" do
    kernel.muted_memory_names = ["gh-helper"]
    out = read("")
    expect(out).not_to include("gh-helper")
    expect(out).to include("- **cli_usage** · system · 2026-09-01 · 80 — CLI")
  end

  it "Engine hands its kernel the muted list" do
    allow(Samagotchi::ConfigFile).to receive(:preloaded_memories).and_return([])
    engine = Samagotchi::Engine.new(mode: :assist, client: client, profile: "gemma4", kernel: kernel,
                                    muted_memories: ["project/gh-helper.md"])
    expect(engine.muted_memory_names).to eq(["gh-helper"])
    expect(kernel.muted_memory_names).to eq(["gh-helper"])
  end

  it "Engine does not count a refused read as a used memory" do
    allow(Samagotchi::ConfigFile).to receive(:preloaded_memories).and_return([])
    engine = Samagotchi::Engine.new(mode: :assist, client: client, profile: "gemma4", kernel: kernel,
                                    muted_memories: ["gh-helper"])
    event = { type: :tool_call_started, call: { name: "memory_read", content: "gh-helper, cli_usage" } }
    engine.send(:capture_used_memory_from_event, event)
    expect(engine.used_memory_names).to eq(["cli_usage"])
  end

  it "Engine follows every memory read with used_memories_updated (the names read, not muted ones)" do
    allow(Samagotchi::ConfigFile).to receive(:preloaded_memories).and_return([])
    engine = Samagotchi::Engine.new(mode: :assist, client: client, profile: "gemma4", kernel: kernel,
                                    muted_memories: ["gh-helper"])
    seen = []
    sink = ->(e) { seen << e }
    engine.send(:emit_event, sink, { type: :tool_call_started, call: { name: "memory_read", content: "gh-helper, cli_usage, notes.md" } })
    engine.send(:emit_event, sink, { type: :tool_call_started, call: { name: "read", content: "memories/notes.md" } })
    engine.send(:emit_event, sink, { type: :tool_call_started, call: { name: "memory_read", content: "gh-helper" } })
    engine.send(:emit_event, sink, { type: :tool_call_started, call: { name: "execute", content: "ls" } })

    updates = seen.select { |e| e[:type] == :used_memories_updated }
    expect(seen.map { |e| e[:type] }).to eq(%i[tool_call_started used_memories_updated tool_call_started used_memories_updated
                                               tool_call_started tool_call_started])
    expect(updates.map { |e| e.slice(:used_memory_names, :read_names) }).to eq([
      { used_memory_names: %w[cli_usage notes], read_names: %w[cli_usage notes] },
      { used_memory_names: %w[cli_usage notes], read_names: %w[notes] }
    ])
  end
end
