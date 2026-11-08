# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/session"
require "samagotchi/bridge/turn_drawings"
require "support/turn_drawing_scenarios"

# GET /api/sessions/:id?parts=1&drawings=1: the items of a turn with a
# valid drawing are stamped (drawn: <turn_id>) and lose their parts, and
# turn_drawings carries chi web's unfold of each drawing. Without
# drawings=1 (an older page) the read is what it always was.
RSpec.describe Samagotchi::Web::App, "the show's turn drawings" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:state_dir) { Dir.mktmpdir }
  let(:dir) { File.join(state_dir, "s1") }

  after { FileUtils.rm_rf(state_dir) }

  # A session loader whose file has +messages+ (symbol keys on top, as
  # Session.load leaves them) in +state_dir+/s1.
  def loader_for(messages)
    list = messages.map { |m| m.transform_keys(&:to_sym) }
    Class.new do
      define_singleton_method(:load) do |_id, state_dir: nil|
        Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: Dir.pwd).tap { |s| s.messages = list }
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

  # +features+: the live worker's sidecar features (a worker that draws
  # names TurnDrawings::FEATURE).
  def app_for(messages, live: nil, features: [Samagotchi::Bridge::TurnDrawings::FEATURE])
    app = described_class.new(manager: manager, state_dir: state_dir, session_class: loader_for(messages), bridge_wait_timeout: 0,
                              markdown: false)
    allow(app).to receive(:bridge_get_json).and_call_original
    allow(app).to receive(:bridge_get_json).with("s1", "snapshot").and_return(live)
    allow(app).to receive(:worker_draws?).with("s1").and_return(features.include?(Samagotchi::Bridge::TurnDrawings::FEATURE))
    app
  end

  def write_lines(lines)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, Samagotchi::Bridge::TurnDrawings::FILE), lines.map { |line| "#{JSON.generate(line)}\n" }.join)
  end

  def show(app, query = "?parts=1&drawings=1")
    JSON.parse(app.call(Rack::MockRequest.env_for("/api/sessions/s1#{query}", "HTTP_HOST" => "127.0.0.1"))[2].first)
  end

  def fixture(name) = JSON.parse(File.read(TurnDrawingScenarios.path(name)))

  describe "the shared scenarios" do
    TurnDrawingScenarios.all.each do |scenario|
      it "stamps #{scenario[:name]}'s turn and sends its drawing (the fixture's show)" do
        saved = fixture(scenario[:name])
        write_lines(saved["lines"])
        data = show(app_for(saved["messages"]))
        shown = { "messages" => data["messages"], "turn_drawings" => data["turn_drawings"] }

        if ENV["UPDATE_TURN_DRAWINGS"]
          File.write(TurnDrawingScenarios.path(scenario[:name]), "#{JSON.pretty_generate(saved.merge("show" => shown))}\n")
        else
          expect(shown).to eq(saved["show"]), "run with UPDATE_TURN_DRAWINGS=1 to write the fixture"
        end
        expect(data["turn_drawings"].keys).to eq(saved["drawn"].keys)
        expect(data["turn_drawings"]).to eq(saved["drawn"])
      end
    end
  end

  it "stamps a stopped session's turn from its file, and a live worker's from its snapshot's messages" do
    saved = fixture("tools_answer")
    write_lines(saved["lines"])

    stopped = show(app_for(saved["messages"]))
    live = show(app_for([], live: { "snapshot" => { "messages" => saved["messages"] } }))

    [stopped, live].each do |data|
      expect(data["messages"].map { |m| m["drawn"] }).to eq(%w[turn-tools turn-tools turn-tools])
      expect(data["messages"].none? { |m| m.key?("parts") }).to be(true)
      expect(data["turn_drawings"].keys).to eq(["turn-tools"])
    end
  end

  # A worker from before turn drawings lists no of_turn on its cards (the
  # page would place a drawn turn's rows again): its session reads as before.
  it "draws nothing for a live worker that doesn't name turn_drawings in its features, as a stopped session's file does" do
    saved = fixture("tools_answer")
    write_lines(saved["lines"])

    old = show(app_for([], live: { "snapshot" => { "messages" => saved["messages"] } }, features: %w[restart]))

    expect(old).not_to have_key("turn_drawings")
    expect(old["messages"].none? { |m| m.key?("drawn") }).to be(true)
    expect(old["messages"][1]).to have_key("parts")
  end

  it "reads whether the live worker draws from its sidecar's features" do
    app = described_class.new(manager: manager, state_dir: state_dir, session_class: loader_for([]), bridge_wait_timeout: 0)
    sidecar = Samagotchi::WorkerSidecar.new(port: 1, features: [Samagotchi::Bridge::TurnDrawings::FEATURE])
    allow(app).to receive(:worker_link).with("s1").and_return(Samagotchi::WorkerLink::Live.new(sidecar: sidecar))
    expect(app.send(:worker_draws?, "s1")).to be(true)
    allow(app).to receive(:worker_link).with("s1").and_return(Samagotchi::WorkerLink::Live.new(sidecar: Samagotchi::WorkerSidecar.new(port: 1, features: [])))
    expect(app.send(:worker_draws?, "s1")).to be(false)
    allow(app).to receive(:worker_link).with("s1").and_return(Samagotchi::WorkerLink::None.new)
    expect(app.send(:worker_draws?, "s1")).to be(false)
  end

  it "drops a rolled-back turn: its items keep their parts and no stamp" do
    saved = fixture("tools_answer")
    write_lines(saved["lines"])

    data = show(app_for(saved["messages"].first(3)))

    expect(data["messages"].map { |m| m["drawn"] }).to eq([nil, nil])
    expect(data["messages"].last).to have_key("parts")
    expect(data).not_to have_key("turn_drawings")
  end

  it "stamps a reminder-only turn's items (no prompt of its own) and not the turn before it" do
    saved = fixture("reminder_only")
    write_lines(saved["lines"])

    data = show(app_for(saved["messages"]))

    expect(data["messages"].map { |m| [m["role"], m["drawn"]] }).to eq([["user", nil], ["assistant", nil], %w[assistant turn-reminder-only]])
  end

  it "leaves a context note inside a range unstamped (it keeps today's place)" do
    saved = fixture("continue_opener")
    line = saved["lines"].first.merge("from" => 1, "from_digest" => Samagotchi::Bridge::TurnDrawings.digest(saved["messages"][1]))
    write_lines([line])

    data = show(app_for(saved["messages"]))

    expect(data["messages"].map { |m| [m["role"], m["drawn"]] }).to eq([["note", nil], %w[user turn-continue], %w[assistant turn-continue]])
  end

  it "keeps a drawn row's ✂ mark as the item's marks, by output id" do
    saved = fixture("tools_answer")
    write_lines(saved["lines"])
    messages = saved["messages"].map(&:dup)
    messages[3] = messages[3].merge("edits" => [{ "kind" => "forget", "ids" => ["t1"], "at" => "x" }])
    allow(Samagotchi::MessageParts).to receive(:edit_marks).and_return("t1" => { "kind" => "forgot" })

    data = show(app_for(messages))

    expect(data["messages"][1]).to include("drawn" => "turn-tools", "marks" => { "t1" => { "kind" => "forgot" } })
  end

  it "has no turn_drawings without a file" do
    data = show(app_for(fixture("plain_answer")["messages"]))

    expect(data).not_to have_key("turn_drawings")
    expect(data["messages"].none? { |m| m.key?("drawn") }).to be(true)
  end

  # An open tab across the upgrade keeps its old page: it never sends
  # drawings=1, so it gets full parts, no stamps and no turn_drawings.
  it "reads without drawings=1 exactly as before: full parts, no stamps, no turn_drawings" do
    saved = fixture("tools_answer")
    before = show(app_for(saved["messages"]), "?parts=1")
    write_lines(saved["lines"])

    after = show(app_for(saved["messages"]), "?parts=1")

    # The session's own fields are the loader's new session each read.
    expect(after.except("session")).to eq(before.except("session"))
    expect(after["messages"][1]).to have_key("parts")
    expect(after).not_to have_key("turn_drawings")
    expect(show(app_for(saved["messages"]), "?drawings=1")).not_to have_key("turn_drawings")
  end

  it "parses the file once until it grows" do
    saved = fixture("tools_answer")
    write_lines(saved["lines"])
    app = app_for(saved["messages"])
    allow(Samagotchi::Bridge::TurnDrawings).to receive(:parse).and_call_original

    2.times { show(app) }

    expect(Samagotchi::Bridge::TurnDrawings).to have_received(:parse).once
  end
end
