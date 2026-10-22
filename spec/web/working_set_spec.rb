# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"
require "samagotchi/web/app"
require "samagotchi/session"

# GET /api/sessions/:id/working_set: the set as the model has it
# (WorkingSet), from a live worker's snapshot or the session file.
RSpec.describe Samagotchi::Web::App, "working set" do
  let(:tmpdir) { Dir.mktmpdir("web-ws") }
  let(:state_dir) { File.join(tmpdir, "samagotchi", "sessions").tap { |d| FileUtils.mkdir_p(d) } }
  let(:repo) { File.join(tmpdir, "app").tap { |d| FileUtils.mkdir_p(d) } }
  let(:path) { File.join(repo, "cart.rb").tap { |p| File.write(p, "one\n") } }
  let(:app) { described_class.new(state_dir: state_dir, session_class: Samagotchi::Session, bridge_wait_timeout: 0) }

  after { FileUtils.rm_rf(tmpdir) }

  def call(url)
    status, _headers, chunks = app.call(Rack::MockRequest.env_for(url, "HTTP_HOST" => "127.0.0.1"))
    [status, JSON.parse(chunks.to_a.join)]
  end

  def stamp
    stat = File.stat(path)
    { path: path, mtime_ns: (stat.mtime.to_i * 1_000_000_000) + stat.mtime.nsec, size: stat.size }
  end

  def read_messages(edits: nil)
    [{ role: "user", content: "go" },
     { role: "model", content: "", tool_calls: [{ id: "c1", name: "read", arguments: { "path" => "cart.rb" } }] },
     { role: "tool_response", content: "[read]\none", tool_call_id: "c1", tool_ids: ["t1"], tool_stamps: [stamp],
       edits: edits }.compact]
  end

  def saved_session(messages)
    Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: repo).tap do |s|
      s.messages.concat(messages)
      s.save(state_dir: state_dir)
    end
  end

  it "builds it from the session file without a worker, a file changed since its read stale" do
    session = saved_session(read_messages)

    status, body = call("/api/sessions/#{session.id}/working_set")
    expect(status).to eq(200)
    expect(body).to eq("items" => [{ "kind" => "file", "key" => path, "state" => "live", "tokens" => 3, "ops" => ["read"],
                                     "count" => 1, "first_id" => "t1" }],
                       "at" => 3, "running" => false)

    File.write(path, "one\ntwo\n")
    expect(call("/api/sessions/#{session.id}/working_set").last["items"].first["state"]).to eq("stale")
  end

  it "builds it from a live worker's snapshot (string keys) under the worker's strategy" do
    session = saved_session([])
    forget = { "t1" => { "kind" => "forget", "note" => "cart", "by" => "model", "staged_at" => "x", "applied_at" => "x" } }
    live_messages = JSON.parse(JSON.generate(read_messages(edits: forget)))
    allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(
      "snapshot" => { "messages" => live_messages },
      "session_state_snapshot" => { "llm_context" => { "strategy" => "forget" } }
    )

    _status, body = call("/api/sessions/#{session.id}/working_set")

    expect(body["items"]).to match([include("key" => path, "state" => "forgotten")])
    expect(body["at"]).to eq(3)
    expect(body["running"]).to be(false)
  end

  it "says when a turn runs: before the turn's first set (or from an older worker), the session's messages" do
    session = saved_session([])
    live_messages = JSON.parse(JSON.generate(read_messages))
    [{ "messages" => live_messages, "current_turn" => { "parts" => [] }, "working_set" => nil },
     { "messages" => live_messages, "current_turn" => { "parts" => [] } }].each do |snapshot|
      allow(app).to receive(:bridge_get_json).with(session.id, "snapshot")
                                             .and_return("snapshot" => snapshot, "session_state_snapshot" => {})

      _status, body = call("/api/sessions/#{session.id}/working_set")

      expect(body).to include("at" => 3, "running" => true)
      expect(body["items"]).to match([include("key" => path, "state" => "live")])
    end
  end

  it "answers the running turn's last set while a turn runs (the snapshot's messages lag it)" do
    session = saved_session([])
    turn_set = { "items" => [{ "kind" => "memory", "key" => "notes", "state" => "live", "tokens" => 9, "ops" => ["read"],
                               "count" => 1, "first_id" => "t2" }], "at" => 7 }
    allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(
      "snapshot" => { "messages" => JSON.parse(JSON.generate(read_messages)), "current_turn" => { "parts" => [] },
                      "working_set" => turn_set },
      "session_state_snapshot" => {}
    )

    _status, body = call("/api/sessions/#{session.id}/working_set")

    expect(body).to eq(turn_set.merge("running" => true))
  end

  it "builds from the messages between turns, whatever set the snapshot carries" do
    session = saved_session([])
    allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(
      "snapshot" => { "messages" => JSON.parse(JSON.generate(read_messages)), "current_turn" => nil,
                      "working_set" => { "items" => [], "at" => 9 } },
      "session_state_snapshot" => {}
    )

    _status, body = call("/api/sessions/#{session.id}/working_set")

    expect(body).to include("at" => 3, "running" => false)
    expect(body["items"]).to match([include("key" => path)])
  end

  it "is empty for a session without tool runs, and 404 for an unknown one" do
    session = saved_session([{ role: "user", content: "hi" }])

    expect(call("/api/sessions/#{session.id}/working_set")).to eq([200, { "items" => [], "at" => 1, "running" => false }])
    expect(call("/api/sessions/00000000-0000-4000-8000-000000000000/working_set").first).to eq(404)
  end
end
