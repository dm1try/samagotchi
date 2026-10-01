# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "support/test_kernel"

# The session's used memories: what the turns read or preloaded, kept on
# the session and shown in the UIs' memory line.
RSpec.describe Samagotchi::Engine, "used memories" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  let(:events) { [] }
  let(:reads) { [] }

  def build_engine(**options)
    engine = described_class.new(client: client, kernel: kernel, profile: "gemma4", **options)
    engine.subscribe(observer: ->(event) { events << event })
    engine
  end

  before do
    allow(Samagotchi::ConfigFile).to receive(:preloaded_memories).and_return([])
    allow(Samagotchi::Tools::MemoryRead).to receive(:call) { |name, **| name.to_s.empty? ? "" : "BODY-#{name}" }
  end

  def kernel_reads(engine, *calls)
    allow(kernel).to receive(:run) do |messages, on_stream_event:, **|
      calls.each { |call| on_stream_event.call({ type: :tool_call_started, call: call }) }
      Samagotchi::LLM::ModelResult.new(text: "ok", conversation: messages + [{ role: "model", content: "ok" }],
                                       exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: false)
    end
    engine
  end

  def updates = events.select { |e| e[:type] == :used_memories_updated }

  it "a resumed session hydrates the list, deduped" do
    session.used_memory_names = %w[notes plan notes]
    session.save

    engine = build_engine(session_id: session.id)

    expect(engine.used_memory_names).to eq(%w[notes plan])
    expect(engine.session_state_snapshot[:used_memory_names]).to eq(%w[notes plan])
  end

  it "a session set before the first turn adds its names" do
    engine = build_engine
    session.used_memory_names = %w[notes]

    engine.session = session

    expect(engine.used_memory_names).to eq(%w[notes])
  end

  it "adds the preloads in the turn and keeps the list on the session" do
    engine = kernel_reads(build_engine(memories: ["notes"]))

    engine.run_turn(session, "hi")

    expect(engine.used_memory_names).to eq(%w[notes])
    expect(session.used_memory_names).to eq(%w[notes])
    expect(updates.last).to eq(type: :used_memories_updated, used_memory_names: %w[notes], event_seq: updates.last[:event_seq])
  end

  it "counts memory_read names (a comma list) and a read of memories/*.md" do
    engine = kernel_reads(build_engine,
                          { name: "memory_read", content: "a, b.md, ,x" },
                          { name: "read", content: "memories/foo.md" },
                          { name: "read", content: "lib/foo.rb" })

    engine.run_turn(session, "hi")

    expect(engine.used_memory_names).to eq(%w[a b x foo])
    expect(updates.map { |e| e[:read_names] }).to eq([%w[a b x], ["foo"], nil])
  end

  it "does not count a muted memory" do
    engine = kernel_reads(build_engine(muted_memories: ["secret"]),
                          { name: "memory_read", content: "secret, open" })

    engine.run_turn(session, "hi")

    expect(engine.used_memory_names).to eq(%w[open])
  end

  it "a repeat read still emits used_memories_updated with its read_names" do
    engine = kernel_reads(build_engine,
                          { name: "memory_read", content: "a" },
                          { name: "memory_read", content: "a" })

    engine.run_turn(session, "hi")

    expect(updates.map { |e| [e[:used_memory_names], e[:read_names]] })
      .to eq([[%w[a], %w[a]], [%w[a], %w[a]], [%w[a], nil]])
  end

  it "the turn's end emits nothing when the list is empty, and still sets it on the session" do
    engine = kernel_reads(build_engine)
    session.used_memory_names = []

    engine.run_turn(session, "hi")

    expect(updates).to be_empty
    expect(session.used_memory_names).to eq([])
  end
end
