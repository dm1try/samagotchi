# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/session"
require "samagotchi/analytics_file"
require "samagotchi/bridge/card_store"
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

  # The made-up lines are kept per range across shows (Synth::MEMO): each example starts with none.
  before { Samagotchi::Bridge::TurnDrawings::Synth::MEMO.clear }
  after { FileUtils.rm_rf(state_dir) }

  # A session loader whose file has +messages+ (symbol keys on top, as
  # Session.load leaves them) in +state_dir+/s1.
  def loader_for(messages)
    list = messages.map { |m| m.transform_keys(&:to_sym) }
    Class.new do
      define_singleton_method(:load) do |_id, state_dir: nil|
        Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: "/work").tap { |s| s.messages = list }
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
        # Its live lines' turns as they drew; any other turn (an earlier one
        # with no line) is made from its messages.
        expect(data["turn_drawings"].slice(*saved["drawn"].keys)).to eq(saved["drawn"])
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

  it "drops a rolled-back turn's line: what is left of it is drawn from its messages" do
    saved = fixture("tools_answer")
    write_lines(saved["lines"])

    data = show(app_for(saved["messages"].first(3)))

    expect(data["messages"].map { |m| m["drawn"] }).to eq(%w[turn-tools turn-tools])
    expect(data["messages"].none? { |m| m.key?("parts") }).to be(true)
    events = data.dig("turn_drawings", "turn-tools", "events")
    expect(events.map { |e| e["type"] }).to include("tool_call_started")
    expect(events.find { |e| e["type"] == "tool_call_completed" }).to include("tool" => "read")
  end

  it "stamps a reminder-only turn's items (no prompt of its own) apart from the turn before it, made from its messages" do
    saved = fixture("reminder_only")
    write_lines(saved["lines"])

    data = show(app_for(saved["messages"]))

    expect(data["messages"].map { |m| [m["role"], m["drawn"]] }).to eq([%w[user turn-0], %w[assistant turn-0], %w[assistant turn-reminder-only]])
    expect(data["turn_drawings"]["turn-0"]["events"].first).to include("type" => "turn_started", "prompt" => "earlier")
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

  # Every turn item of a session drawn (stamped, with its drawing sent).
  def all_drawn(data)
    turn_items = data["messages"].reject { |m| m["role"] == "note" && !m["turn_start"] }
    turn_items.all? { |m| m["drawn"] && data["turn_drawings"].key?(m["drawn"]) } && turn_items.none? { |m| m.key?("parts") }
  end

  def write_analytics(turns, tools = [])
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, Samagotchi::AnalyticsFile::NAME), JSON.generate("turn_records" => turns, "tool_records" => tools))
  end

  # +n+ turns of a prompt, a read and an answer; +ids+: whether they carry turn ids.
  def long_session(n, ids: true)
    head = [{ "role" => "system", "content" => "You are chi." }]
    head + (1..n).flat_map do |k|
      prompt = { "role" => "user", "content" => "q#{k}", "at" => TurnDrawingScenarios::AT }
      prompt["turn_id"] = "t#{k}" if ids
      [prompt,
       { "role" => "model", "content" => "", "tool_calls" => [{ "id" => "c#{k}", "name" => "read", "arguments" => %({"path":"f#{k}"}) }] },
       { "role" => "tool_response", "content" => "[read]\n#{k}", "tool_call_id" => "c#{k}" },
       { "role" => "model", "content" => "a#{k}" }]
    end
  end

  it "draws every turn of a session from before turn drawings (no file), each from its messages" do
    data = show(app_for(fixture("plain_answer")["messages"]))

    expect(all_drawn(data)).to be(true)
    expect(data["turn_drawings"].keys).to eq(["turn-plain"])
  end

  it "draws every turn of a 150-turn session, past the 100 a show drew before" do
    messages = long_session(150)
    data = show(app_for(messages))

    expect(all_drawn(data)).to be(true)
    expect(data["turn_drawings"].size).to eq(150)
    expect(data["turn_drawings"]["t1"]["events"].map { |e| e["type"] }).to include("tool_call_completed")
  end

  it "draws a one-shot session's turns (no Bridge wrote a line), with their records" do
    messages = long_session(2)
    write_analytics([{ "id" => "t1", "status" => "completed", "duration_ms" => 1200 }, { "id" => "t2", "status" => "canceled",
                                                                                         "duration_ms" => 900, "cancellation_reason" => "user" }],
                    [{ "turn_id" => "t1", "iteration" => 1, "call_index" => 1, "tool" => "read", "status" => "ok", "duration_ms" => 33 }])
    data = show(app_for(messages))

    expect(all_drawn(data)).to be(true)
    expect(data["turn_drawings"]["t1"]["end"]).to include("type" => "turn_completed", "duration_ms" => 1200, "record_id" => "t1")
    expect(data["turn_drawings"]["t2"]["end"]).to include("type" => "turn_canceled", "cancellation_reason" => "user")
    read = data["turn_drawings"]["t1"]["events"].find { |e| e["type"] == "tool_call_completed" }
    expect(read).to include("duration_ms" => 33)
  end

  it "keeps an unlined turn's in-turn hook notice, from CardStore, after a reload (H1)" do
    messages = long_session(1)
    store = Samagotchi::Bridge::CardStore.new(path: File.join(dir, Samagotchi::Bridge::CardStore::FILE))
    store.call({ type: :turn_started, turn_id: "t1" })
    store.call({ type: :generation_started, iteration: 1 })
    store.call({ type: :tool_call_started, iteration: 1, call_index: 1 })
    store.call({ type: :hook_notice, hook: "loop-guard", text: "loop: read repeated", level: :warn })
    store.call({ type: :turn_completed })

    data = show(app_for(messages))

    events = data["turn_drawings"]["t1"]["events"]
    notice = events.index { |e| e["type"] == "hook_notice" }
    expect(events[notice]).to include("hook" => "loop-guard", "text" => "loop: read repeated")
    expect(notice).to be > events.index { |e| e["type"] == "tool_call_started" }
    expect(data["cards"].find { |c| c["type"] == "hook_notice" }).to include("of_turn" => "t1")
  end

  it "pairs a session saved before turn ids with its records by place: its timing line stays (M2)" do
    write_analytics([{ "id" => "r1", "status" => "completed", "duration_ms" => 1500 }, { "id" => "r2", "status" => "completed",
                                                                                         "duration_ms" => 2500 }])
    data = show(app_for(long_session(2, ids: false)))

    expect(all_drawn(data)).to be(true)
    ends = data["turn_drawings"].values.map { |d| d["end"] }
    expect(ends.map { |e| [e["record_id"], e["duration_ms"]] }).to eq([["r1", 1500], ["r2", 2500]])
    expect(ends.none? { |e| e.key?("turn_id") }).to be(true)
  end

  it "draws every turn when the file is damaged or a turn's drawing can't be made (M6)" do
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, Samagotchi::Bridge::TurnDrawings::FILE), "{not json\n\x00\xff\n")
    expect(all_drawn(show(app_for(long_session(2))))).to be(true)

    Samagotchi::Bridge::TurnDrawings::Synth::MEMO.clear
    allow(Samagotchi::Bridge::TurnDrawings::Synth).to receive(:line).and_raise(ArgumentError, "boom")
    data = show(app_for(long_session(2)))
    expect(data["messages"].map { |m| m["drawn"] }.uniq).to eq(%w[t1 t2])
    expect(data["turn_drawings"]["t1"]["events"].map { |e| e["type"] }).to eq(%w[turn_started])
    expect(data["turn_drawings"]["t1"]["end"]).to include("type" => "turn_completed")
  end

  it "makes a repeated id's earlier turn under an id of its own: never two turns stamped as one (the re-run keeps its line)" do
    saved = fixture("repeated_id")
    write_lines(saved["lines"])
    data = show(app_for(saved["messages"]))

    expect(data["messages"].map { |m| m["drawn"] }).to eq(%w[turn-again~1 turn-again~1 turn-again turn-again])
    expect(data["turn_drawings"]["turn-again~1"]["end"]).to eq("type" => "turn_failed")
    expect(data["turn_drawings"]["turn-again"]["end"]).to include("turn_id" => "turn-again")
  end

  it "gives a turn with no turn record its saved tool records' durations" do
    write_analytics([], [{ "turn_id" => "t1", "iteration" => 1, "call_index" => 1, "tool" => "read", "status" => "ok", "duration_ms" => 77 }])
    data = show(app_for(long_session(1)))

    read = data["turn_drawings"]["t1"]["events"].find { |e| e["type"] == "tool_call_completed" }
    expect(read).to include("duration_ms" => 77)
  end

  it "never makes the running turn's drawing (its line comes at its end, L3)" do
    messages = long_session(1) + [{ "role" => "user", "content" => "now", "turn_id" => "t2" }]
    live = { "snapshot" => { "messages" => messages, "current_turn" => { "turn_id" => "t2", "prompt" => "now", "parts" => [] } } }
    data = show(app_for([], live: live))

    expect(data["messages"].map { |m| m["drawn"] }).to eq(["t1", "t1", "t1", nil])
    expect(data["turn_drawings"].keys).to eq(["t1"])
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
