# frozen_string_literal: true

require "spec_helper"
require "json"
require "rack/mock"
require "tmpdir"
require "samagotchi/bridge_client"
require "samagotchi/plugin/context"
require "samagotchi/session"
require "samagotchi/terminal_ui/local_link"
require "samagotchi/web/app"
require "samagotchi/worker_link"
require_relative "../../script/release/compat_wire"

# What another chi version's worker answered its clients (the corpus's
# wire/: GET state, snapshot and tail after a turn, a snapshot mid-turn with
# a prompt queued; CompatWire), read by today's clients: chi web's show and
# its light re-reads, the working set read, BridgeClient#event_seq, the
# attached terminal's /stats fallback, a plugin's ctx.sessions read. Each
# reply is served as recorded through a BridgeClient whose get_response
# answers from the files (an unrecorded route: an older worker's 404).
RSpec.describe "the recorded wire samples" do
  let(:compat_root) { __dir__ }
  # The last release whose corpus has no wire/: a later one must hold it.
  let(:wire_after) { Gem::Version.new("0.165.0") }
  let(:id) { CompatWire::SESSION_ID }

  # A Bridge's replies as +dir+ recorded them, by route.
  class WireCorpusClient < Samagotchi::BridgeClient
    def initialize(dir, routes)
      super(session_id: CompatWire::SESSION_ID, port: 0, secret: nil)
      @dir = dir
      @routes = routes
    end

    def get_response(path)
      route = path.split("?", 2).first
      name = @routes[route]
      return Response.new(status: 404, body: JSON.generate(error: "not_found", path: route)) unless name

      reply = JSON.parse(File.read(File.join(@dir, name)))
      Response.new(status: reply.fetch("status"), body: JSON.generate(reply.fetch("body")))
    end
  end

  def idle_routes = CompatWire::IDLE_ROUTES.invert
  def running_routes = CompatWire::RUNNING_ROUTES.invert

  # The newest corpus before the current version (as readers_spec picks it).
  def corpus_version
    versions = Dir.children(compat_root).select { |name| File.directory?(File.join(compat_root, name)) && Gem::Version.correct?(name) }
    current = Gem::Version.new(Samagotchi::VERSION)
    previous = versions.select { |version| Gem::Version.new(version) < current }
    candidates = previous.empty? ? versions.select { |version| Gem::Version.new(version) <= current } : previous
    candidates.max_by { |version| Gem::Version.new(version) }
  end

  def app_on(dir)
    Samagotchi::Web::App.new(state_dir: File.join(dir, "sessions"), session_class: Samagotchi::Session, bridge_wait_timeout: 0)
  end

  def show(app, client, query = "")
    allow(app).to receive(:bridge_client).with(id).and_return(client)
    status, _headers, chunks = app.call(Rack::MockRequest.env_for("/api/sessions/#{id}#{query}", "HTTP_HOST" => "127.0.0.1"))
    expect(status).to eq(200), chunks.to_a.join
    JSON.parse(chunks.to_a.join)
  end

  def recorded(dir, name) = JSON.parse(File.read(File.join(dir, name)))

  def texts(items) = items.map { |item| item["content"] || item["text"] }

  # Every reader of the samples in +dir+ (a copy: chi web may write beside
  # the session file), as +version+ recorded them.
  def expect_wire_read(dir, version)
    expect(recorded(dir, "snapshot.json").dig("body", "snapshot", "chi_version")).to eq(version)
    idle = WireCorpusClient.new(dir, idle_routes)
    running = WireCorpusClient.new(dir, running_routes)
    expect_show_read(dir, idle, running)
    expect_light_reads(dir, idle)
    expect_working_set_read(dir, idle, running)
    expect_client_reads(dir, idle)
    expect_plugin_read(dir, idle, running)
  end

  # (a) The full show, idle and mid-turn.
  def expect_show_read(dir, idle, running)
    seq = recorded(dir, "snapshot.json").dig("body", "snapshot", "event_seq")
    body = show(app_on(dir), idle)
    expect(body).to include("last_event_seq" => seq, "last_event_id" => "#{seq}-#{CompatWire::EPOCH}", "current_turn" => nil,
                            "replay" => [], "queued" => [])
    expect(body["session"]).to include("id" => id, "status" => "idle")
    expect(texts(body["messages"])).to include(CompatWire::PROMPT, CompatWire::ANSWER)
    expect(body["cards"]).to match([include("type" => "hook_notice", "hook" => "compat", "text" => "compatibility corpus")])
    expect(body["timing"]["turn_records"].map { |turn| turn["id"] }).to include(CompatWire::TURN_ID)
    expect(body["turn_drawings"].keys).to eq([CompatWire::TURN_ID])

    seq = recorded(dir, "snapshot_running.json").dig("body", "snapshot", "event_seq")
    body = show(app_on(dir), running)
    expect(body).to include("last_event_seq" => seq, "last_event_id" => "#{seq}-#{CompatWire::EPOCH}")
    expect(body["session"]).to include("status" => "running")
    expect(body["current_turn"]).to include("turn_id" => CompatWire::RUNNING_TURN_ID, "prompt" => "#{CompatWire::PROMPT} again")
    expect(body["queued"]).to match([include("enqueued_id" => CompatWire::ENQUEUED_ID, "prompt" => CompatWire::QUEUED_PROMPT)])
    replay = body["replay"]
    expect(replay.first).to include("type" => "turn_started", "turn_id" => CompatWire::RUNNING_TURN_ID)
    expect(replay).to include(include("type" => "tool_call_completed", "tool" => "read", "tool_id" => "compat-t1"))
    expect(replay.last).to include("type" => "turn_enqueued", "enqueued_id" => CompatWire::ENQUEUED_ID)
    # The running turn has no line yet: only the finished one is drawn.
    expect(body["turn_drawings"].keys).to eq([CompatWire::TURN_ID])
  end

  # (b) ?tail=1, from GET tail and from an older worker's snapshot; (c) ?timing=1 from GET state.
  def expect_light_reads(dir, idle)
    tail = show(app_on(dir), idle, "?tail=1&turn_id=#{CompatWire::TURN_ID}")
    expect(tail).to include("tail" => true)
    expect(tail["session"]).to include("id" => id, "status" => "idle")
    expect(texts(tail["messages"])).to eq([CompatWire::ANSWER])
    expect(tail["timing"]["turn_records"].map { |turn| turn["id"] }).to eq([CompatWire::TURN_ID])

    older = WireCorpusClient.new(dir, idle_routes.except("tail"))
    expect(texts(show(app_on(dir), older, "?tail=1")["messages"])).to eq([CompatWire::ANSWER])
    expect(show(app_on(dir), idle, "?cards=1")["cards"]).to match([include("type" => "hook_notice", "text" => "compatibility corpus")])

    timing = show(app_on(dir), idle, "?timing=1")["timing"]
    expect(timing["turn_records"].map { |turn| turn["id"] }).to eq([CompatWire::TURN_ID])
    expect(timing["tool_records"].map { |tool| tool["tool"] }).to eq(["read"])
  end

  # (d) The working set: the running turn's (the snapshot's working_set), the idle one built from the messages.
  def expect_working_set_read(dir, idle, running)
    file = "#{CompatWire::CWD}/README.md"
    set = show(app_on(dir), running, "/working_set")
    expect(set).to include("running" => true)
    expect(set["items"]).to match([include("kind" => "file", "key" => file, "ops" => ["read"])])

    set = show(app_on(dir), idle, "/working_set")
    expect(set).to include("running" => false)
    expect(set["items"]).to match([include("kind" => "file", "key" => file)])
  end

  # (e) BridgeClient#event_seq (GET state) and the attached terminal's /stats
  # from GET state (no stats recorded: a worker from before the route).
  def expect_client_reads(dir, idle)
    expect(idle.event_seq).to eq(recorded(dir, "state.json").dig("body", "session_state_snapshot", "event_seq"))
    link = Samagotchi::TerminalUI::LocalLink.new(client: idle, state_dir: File.join(dir, "sessions"))
    expect(link.stats_metrics).to include("turns" => 1, "tool_calls_total" => 1)
  end

  # (f) A plugin's ctx.sessions read of a live session, idle and mid-turn.
  def expect_plugin_read(dir, idle, running)
    state_dir = File.join(dir, "sessions")
    host = Samagotchi::Plugin::Host.new(session_id: -> { "compat-reader" }, cwd: -> { dir }, model_name: -> { "compat:model" },
                                        state_dir: -> { state_dir })
    sessions = Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {}, host: host).sessions

    allow(Samagotchi::WorkerLink).to receive(:client).and_return(idle)
    read = sessions.read(id)
    expect(read).to include(id: id, running: false)
    expect(read[:messages].map { |message| message[:content] }).to eq([CompatWire::PROMPT, "Reading.", "[read]\ncompat", CompatWire::ANSWER])

    allow(Samagotchi::WorkerLink).to receive(:client).and_return(running)
    read = sessions.read(id)
    expect(read).to include(running: true)
    expect(read[:messages].map { |message| message[:content] }.last(2)).to eq(["#{CompatWire::PROMPT} again", "Reading."])
  end

  def copy(source)
    Dir.mktmpdir("chi-compat-wire-").tap { |tmp| FileUtils.cp_r(File.join(source, "."), tmp) }
  end

  it "reads the newest previous release's wire samples with today's clients" do
    version = corpus_version
    source = File.join(compat_root, version, "wire")
    unless File.directory?(source)
      expect(Gem::Version.new(version)).to be <= wire_after, "#{version}'s corpus has no wire/"
      skip "#{version}'s corpus is from before wire samples (#{wire_after} and before)"
    end

    dir = copy(source)
    expect_wire_read(dir, version)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "reads the wire samples the recorder records now (the next release's)" do
    Dir.mktmpdir("chi-compat-wire-now-") do |dir|
      CompatWire.record!(dir, version: Samagotchi::VERSION)
      expect_wire_read(dir, Samagotchi::VERSION)
    end
  end
end
