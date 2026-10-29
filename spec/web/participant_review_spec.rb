# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/web/grants"
require "samagotchi/participants"
require "samagotchi/analytics_file"

# GET /api/sessions/:id/review, the participant page's data, with a live
# worker's snapshot: the turn in progress, the queue as a participant sees
# it, waiting for the owner; and the owner's participant view of the same.
RSpec.describe Samagotchi::Web::App, "participant review" do
  let(:owner_token) { "t0ken-t0ken-t0ken-t0ken-t0ken-t0ken-t0ken" }
  let(:lan_ip) { "192.168.1.55" }
  let(:root) { File.realpath(Dir.mktmpdir("web-review")) }
  let(:state_dir) { File.join(root, "samagotchi", "sessions") }
  let(:grants) { Samagotchi::Web::Grants.new(Samagotchi::Web::Grants.path(state_dir: state_dir)) }
  let(:app) do
    described_class.new(state_dir: state_dir, bridge_wait_timeout: 0, grants: grants, lan: { ip: lan_ip, token: owner_token })
  end
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: root).tap do |s|
      s.title = "plan review"
      s.save(state_dir: state_dir)
      FileUtils.mkdir_p(Samagotchi::Session.session_dir(s.id, state_dir: state_dir))
    end
  end
  let(:issued) { Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex", state_dir: state_dir) }
  let(:author) { issued.grant.author }
  let(:snapshot) do
    { "snapshot" => {
        "messages" => [{ "role" => "user", "content" => "earlier", "turn_id" => "t0" }, { "role" => "model", "content" => "ok" }],
        "current_turn" => { "prompt" => "owner's question", "turn_id" => "live-1", "origin" => { "client_id" => "web:1" },
                            "pending_question" => { "question" => "Allow execute: env?" },
                            "parts" => [{ "kind" => "text", "text" => "Let me check" },
                                        { "kind" => "tool", "tool" => "execute", "params" => "env", "status" => "running" }] },
        "queued" => [{ "enqueued_id" => "e1", "client_id" => "review:#{issued.grant.id}", "prompt" => "mine", "author" => author },
                     { "enqueued_id" => "e2", "client_id" => "web:1", "prompt" => "owner's next" }],
        "cards" => [{ "type" => "card", "body" => "CARD" }], "event_id" => "12-ep"
      },
      "session_state_snapshot" => { "status" => "running", "participants" => [{ "id" => "p_x" }], "metrics" => { "cost" => 1 } } }
  end

  before { allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(snapshot) }

  after { FileUtils.remove_entry(root) }

  def review(bearer)
    env = Rack::MockRequest.env_for("/api/sessions/#{session.id}/review")
    env["HTTP_HOST"] = "#{lan_ip}:4567"
    env["REMOTE_ADDR"] = "192.168.1.20"
    env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}"
    status, _headers, chunks = app.call(env)
    [status, JSON.parse(chunks.join)]
  end

  it "gives a participant the turn so far, their own queued turns and how many others wait, and that the owner is asked" do
    status, body = review(issued.token)
    expect(status).to eq(200)
    expect(body.keys).to contain_exactly("viewer", "session", "participants", "messages", "current_turn", "waiting_for_owner",
                                         "queued", "last_event_id", "subjects", "verdicts", "fresh_running")
    expect(body["subjects"]).to eq([])
    # Invited without the pair stamp: their turns are review turns.
    expect(body["viewer"]).to include("kind" => "participant", "id" => issued.grant.id, "name" => "Alex",
                                      "mode" => "review", "can_comment" => true)
    expect(body["session"]).to eq("id" => session.id, "title" => "plan review", "status" => "running",
                                  "verify_unavailable" => false)
    expect(body["participants"]).to eq([{ "id" => issued.grant.id, "name" => "Alex", "kind" => "human" }])
    expect(body["messages"].map { |m| m["content"] }).to eq(%w[earlier ok])
    expect(body["current_turn"]).to eq("prompt" => "owner's question", "turn_id" => "live-1", "text" => "Let me check",
                                       "tools" => [{ "tool" => "execute", "status" => "running" }], "waiting_for_owner" => true)
    expect(body["waiting_for_owner"]).to be(true)
    expect(body["queued"]).to eq("mine" => [{ "enqueued_id" => "e1", "prompt" => "mine" }], "others" => 1)
    expect(body["last_event_id"]).to eq("12-ep")
    expect(body["verdicts"]).to eq([])
    expect(JSON.generate(body)).not_to include("env?", "CARD", "owner's next", "metrics")
  end

  it "shows a filtered verdict card to participants without exposing reply metadata" do
    session.verdicts = [{
      anchor: { turn_id: "123e4567-e89b-12d3-a456-426614174000", quote: "claim" },
      verdict: "confirmed", reason: "supported", by: author,
      check_turn_id: "123e4567-e89b-12d3-a456-426614174001", at: "now", private: "secret"
    }]
    session.save(state_dir: state_dir)

    body = review(issued.token).last

    expect(body["verdicts"]).to eq([{
      "anchor" => { "turn_id" => "123e4567-e89b-12d3-a456-426614174000", "quote" => "claim" },
      "verdict" => "confirmed", "reason" => "supported", "by" => author,
      "check_turn_id" => "123e4567-e89b-12d3-a456-426614174001"
    }])
    expect(JSON.generate(body)).not_to include("private", "secret", '"at"')
  end

  it "hides an automatic turn's prompt by the live worker's record, before analytics.json has it" do
    snapshot["snapshot"]["current_turn"] = nil
    snapshot["session_state_snapshot"]["metrics"] = { "turn_records" => [{ "id" => "t0", "automatic" => true }] }
    body = review(issued.token).last
    expect(body["messages"].first).to eq("role" => "user", "content" => "", "automatic" => true, "turn_id" => "t0")
  end

  it "opens a wake turn with its boundary, never the delegate report's or the context note's text" do
    snapshot["snapshot"]["current_turn"] = nil
    snapshot["snapshot"]["messages"] = [
      { "role" => "user", "content" => "earlier", "turn_id" => "t0" }, { "role" => "model", "content" => "ok" },
      { "role" => "user", "kind" => "input", "source" => "delegate_report", "turn_start" => true, "turn_id" => "t1",
        "content" => "CHILD REPORT" },
      { "role" => "model", "content" => "child done" },
      Samagotchi::ContextNote.message(note_id: "n1", text: "DEPLOY FROZEN", source: "slack", turn_start: true,
                                      turn_id: "t2").transform_keys(&:to_s),
      { "role" => "model", "content" => "noted" }
    ]
    body = review(issued.token).last
    expect(body["messages"].map { |m| m.slice("role", "content", "automatic", "turn_id") }).to eq([
      { "role" => "user", "content" => "earlier", "turn_id" => "t0" }, { "role" => "assistant", "content" => "ok" },
      { "role" => "user", "content" => "", "automatic" => true, "turn_id" => "t1" },
      { "role" => "assistant", "content" => "child done" },
      { "role" => "user", "content" => "", "automatic" => true, "turn_id" => "t2" },
      { "role" => "assistant", "content" => "noted" }
    ])
    expect(JSON.generate(body)).not_to include("CHILD REPORT", "DEPLOY FROZEN", "slack")
  end

  it "is waiting for the owner while a Continue offer stands between turns" do
    snapshot["snapshot"]["current_turn"] = nil
    snapshot["snapshot"]["continue_offer"] = { "context" => "step limit" }
    body = review(issued.token).last
    expect([body["current_turn"], body["waiting_for_owner"]]).to eq([nil, true])
  end

  it "shows idle when the worker says running but no turn is active" do
    snapshot["snapshot"]["current_turn"] = nil
    expect(review(issued.token).last.dig("session", "status")).to eq("idle")
  end

  it "says a participant at their cap may not comment" do
    dir = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)
    File.write(Samagotchi::AnalyticsFile.path(dir), JSON.generate({ "turn_records" => [{ "id" => "t1", "author" => author, "cost" => 5.0 }] }))
    expect(review(issued.token).last["viewer"]).to include("can_comment" => false, "cap_reached" => true)
  end

  describe "a participant's usage (the exposure policy's own level)" do
    let(:other) { Samagotchi::Participants.invite(grants, session_id: session.id, name: "Sam", state_dir: state_dir).grant }
    let(:dir) { Samagotchi::Session.session_dir(session.id, state_dir: state_dir) }

    before do
      File.write(Samagotchi::AnalyticsFile.path(dir), JSON.generate({ "turn_records" => [
        { "id" => "t1", "author" => author, "cost" => 0.5 },
        { "id" => "t2", "author" => other.author, "cost" => 1.25 },
        { "id" => "t3", "cost" => 7.0 }
      ] }))
      snapshot["snapshot"]["queued"] << { "enqueued_id" => "e3", "prompt" => "Sam's", "author" => other.author }
    end

    it "is their own spend, cap, queued turns, queue limit, link expiry and the model: nobody else's" do
      usage = review(issued.token).last.dig("viewer", "usage")
      expect(usage).to eq("spent" => 0.5, "cap" => 2.0, "queued" => 1, "queue_limit" => 3,
                          "expires_at" => issued.grant.expires_at, "model" => "m")
    end

    it "counts their running turn from the live worker, never adding the saved spend it already holds" do
      snapshot["session_state_snapshot"]["metrics"] = { "cost" => 9.0, "spend_by_author" => {
        author => { "turns" => 1, "cost" => 0.875 }, other.author => { "turns" => 1, "cost" => 4.0 }
      } }
      snapshot["session_state_snapshot"]["model_name"] = "live-model"
      usage = review(issued.token).last.dig("viewer", "usage")
      expect(usage).to include("spent" => 0.875, "model" => "live-model")
    end

    it "keeps the saved spend when the worker counts less (no turn of theirs in it yet), and reads it without a worker" do
      snapshot["session_state_snapshot"]["metrics"] = { "spend_by_author" => { other.author => { "cost" => 4.0 } } }
      expect(review(issued.token).last.dig("viewer", "usage", "spent")).to eq(0.5)

      allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(nil)
      usage = review(issued.token).last.dig("viewer", "usage")
      expect(usage).to include("spent" => 0.5, "queue_limit" => 3, "model" => "m")
      expect(usage).not_to have_key("queued")
    end

    it "shows a level this chi doesn't know as its own, the narrowest" do
      store = JSON.parse(File.read(grants.path))
      store["grants"].find { |row| row["id"] == issued.grant.id }["exposure"] = "session"
      File.write(grants.path, JSON.generate(store))
      expect(grants.find(issued.grant.id).exposure).to eq("session")
      usage = review(issued.token).last.dig("viewer", "usage")
      expect(usage.keys).to eq(%w[spent cap queued queue_limit expires_at model])
    end
  end

  it "gives the owner the same filtered data as the participant view: nothing theirs, no composer" do
    issued
    status, body = review(owner_token)
    expect(status).to eq(200)
    expect(body["viewer"]).to eq("kind" => "owner", "can_comment" => false, "mode" => "pair")
    expect(body["queued"]).to eq("mine" => [], "others" => 2)
    expect(body["current_turn"]).to include("prompt" => "owner's question", "text" => "Let me check")
    expect(JSON.generate(body)).not_to include("env?", "CARD")
  end

  # A dev server that logs request headers may print the owner's
  # 127.0.0.1 cookie (the loopback value) into a tool's output.
  it "never shows the owner's token or its loopback cookie value to a participant" do
    loopback = Samagotchi::Web::Token.loopback_cookie(owner_token)
    snapshot["snapshot"]["current_turn"]["parts"] << { "kind" => "text", "text" => "seen #{loopback} and #{owner_token}" }
    _status, body = review(issued.token)
    expect(body.dig("current_turn", "text")).to include("seen")
    expect(JSON.generate(body)).not_to include(loopback, owner_token)
  end

  it "names a participant invited to act pair, and review again while an older worker holds the session" do
    pair = Samagotchi::Participants.invite(grants, session_id: session.id, name: "Sam", mode: "pair", state_dir: state_dir)
    _status, body = review(pair.token)
    expect(body["viewer"]).to include("mode" => "pair")
    sidecar = Samagotchi::WorkerSidecar.new(port: 1, session_id: session.id, features: %w[delivery review_turns])
    allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(Samagotchi::WorkerLink::Live.new(sidecar: sidecar))
    _status, body = review(pair.token)
    expect(body["viewer"]).to include("mode" => "review")
  end

  it "names the mode review for a working session whose live worker predates pair turns" do
    issued
    sidecar = Samagotchi::WorkerSidecar.new(port: 1, session_id: session.id, features: %w[delivery review_turns])
    allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(Samagotchi::WorkerLink::Live.new(sidecar: sidecar))
    _status, body = review(owner_token)
    expect(body["viewer"]).to include("mode" => "review")
  end
end
