# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/objectives"
require "samagotchi/objectives_audit"
require "samagotchi/side_judgments"
require "samagotchi/system_one/answer"
require "samagotchi/system_one/client"
require "samagotchi/system_one/fake_backend"
require "samagotchi/system_one/recording"
require "samagotchi/system_one/runs"

RSpec.describe Samagotchi::ObjectivesAudit do
  let(:tmpdir) { Dir.mktmpdir("objectives-audit") }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: tmpdir).tap { |s| s.save(state_dir: tmpdir) }
  end
  let(:store) { Samagotchi::SystemOne::Runs::MemoryStore.new }
  let(:runs) { Samagotchi::SystemOne::Runs.new(store: store) }
  let(:side) { Samagotchi::SideJudgments.new }
  let(:answer) { { "affects" => Samagotchi::SystemOne::Answer.from_wire("affects", { "type" => "noul", "noul" => 0.9 }) } }
  let(:backend) { Samagotchi::SystemOne::FakeBackend.new(answer) }
  let(:client_for) do
    lambda do |judgment, _session|
      next nil if host_gone

      client = Samagotchi::SystemOne::Client.new(backend: backend, mode: "audit", host: "h", model: "jev", tag: :system_one)
      Samagotchi::SystemOne::Recording.new(client, judgment: judgment, runs: runs,
                                                   context: Samagotchi::SystemOne::Recording::Context.of(session, session_model: "m"))
    end
  end
  let(:host_gone) { false }
  let(:audit) { described_class.new(client_for: client_for, side: side, state_dir: -> { tmpdir }) }
  let(:prompt) { "We also need the coffee order to go through a new payment provider" }
  let(:answer_text) { "I changed the checkout and ran the specs. #{"It holds. " * 60}" }

  after { FileUtils.rm_rf(tmpdir) }

  def on(mode = "audit")
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("objectives.system_one").and_return(mode)
  end

  def with_list(*statuses)
    items = statuses.each_with_index.map { |status, i| { "id" => "O#{i + 1}", "text" => "aim #{i + 1}", "status" => status, "done_when" => ("hint" if i.zero?) }.compact }
    session.messages = [Samagotchi::ContextNote.message(note_id: "n", text: "x", source: "objectives", header: Samagotchi::ContextNote::OBJECTIVES_HEADER,
                                                        objectives: { "next" => statuses.size + 1, "items" => items })]
  end

  def settle
    %i[objectives_incoming objectives_outgoing].each do |kind|
      thread = side.thread(kind)
      join!(thread, "the #{kind} asks") if thread
    end
  end

  def lines(judgment) = store.lines[judgment]

  it "is off by default: reads no list and asks nothing" do
    with_list("active")
    allow(Samagotchi::Objectives).to receive(:current).and_call_original

    audit.incoming(session, prompt)
    audit.outgoing(session, answer_text)
    audit.note(session, { text: prompt, source: "peer" })
    settle

    expect(backend.calls).to eq(0)
    expect(store.lines).to be_empty
    expect(Samagotchi::Objectives).not_to have_received(:current)
  end

  it "takes no other mode for now: an on is an off" do
    on("on")
    with_list("active")

    audit.incoming(session, prompt)
    settle

    expect(backend.calls).to eq(0)
  end

  it "asks nothing with no list, or with nothing active" do
    on
    audit.incoming(session, prompt)
    with_list("done", "dropped")
    audit.outgoing(session, answer_text)
    settle

    expect(backend.calls).to eq(0)
  end

  it "asks nothing with no host" do
    on
    with_list("active")
    allow(audit).to receive(:warn)
    audit2 = described_class.new(client_for: ->(_j, _s) {}, side: side, state_dir: -> { tmpdir })

    audit2.incoming(session, prompt)
    settle

    expect(backend.calls).to eq(0)
    expect(store.lines).to be_empty
  end

  it "one ask per active objective, recorded with the message as sent and its session" do
    on
    with_list("active", "done", "active")

    audit.incoming(session, prompt)
    settle

    expect(backend.calls).to eq(2)
    runs_seen = lines(described_class::INCOMING).select { |line| line["kind"].nil? || line["kind"] == "run" }
    expect(runs_seen.map { |line| line["state"]["objective"] }).to eq(["aim 1 (done when: hint)", "aim 3"])
    expect(runs_seen.first["state"]["message"]).to eq(prompt)
    expect(runs_seen.first).to include("asked" => true, "mode" => "audit", "session_id" => session.id, "model" => "jev")
  end

  it "keeps its asks to a few objectives" do
    on
    with_list(*Array.new(described_class::MAX_OBJECTIVES + 3, "active"))

    audit.outgoing(session, answer_text)
    settle

    expect(backend.calls).to eq(described_class::MAX_OBJECTIVES)
  end

  it "keeps its triggers narrow: a short line or a command isn't incoming, a short answer isn't outgoing" do
    on
    with_list("active")

    audit.incoming(session, "ok go")
    audit.incoming(session, "/objectives check O1 and some more words to be long enough")
    audit.incoming(session, "!ls -la and some more words to be long enough for this")
    audit.outgoing(session, "Done.")
    settle

    expect(backend.calls).to eq(0)
  end

  it "a note counts as incoming, but not the list's own or a continue's" do
    on
    with_list("active")

    audit.note(session, { text: prompt, source: "objectives", objectives: {} })
    audit.note(session, { text: prompt, source: Samagotchi::SessionChain::NOTE_SOURCE })
    settle
    expect(backend.calls).to eq(0)

    audit.note(session, { text: prompt, source: "peer" })
    settle
    expect(backend.calls).to eq(1)
    expect(lines(described_class::INCOMING).first["state"]["message"]).to eq(prompt)
  end

  it "an outgoing ask has the answer's tail, bounded, under its own judgment" do
    on
    with_list("active")
    long = "#{"a" * 5000}THE END"

    audit.outgoing(session, long)
    settle

    message = lines(described_class::OUTGOING).first["state"]["message"]
    expect(message.length).to eq(described_class::MESSAGE_CHARS)
    expect(message).to end_with("THE END")
  end

  it "a second ask while one runs is a saved skip, no request" do
    on
    with_list("active")
    gate = Queue.new
    slow = Samagotchi::SystemOne::FakeBackend.new do |_state, _questions|
      gate.pop
      answer
    end
    client = lambda do |judgment, _session|
      Samagotchi::SystemOne::Recording.new(Samagotchi::SystemOne::Client.new(backend: slow, mode: "audit", host: "h", model: "jev", tag: :system_one),
                                           judgment: judgment, runs: runs)
    end
    held = described_class.new(client_for: client, side: side, state_dir: -> { tmpdir })

    held.incoming(session, prompt)
    held.incoming(session, "#{prompt} again")
    gate << true
    settle

    expect(slow.calls).to eq(1)
    expect(lines(described_class::INCOMING).map { |line| line["asked"] }).to contain_exactly(true, false)
    expect(lines(described_class::INCOMING).find { |line| line["asked"] == false }).to include("skipped" => "busy")
  end

  it "never holds the caller: the ask runs off its thread" do
    on
    with_list("active")
    gate = Queue.new
    slow = Samagotchi::SystemOne::FakeBackend.new do |_state, _questions|
      gate.pop
      answer
    end
    client = lambda do |judgment, _session|
      Samagotchi::SystemOne::Recording.new(Samagotchi::SystemOne::Client.new(backend: slow, mode: "audit", host: "h", model: "jev", tag: :system_one),
                                           judgment: judgment, runs: runs)
    end
    held = described_class.new(client_for: client, side: side, state_dir: -> { tmpdir })

    held.outgoing(session, answer_text) # would block here if it weren't apart
    expect(store.lines).to be_empty

    gate << true
    settle
    expect(lines(described_class::OUTGOING).size).to eq(1)
  end

  it "a failed judgment is recorded and logged, and raises nowhere" do
    on
    with_list("active")
    failing = Samagotchi::SystemOne::FakeBackend.new(failing: true)
    client = lambda do |judgment, _session|
      Samagotchi::SystemOne::Recording.new(Samagotchi::SystemOne::Client.new(backend: failing, mode: "audit", host: "h", model: "jev", tag: :system_one),
                                           judgment: judgment, runs: runs)
    end
    broken = described_class.new(client_for: client, side: side, state_dir: -> { tmpdir })

    expect { broken.incoming(session, prompt) }.not_to raise_error
    settle

    expect(lines(described_class::INCOMING).first).to include("failure" => "Samagotchi::SystemOne::BackendError")
  end

  it "a raise while it prepares is one warn, never the caller's" do
    on
    allow(Samagotchi::Objectives).to receive(:current).and_raise(IOError, "disk")
    allow(Samagotchi::Log).to receive(:warn)

    expect { audit.outgoing(session, answer_text) }.not_to raise_error

    expect(Samagotchi::Log).to have_received(:warn).with(:system_one, "objectives_audit_failed", anything)
  end

  it "leaves a scratch session, a review session and a session with no id alone" do
    on
    with_list("active")
    session.scratch = true
    audit.incoming(session, prompt)
    session.scratch = false
    allow(session).to receive(:review?).and_return(true)
    audit.incoming(session, prompt)
    settle

    expect(backend.calls).to eq(0)
  end
end
