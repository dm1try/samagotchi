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

  def build_engine
    client = test_client
    @engine = described_class.new(client: client, kernel: test_kernel(client: client), model_name: "Gemma-4B-it")
    @engine.instance_variable_set(:@session_state_dir, state_dir)
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

  it "asks once per proposed candidate at an owner turn's start, logs it and in audit attaches nothing" do
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

  it "saves each ask as context.candidate's run, on the session it judged" do
    store = Samagotchi::SystemOne::Runs::MemoryStore.new
    engine = build_engine
    allow(engine).to receive(:system_one_runs).and_return(Samagotchi::SystemOne::Runs.new(store: store))
    session = new_session
    propose(session, "pr-412")

    judge(engine, session, "Fix the login redirect")
    join!(engine.instance_variable_get(:@side_judgments).thread(:context), "the asks")
    line = store.lines["context.candidate"].first
    expect(line).to include("judgment" => "context.candidate", "session_id" => session.id, "session_model" => "model")
    expect(line["state"]["candidate"]).to include("Fix the login redirect")
  end

  # A whole run_turn with System 1 on the session's model server. The asks start
  # at the turn's start: the docs' promises for what they answer hold there too.
  context "with System 1 on the model's own local host, during a turn" do
    let(:mode) { "on" }
    let(:kernel_client) { test_client }
    let(:kernel) { test_kernel(client: kernel_client) }
    let(:requests) { [] }

    def own(session) = Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir)

    def own_host_engine
      @engine = described_class.new(client: kernel_client, kernel: kernel, model_name: "Gemma-4B-it").tap do |engine|
        engine.session_state_dir = state_dir
        allow(engine.instance_variable_get(:@host_registry)).to receive(:host_for_model)
          .and_return([Samagotchi::HostRegistry::HostEntry.new(name: "judge", host: "127.0.0.1", port: 8080, client: kernel_client), nil])
      end
    end

    # The model's request: it waits for the asks, so what they answered is
    # there to be seen while the turn is running.
    def model_waits_for_the_asks(engine, seen = {})
      allow(kernel).to receive(:run) do |messages, **|
        thread = engine.instance_variable_get(:@side_judgments).thread(:context)
        join!(thread, "the asks during the turn") if requests.empty? && thread
        seen[:running] = engine.turn_running? if requests.empty?
        seen[:judged] = lines("judged").size if requests.empty?
        yield seen if block_given? && requests.empty?
        requests << messages.map(&:dup)
        Samagotchi::LLM::ModelResult.new(text: "ok", conversation: messages.reject { |m| m[:role].to_s == "system" } +
                                                                   [{ role: "model", content: "ok" }],
                                         exhausted: false, pending_tool_calls: false, tool_activity: [])
      end
      seen
    end

    it "asks during the turn; an attach stays out of its history, and its note is delivered between turns" do
      engine = own_host_engine
      session = new_session
      propose(session, "pr-412")
      answers.push([0.9, 0.9])
      seen = model_waits_for_the_asks(engine) { |facts| facts[:attached] = !own(session).source("pr-412").nil? }

      engine.run_turn(session, "Fix the login redirect")

      expect(seen).to eq(running: true, judged: 1, attached: true)
      note = ->(message) { message[:context_source] == "pr-412" }
      expect(requests.first.select(&note)).to be_empty
      expect(session.messages.select(&note)).to be_empty

      # The poller's fetch, then the delivery between turns.
      own(session).record_text("pr-412", Samagotchi::ContextSources::Fetched.new(text: "x", summary: nil, wake: false, hint: nil))
      expect(Samagotchi::ContextCandidates.deliver_notes(engine, session, state_dir: state_dir)).to eq(1)
      engine.run_turn(session, "and the test")
      expect(requests.last.count(&note)).to eq(1)
    end

    it "holds a card its answer brings until the turn has ended" do
      engine = own_host_engine
      allow(engine).to receive(:show_card).and_call_original
      session = new_session
      propose(session, "pr-412")
      answers.push([0.7, 0.9])
      seen = model_waits_for_the_asks(engine) do |facts|
        facts[:carded] = lines("carded").size
        expect(engine).not_to have_received(:show_card)
      end

      engine.run_turn(session, "Fix the login redirect")

      expect(seen).to include(running: true, carded: 1)
      expect(engine).to have_received(:show_card).once.with(hash_including(id: "context-candidate-pr-412"))
      expect(requests.first.map { |message| message[:content].to_s }).not_to include(a_string_including("pr-412"))
    end
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

  context "with mode on" do
    let(:mode) { "on" }

    def own(session) = Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir)

    it "attaches a candidate the judge puts at or over the threshold, adding nothing to the conversation itself" do
      engine = build_engine
      allow(engine).to receive(:show_card).and_call_original
      session = new_session
      propose(session, "pr-412")
      answers.push([0.9, 0.9])
      before = session.messages.dup

      judge(engine, session, "Fix the login redirect")

      expect(own(session).source("pr-412").why).to eq("it looks related to your task")
      expect(session.messages).to eq(before)
      expect(engine).not_to have_received(:show_card)
      expect(lines.map { |line| line["kind"] }).to eq(%w[judged judge_attached])
    end

    it "shows the middle band's card once, also after a restart (a new Engine)" do
      engine = build_engine
      allow(engine).to receive(:show_card).and_call_original
      session = new_session
      propose(session, "pr-412")
      answers.push([0.7, 0.9], [0.7, 0.9])

      judge(engine, session, "Fix the login redirect")
      expect(engine).to have_received(:show_card).once.with(hash_including(id: "context-candidate-pr-412"))
      engine.shutdown

      restarted = build_engine
      allow(restarted).to receive(:show_card).and_call_original
      ["Fix the login redirect", "a", "b"].each { |text| owner_prompt(session, text) }
      judge(restarted, session, "and c")

      expect(lines("judged").size).to eq(2)
      expect(restarted).not_to have_received(:show_card)
      expect(lines("carded").size).to eq(1)
      expect(own(session).sources).to eq([])
    end

    it "holds a card an answer brings mid-turn until the turn has ended" do
      engine = build_engine
      allow(engine).to receive(:show_card).and_call_original
      running = true
      allow(engine).to receive(:turn_running?) { running }
      session = new_session
      propose(session, "pr-412")
      answers.push([0.7, 0.9])

      judge(engine, session, "Fix the login redirect")
      expect(engine).not_to have_received(:show_card)
      expect(lines("carded").size).to eq(1)

      running = false
      engine.send(:show_context_cards_after_turn)
      expect(engine).to have_received(:show_card).once.with(hash_including(id: "context-candidate-pr-412"))
      engine.send(:show_context_cards_after_turn)
      expect(engine).to have_received(:show_card).once
    end

    it "leaves a candidate under the offer threshold proposed" do
      engine = build_engine
      allow(engine).to receive(:show_card).and_call_original
      session = new_session
      propose(session, "pr-412")
      answers.push([0.3, 0.9])

      judge(engine, session, "Fix the login redirect")

      expect(own(session).sources).to eq([])
      expect(engine).not_to have_received(:show_card)
      expect(Samagotchi::ContextCandidates.with_status(session.id, project_root: session.project_root, state_dir: state_dir)
        .map(&:last)).to eq(["proposed"])
    end

    it "never judges again a judge-attached source the user removed: it is declined" do
      engine = build_engine
      session = new_session
      propose(session, "pr-412")
      answers.push([0.9, 0.9])
      judge(engine, session, "Fix the login redirect")
      pop!(asked, "the first ask")

      own(session).remove("pr-412")
      ["Fix the login redirect", "a", "b"].each { |text| owner_prompt(session, text) }
      judge(engine, session, "and c")

      expect(asked).to be_empty
      expect(lines.map { |line| line["kind"] }).to eq(%w[judged judge_attached declined])
    end
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
