# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/engine"
require "samagotchi/session"
require "support/thinking_off"
require "support/test_kernel"

# The candidate judge's wiring in the Engine (docs/context.md, "The
# judge"): when it asks, on which thread, and what it never touches.
RSpec.describe Samagotchi::Engine do
  include_context "thinking off"

  let(:dir) { Dir.mktmpdir("context-judge-engine") }
  let(:state_dir) { File.join(dir, "sessions").tap { |d| FileUtils.mkdir_p(d) } }
  let(:mode) { "audit" }
  let(:asked) { Queue.new }
  let(:answers) { [] }
  let(:system_one) { instance_double(Samagotchi::SystemOne::Client, host: "judge", model: "jev") }

  before do
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("context.candidates.mode").and_return(mode)
    allow(Samagotchi::Config).to receive(:get).with("toolkit.suggest.mode").and_return("off")
    allow(system_one).to receive(:ask) do |state:, questions:, **|
      asked << [state, questions]
      about, task = answers.shift || [0.9, 0.9]
      { "about" => Samagotchi::SystemOne::Answer.new(id: "about", type: :noul, noul: about),
        "task" => Samagotchi::SystemOne::Answer.new(id: "task", type: :noul, noul: task) }
    end
    allow(Samagotchi::SystemOne::Client).to receive(:from_config).and_return(system_one)
  end

  after do
    @engine&.shutdown
    FileUtils.rm_rf(dir)
  end

  def build_engine(model_host: double(name: "model", remote?: true, root_url: "https://model:443"))
    client = test_client
    @engine = described_class.new(client: client, kernel: test_kernel(client: client), model_name: "Gemma-4B-it")
    @engine.instance_variable_set(:@session_state_dir, state_dir)
    @engine.instance_variable_set(:@host_registry, double(host_for_model: [model_host, nil], find_entry: nil))
    allow(@engine).to receive(:effective_model_name).and_return("model")
    @engine
  end

  def new_session(**fields)
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: dir).tap do |s|
      fields.each { |key, value| s.public_send(:"#{key}=", value) }
      s.save(state_dir: state_dir)
    end
  end

  def propose(session, name, title: "##{name} Fix the login redirect")
    Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir).add_candidate(
      Samagotchi::ContextSources::Candidate.new(name: name, url: nil, cmd: "printf x", title: title, describe: nil,
                                                mentions: [], proposed_by: "plugin:test", at: "2026-10-31T10:00:00Z")
    )
  end

  def turn(session, prompt, author: nil)
    Struct.new(:session, :prompt, :origin).new(session, prompt, Struct.new(:author).new(author))
  end

  def judge(engine, session, prompt, author: nil)
    engine.send(:start_context_judge, turn(session, prompt, author: author))
    thread = engine.instance_variable_get(:@side_judgments).thread(:context)
    join!(thread, "the context asks") if thread
  end

  def owner_prompt(session, text)
    session.messages << { role: "user", turn_id: SecureRandom.uuid, content: text } << { role: "model", content: "ok" }
  end

  def lines(kind = nil)
    path = Samagotchi::ContextCandidatesLog.path(state_dir)
    all = File.exist?(path) ? File.readlines(path).map { |line| JSON.parse(line) } : []
    kind ? all.select { |line| line["kind"] == kind } : all
  end

  context "with mode off (the default)" do
    let(:mode) { "off" }

    it "sends nothing to System 1, but still logs the user's own changes" do
      engine = build_engine
      session = new_session
      propose(session, "pr-412")
      Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir).decline("pr-412", nil)

      judge(engine, session, "Fix the login redirect")

      expect(Samagotchi::SystemOne::Client).not_to have_received(:from_config)
      expect(lines.map { |line| line["kind"] }).to eq(["declined"])
    end
  end

  it "asks once per proposed candidate at an owner turn's start, logs it and attaches nothing" do
    engine = build_engine
    session = new_session
    propose(session, "pr-412")
    propose(session, "pr-500", title: "#500 Other work")
    answers.push([0.85, 0.9], [0.1, 0.9])

    judge(engine, session, "Fix the login redirect")

    states = [pop!(asked, "the first ask"), pop!(asked, "the second ask")].map(&:first)
    expect(states.map { |state| state["candidate"] }).to contain_exactly("#pr-412 Fix the login redirect", "#500 Other work")
    expect(states.map { |state| state["conversation"] }).to all(eq(["Fix the login redirect"]))
    expect(lines("judged").to_h { |line| [line["name"], line["would"]] }).to eq("pr-412" => "attach", "pr-500" => "none")
    expect(Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir).sources).to eq([])

    owner_prompt(session, "Fix the login redirect")
    judge(engine, session, "and the test")
    expect(asked).to be_empty
  end

  it "defers a candidate while no task is stated, and judges it at the next real prompt" do
    engine = build_engine
    session = new_session
    propose(session, "pr-412")
    answers.push([0.5, 0.1], [0.9, 0.95])

    judge(engine, session, "hi")
    owner_prompt(session, "hi")
    judge(engine, session, "Fix the login redirect")

    expect(lines("judged").map { |line| line.values_at("stated", "owner_prompts") }).to eq([[false, 1], [true, 2]])
    _first = pop!(asked, "the deferred ask")
    second = pop!(asked, "the judged ask")
    expect(second.first["conversation"]).to eq(["Fix the login redirect"])
  end

  it "asks nothing for a participant's turn or in a review session" do
    engine = build_engine
    session = new_session
    propose(session, "pr-412")

    judge(engine, session, "Fix the login redirect", author: "p:abc")
    session.review = { "subjects" => ["a.md"] }
    judge(engine, session, "Fix the login redirect")

    expect(system_one).not_to have_received(:ask)
  end

  it "waits for the turn's end on the model's own local server" do
    engine = build_engine(model_host: double(name: "judge", remote?: false, root_url: "http://127.0.0.1:8080"))
    allow(engine).to receive(:turn_running?).and_return(true)
    session = new_session
    propose(session, "pr-412")

    judge(engine, session, "Fix the login redirect")
    expect(system_one).not_to have_received(:ask)

    engine.send(:run_context_judge_after_turn)
    join!(engine.instance_variable_get(:@side_judgments).thread(:context), "the asks after the turn")
    expect(lines("judged").size).to eq(1)
  end

  it "judges a late proposal on the owner's prompts so far" do
    engine = build_engine
    session = new_session
    owner_prompt(session, "Fix the login redirect")
    engine.instance_variable_set(:@session, session)
    allow(engine).to receive(:messages_checkpoint).and_return(session.messages)
    propose(session, "pr-412")

    engine.send(:judge_late_candidates)
    join!(engine.instance_variable_get(:@side_judgments).thread(:context), "the late ask")

    expect(lines("judged").first).to include("phase" => "late", "owner_prompts" => 1)
  end

  it "gives a delegate child its parent's attached sources as started_from" do
    engine = build_engine
    parent = new_session
    Samagotchi::ContextSources.session_location(parent.id, state_dir: state_dir).add(
      Samagotchi::ContextSources::Source.new(name: "pr-400", cmd: "printf x", every_seconds: nil, why: "w", hint: nil,
                                             scope: "session", added_by: "cli", created_at: "2026-10-31T10:00:00Z",
                                             title: "#400 Epic: auth")
    )
    child = new_session(parent_id: parent.id, delegate: true)
    propose(child, "pr-412")

    judge(engine, child, "Do the redirect part")

    state, questions = pop!(asked, "the child's ask")
    expect(state["started_from"]).to eq("parent_attached" => ["#400 Epic: auth"])
    expect(questions["about"].instructions).to include("started_from")
  end
end
