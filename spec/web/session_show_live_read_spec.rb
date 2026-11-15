# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/session"
require "samagotchi/worker_link"
require_relative "../support/worker_links"

# GET /api/sessions/:id's `live_read`: "ok" when the live worker's snapshot
# came, "none" when no worker owns the session, "failed" when a live worker's
# Bridge answered with no snapshot (the debug log's record says the why and the
# elapsed ms). The page's stage_missing.js reads it, so a running session with
# nothing on its stage is not mistaken for one whose stream replayed the turn's
# end (docs/internals/web-frontend.md, "A running session without a turn").
# No real worker: the snapshot read is stubbed as the other session-show specs
# stub it.
RSpec.describe Samagotchi::Web::App, "the show's live_read" do
  include WorkerLinks

  let(:state_dir) { Dir.mktmpdir }
  let(:log_path) { File.join(state_dir, "chi.log") }

  after { FileUtils.rm_rf(state_dir) }

  def manager
    Class.new do
      def session_owner(_id, state_dir: nil) = nil
      def read_responses(_id, since_time: nil, state_dir: nil) = []
      def retention_sweep_if_due(state_dir: nil) = nil
    end.new
  end

  def loader
    Class.new do
      define_singleton_method(:load) do |_id, state_dir: nil|
        Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: "/work")
      end
      define_singleton_method(:session_dir) { |id, state_dir: nil| File.join(state_dir.to_s, id) }
      define_singleton_method(:exist?) { |_id, state_dir: nil| true }
    end
  end

  # The app with a worker that is Live on +port+ (nil: no worker at all), whose
  # snapshot GET answers [status, body] (status nil: no reply came).
  def app(status: 200, body: nil, port: 4321)
    Samagotchi::Log.configure(path: log_path, level: :debug)
    app = Samagotchi::Web::App.new(manager: manager, state_dir: state_dir, session_class: loader,
                                   bridge_wait_timeout: 0, markdown: false)
    link = if port
             live_link({ port: port, version: Samagotchi::VERSION, protocol: Samagotchi::WorkerLink::PROTOCOL })
           else
             Samagotchi::WorkerLink::None.new
           end
    allow(app).to receive(:worker_link).and_return(link)
    allow(app).to receive(:bridge_get).and_call_original
    allow(app).to receive(:bridge_get).with("s1", "snapshot").and_return([status, body])
    app
  end

  def show(app)
    status, _headers, body = app.call(Rack::MockRequest.env_for("/api/sessions/s1", "HTTP_HOST" => "127.0.0.1"))
    expect(status).to eq(200)
    JSON.parse(body.first)
  end

  def web_records(event)
    return [] unless File.exist?(log_path)

    File.open(log_path) { |io| Samagotchi::LogLine.each_record(io).select { |r| r.tag == "web" && r.event == event } }
  end

  it "says ok when the live worker's snapshot came, in one GET, and logs nothing" do
    snapshot = { "current_turn" => { "turn_id" => "t1", "prompt" => "go" } }
    app = app(status: 200, body: { "snapshot" => snapshot, "session_state_snapshot" => { "event_seq" => 7 } })
    data = show(app)

    expect(data["live_read"]).to eq("ok")
    expect(data["current_turn"]).to eq(snapshot["current_turn"])
    expect(data["last_event_seq"]).to eq(7)
    expect(app).to have_received(:bridge_get).with("s1", "snapshot").once
    expect(web_records("live_snapshot_failed")).to be_empty
  end

  it "says none when no worker owns the session, without asking the Bridge, and logs nothing" do
    app = app(port: nil)
    data = show(app)

    expect(data["live_read"]).to eq("none")
    expect(data["current_turn"]).to be_nil
    expect(app).not_to have_received(:bridge_get)
    expect(web_records("live_snapshot_failed")).to be_empty
  end

  it "says failed and logs the status, in one GET, when a live worker answers a non-200" do
    app = app(status: 500)
    data = show(app)

    expect(data["live_read"]).to eq("failed")
    expect(data["current_turn"]).to be_nil
    record = web_records("live_snapshot_failed").first
    expect(record.fields["why"]).to eq("status 500")
    expect(record.sid).to eq("s1")
    expect(record.fields["ms"].to_i).to be >= 0
    expect(app).to have_received(:bridge_get).with("s1", "snapshot").once
  end

  it "says failed and logs no reply when the Bridge never answered" do
    app = app(status: nil)
    data = show(app)

    expect(data["live_read"]).to eq("failed")
    record = web_records("live_snapshot_failed").first
    expect(record.fields["why"]).to eq("no reply")
    expect(app).to have_received(:bridge_get).with("s1", "snapshot").once
  end

  it "says failed when the Bridge answers 200 with no JSON body" do
    app = app(status: 200, body: nil)
    data = show(app)

    expect(data["live_read"]).to eq("failed")
    expect(web_records("live_snapshot_failed").first.fields["why"]).to eq("no snapshot in the answer")
    expect(app).to have_received(:bridge_get).with("s1", "snapshot").once
  end

  it "keeps a failed read's session as the file has it, without a stream cursor" do
    data = show(app(status: 503))

    expect(data["current_turn"]).to be_nil
    expect(data["replay"]).to eq([])
    expect(data["last_event_seq"]).to be_nil
    expect(data["last_event_id"]).to be_nil
    expect(data["session"]["status"]).to eq("idle")
  end
end
