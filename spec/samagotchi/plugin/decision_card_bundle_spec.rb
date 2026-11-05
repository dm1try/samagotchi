# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/engine"
require "samagotchi/objectives"
require "samagotchi/session"
require "samagotchi/bridge"
require "samagotchi/session_commands"
require "samagotchi/memory_bundle/installer"
require "support/test_kernel"

# The shipped decision-card bundle installed as a user would and loaded by an
# Engine that runs real turns (its plugin alone: lib/samagotchi/bundles/decision-card/spec/).
RSpec.describe "The decision-card bundle, installed" do
  let(:shipped) { File.expand_path("../../../lib/samagotchi/bundles/decision-card", __dir__) }
  let(:tmpdir) { Dir.mktmpdir("decision-card-") }
  let(:state_dir) { File.join(tmpdir, "sessions") }
  let(:client) { test_client }
  let(:events) { [] }
  let(:side_requests) { [] }
  let(:plugin_threads) { [] }
  let(:side_answer) { "SUMMARY: The cart is ready.\nQUESTION: Which size?\nOBJECTIVES: O1" }
  let(:answer) { "#{"The cart is ready. " * 80}\n\nWhich size do you want?" }
  let(:list) { Samagotchi::Objectives::List.new.set([{ text: "Two coffees" }]) }
  let(:note) do
    Samagotchi::ContextNote.message(note_id: "n1", text: list.text, source: "objectives",
                                    header: Samagotchi::ContextNote::OBJECTIVES_HEADER, objectives: list.to_payload)
  end

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

  around do |example|
    saved = ENV.to_h.slice("SAMAGOTCHI_DEFAULT_MODEL", "XDG_STATE_HOME", "SAMAGOTCHI_THINKING_LEVEL")
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    ENV["SAMAGOTCHI_THINKING_LEVEL"] = "off"
    ENV["XDG_STATE_HOME"] = File.join(tmpdir, "state")
    example.run
  ensure
    %w[SAMAGOTCHI_DEFAULT_MODEL XDG_STATE_HOME SAMAGOTCHI_THINKING_LEVEL].each { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  before do
    FileUtils.mkdir_p(Samagotchi::MemoryPaths.system_dir)
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    side = instance_double(Samagotchi::IdleClient)
    allow(side).to receive(:ask) do |request, **|
      side_requests << request
      Samagotchi::IdleClient::Summary.new(text: side_answer, model: "m", top_logprobs: nil)
    end
    allow(Samagotchi::IdleClient).to receive(:for).and_return(side)
    allow(client).to receive(:complete) { answer }
    allow(Thread).to receive(:new).and_wrap_original do |original, *args, &body|
      original.call(*args, &body).tap { |thread| plugin_threads << thread if body.source_location.first.include?("decision-card") }
    end
  end

  after { FileUtils.rm_rf(tmpdir) }

  def install
    installer = Samagotchi::MemoryBundle::Installer.new(source: shipped, name: "decision-card", scope: "system", strict: true)
    installer.run
    expect(installer.warnings).to be_empty
  end

  def new_engine
    Samagotchi::Engine.new(client: client).tap do |engine|
      engine.session_state_dir = state_dir
      engine.interface = :worker
      engine.subscribe(observer: ->(event) { events << event })
    end
  end

  def new_session(with_list: true)
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir).tap do |session|
      session.messages = [note] if with_list
    end
  end

  # A turn, then the plugin's thread: its card comes when no turn runs.
  def run(engine, session, prompt = "order it")
    engine.session = session
    engine.run_turn(session, prompt)
    plugin_threads.each(&:join)
  end

  def cards = events.select { |event| event[:type] == :card }

  it "lists /short's card as from /short, typed through the session's commands; a turn's own card names none" do
    install
    engine = new_engine
    store = Samagotchi::Bridge::CardStore.new
    engine.subscribe(observer: store)
    session = new_session
    run(engine, session)
    commands = Samagotchi::SessionCommands.new(engine: engine, turn_flow: Samagotchi::TurnFlow.new(engine: engine), default_model: "m",
                                               registry: engine.command_registry)
    commands.run("/short")
    expect(store.list(messages: session.messages).map { |c| [c[:title], c[:label]] })
      .to contain_exactly(["A question for you · O1", nil], ["Short version", "from /short"])
  end

  it "shows its card between turns, after the turn's end, with nothing in the conversation" do
    install
    engine = new_engine
    session = new_session
    run(engine, session)

    expect(side_requests.size).to eq(1)
    expect(side_requests.first.last[:content]).to include("O1 Two coffees", "order it", "Which size do you want?")
    expect(cards.size).to eq(1)
    expect(cards.first).to include(source: "decision-card", title: "A question for you · O1", in_turn: false, actions: [])
    expect(events.index { |event| event[:type] == :turn_completed }).to be < events.index { |event| event[:type] == :card }
    expect(session.messages.map { |message| message[:role] }).to eq(%w[system system user model])
    expect(session.messages.to_s).not_to include("A question for you", "The cart is ready.\\nQUESTION")
  end

  # KernelLoop keeps the model's content with its thought block until the next turn.
  it "gates on the answer, not on the thought the native loop stored with it" do
    install
    thought = "<|channel>thought\n#{"Thinking it over. " * 100}Is it?<channel|>"
    allow(client).to receive(:complete) { "#{thought}Which one?" }
    engine = new_engine
    session = new_session
    run(engine, session)

    expect(session.messages.last[:content].length).to be > 1200
    expect(side_requests).to be_empty
    expect(cards).to be_empty
  end

  it "gives the side request the answer without the thought" do
    install
    allow(client).to receive(:complete) { "<|channel>thought\nSECRET PLAN<channel|>#{answer}" }
    run(new_engine, new_session)

    expect(side_requests.size).to eq(1)
    expect(side_requests.first.last[:content]).not_to include("SECRET")
  end

  it "keeps a quick answer's card out of the turn while the turn's end takes its time" do
    install
    engine = new_engine
    # What runs after the hooks, still inside the turn (another bundle's slow hook has the same effect).
    allow(engine).to receive(:store_answer_display).and_wrap_original do |original, *args, **options|
      wait_for("the side request") { side_requests.any? }
      expect(plugin_threads.first.join(0.3)).to be_nil
      expect(cards).to be_empty
      original.call(*args, **options)
    end
    run(engine, new_session)

    expect(cards.map { |card| card[:in_turn] }).to eq([false])
  end

  it "folds the card to a line when the next turn starts, in the same place" do
    install
    engine = new_engine
    session = new_session
    run(engine, session)
    run(engine, session, "the small one")

    folded = cards.find { |card| card[:title] == "Asked" }
    expect(folded).to include(id: cards.first[:id], body: "Which size?", actions: [])
  end

  it "makes no side request in a session with no list" do
    install
    engine = new_engine
    run(engine, new_session(with_list: false))

    expect(side_requests).to be_empty
    expect(cards).to be_empty
  end

  it "sends the model the same requests as a chi without the bundle" do
    seen = []
    allow(client).to receive(:complete) do |prompt, **|
      seen << prompt
      answer
    end
    # A turn with a card, then the turn after it, when the card folds.
    turn = lambda do
      seen.clear
      session = new_session
      engine = new_engine
      run(engine, session)
      run(engine, session, "the small one")
      seen.map { |prompt| prompt.gsub(session.id, "SESSION").gsub(session.id[0, 8], "SID") }
    end

    without = turn.call
    install

    expect(without.size).to eq(2)
    expect(turn.call).to eq(without)
    expect(side_requests.size).to eq(2)
    expect(cards.map { |card| card[:title] }).to include("Asked")
  end
end
