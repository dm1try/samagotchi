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
        "current_turn" => { "prompt" => "owner's question", "origin" => { "client_id" => "web:1" },
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
                                         "queued", "last_event_id")
    expect(body["viewer"]).to include("kind" => "participant", "id" => issued.grant.id, "name" => "Alex", "can_comment" => true)
    expect(body["session"]).to eq("id" => session.id, "title" => "plan review", "status" => "running")
    expect(body["participants"]).to eq([{ "id" => issued.grant.id, "name" => "Alex", "kind" => "human" }])
    expect(body["messages"].map { |m| m["content"] }).to eq(%w[earlier ok])
    expect(body["current_turn"]).to eq("prompt" => "owner's question", "text" => "Let me check",
                                       "tools" => [{ "tool" => "execute", "status" => "running" }], "waiting_for_owner" => true)
    expect(body["waiting_for_owner"]).to be(true)
    expect(body["queued"]).to eq("mine" => [{ "enqueued_id" => "e1", "prompt" => "mine" }], "others" => 1)
    expect(body["last_event_id"]).to eq("12-ep")
    expect(JSON.generate(body)).not_to include("env?", "CARD", "owner's next", "metrics")
  end

  it "hides an automatic turn's prompt by the live worker's record, before analytics.json has it" do
    snapshot["snapshot"]["current_turn"] = nil
    snapshot["session_state_snapshot"]["metrics"] = { "turn_records" => [{ "id" => "t0", "automatic" => true }] }
    body = review(issued.token).last
    expect(body["messages"].first).to eq("role" => "user", "content" => "", "automatic" => true, "turn_id" => "t0")
  end

  it "is waiting for the owner while a Continue offer stands between turns" do
    snapshot["snapshot"]["current_turn"] = nil
    snapshot["snapshot"]["continue_offer"] = { "context" => "step limit" }
    body = review(issued.token).last
    expect([body["current_turn"], body["waiting_for_owner"]]).to eq([nil, true])
  end

  it "says a participant at their cap may not comment" do
    dir = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)
    File.write(Samagotchi::AnalyticsFile.path(dir), JSON.generate({ "turn_records" => [{ "id" => "t1", "author" => author, "cost" => 5.0 }] }))
    expect(review(issued.token).last["viewer"]).to include("can_comment" => false, "cap_reached" => true)
  end

  it "gives the owner the same filtered data as the participant view: nothing theirs, no composer" do
    issued
    status, body = review(owner_token)
    expect(status).to eq(200)
    expect(body["viewer"]).to eq("kind" => "owner", "can_comment" => false)
    expect(body["queued"]).to eq("mine" => [], "others" => 2)
    expect(body["current_turn"]).to include("prompt" => "owner's question", "text" => "Let me check")
    expect(JSON.generate(body)).not_to include("env?", "CARD")
  end
end
