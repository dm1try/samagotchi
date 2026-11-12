# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/session"
require "samagotchi/bridge/card_store"
require "samagotchi/bridge/turn_accumulator"
require "samagotchi/bridge/turn_drawings"
require "support/stage_cut_scenarios"

# The show a page reloads to mid-turn while a card waits (the live-vs-reload
# harness, spec/web/public/stage_cuts_parity.test.js): for each scenario's
# cut, the Bridge's TurnAccumulator and CardStore fold the events so far into
# a worker's snapshot, and Web::SessionShow sends the page's read of it.
# UPDATE_STAGE_CUTS=1 writes spec/shared/stage_cuts/<name>.json.
RSpec.describe Samagotchi::Web::App, "the show at a turn's cuts (stage cuts)" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:state_dir) { Dir.mktmpdir }

  before { Samagotchi::Bridge::TurnDrawings::Synth::MEMO.clear }
  after { FileUtils.rm_rf(state_dir) }

  def loader
    Class.new do
      define_singleton_method(:load) do |_id, state_dir: nil|
        Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: "/work")
      end
      define_singleton_method(:session_dir) { |id, state_dir: nil| File.join(state_dir.to_s, id) }
      define_singleton_method(:exist?) { |_id, state_dir: nil| true }
    end
  end

  def manager
    Class.new do
      def session_owner(_id, state_dir: nil) = nil
      def read_responses(_id, since_time: nil, state_dir: nil) = []
      def retention_sweep_if_due(state_dir: nil) = nil
    end.new
  end

  def wire(value) = JSON.parse(JSON.generate(value))

  # The worker's snapshot after +events+ (Bridge#snapshot's keys the show
  # reads): the turn in progress, the cards, a question between turns. A
  # turn that ended is drawn as the Bridge draws it live (TurnDrawings, in
  # the session's dir), as a worker's finished turn reloads.
  def snapshot(events, messages)
    drawings = Samagotchi::Bridge::TurnDrawings.new(path: File.join(state_dir, "s1", Samagotchi::Bridge::TurnDrawings::FILE),
                                                    messages: -> { messages })
    # A fixed clock: a running call's elapsed_ms is 0 on any machine.
    accumulator = Samagotchi::Bridge::TurnAccumulator.new(clock: -> { 0.0 }, on_turn_end: drawings.method(:append))
    cards = Samagotchi::Bridge::CardStore.new
    open = nil
    events.each do |event|
      accumulator.call(event)
      cards.call(event)
      open = event[:pending_question] if event[:type] == :question_requested
      open = nil if %i[question_answered question_cancelled].include?(event[:type])
    end
    current = accumulator.current_turn
    wire({ messages: messages, current_turn: current, queued: accumulator.queued, queued_commands: accumulator.queued_commands,
           continue_offer: accumulator.continue_offer, pending_question: current ? nil : open, cards: cards.list(messages: messages) })
  end

  def show_at(scenario, count)
    events = scenario[:events].first(count)
    ended = events.any? { |e| e[:type] == :turn_completed }
    # The session's messages: mid-turn the running turn's are its loop's
    # (Engine#live_conversation), not yet the session's.
    messages = ended ? [StageCutScenarios::HEAD, *scenario[:messages]] : [StageCutScenarios::HEAD]
    app = described_class.new(manager: manager, state_dir: state_dir, session_class: loader, bridge_wait_timeout: 0, markdown: false)
    allow(app).to receive(:bridge_get_json).and_call_original
    allow(app).to receive(:bridge_get_json).with("s1", "snapshot").and_return({ "snapshot" => snapshot(events, messages) })
    data = JSON.parse(app.call(Rack::MockRequest.env_for("/api/sessions/s1", "HTTP_HOST" => "127.0.0.1"))[2].first)
    data.slice("messages", "turn_drawings", "current_turn", "replay", "cards", "pending_question", "continue_offer")
  end

  StageCutScenarios.all.each do |scenario|
    it "sends #{scenario[:name]}'s show at each cut (the fixture's)" do
      fixture = wire(scenario.except(:name, :messages)).merge(
        "cuts" => scenario[:cuts].map { |cut| wire(cut).merge("show" => show_at(scenario, cut[:at])) }
      )
      path = StageCutScenarios.path(scenario[:name])
      if ENV["UPDATE_STAGE_CUTS"]
        FileUtils.mkdir_p(StageCutScenarios::DIR)
        File.write(path, "#{JSON.pretty_generate(fixture)}\n")
      else
        expect(File.exist?(path)).to be(true), "run with UPDATE_STAGE_CUTS=1 to write #{path}"
        expect(JSON.parse(File.read(path))).to eq(fixture), "run with UPDATE_STAGE_CUTS=1 to write the fixture"
      end
    end
  end

  it "shows a card waiting at every waiting cut (the cut is where the page reloads)" do
    StageCutScenarios.all.each do |scenario|
      cut = scenario[:cuts].first
      data = show_at(scenario, cut[:at])
      waits = data["pending_question"] || data["cards"].any? { |c| c["actions"]&.any? }
      expect(waits).to be_truthy, scenario[:name]
    end
  end
end
