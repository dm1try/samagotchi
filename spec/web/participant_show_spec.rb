# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/grants"
require "samagotchi/participants"
require "samagotchi/analytics_file"

# A participant's GET /api/sessions/:id (Web::ParticipantShow): the main
# page's read in the owner's shape, every value filtered. The leaks of
# both reads (this and /review) are participant_review_spec's and
# participant_red_team_spec's.
RSpec.describe Samagotchi::Web::App, "a participant's show" do
  let(:owner_token) { "t0ken-t0ken-t0ken-t0ken-t0ken-t0ken-t0ken" }
  let(:lan_ip) { "192.168.1.55" }
  let(:root) { File.realpath(Dir.mktmpdir("web-participant-show")) }
  let(:state_dir) { File.join(root, "samagotchi", "sessions") }
  let(:grants) { Samagotchi::Grants.new(Samagotchi::Grants.path(state_dir: state_dir)) }
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
  let(:client_id) { "review:#{issued.grant.id}" }
  let(:snapshot) do
    { "snapshot" => {
        "messages" => [{ "role" => "user", "content" => "earlier", "turn_id" => "t0" },
                       { "role" => "model", "content" => "ok" }],
        "current_turn" => { "prompt" => "owner's question", "turn_id" => "live-1", "origin" => { "client_id" => "web:1" },
                            "generation" => { "thinking_only" => true, "age" => 2.5, "model" => "SECRET-GEN" },
                            "parts" => [{ "kind" => "text", "text" => "Let me check", "iteration" => 1 },
                                        { "kind" => "tool", "tool" => "read", "params" => "TOOL-PARAMS", "status" => "running",
                                          "iteration" => 1, "call_index" => 0,
                                          "ref" => { "kind" => "file", "path" => File.join(root, "docs", "plan.md"), "line" => 3 } }] },
        "queued" => [{ "enqueued_id" => "e1", "client_id" => client_id, "prompt" => "mine", "author" => author,
                       "delivery" => "queue", "images" => [{ "file" => "IMAGE-FILE" }] },
                     { "enqueued_id" => "e2", "client_id" => "web:1", "prompt" => "owner's next" }],
        "event_id" => "12-ep"
      },
      "session_state_snapshot" => {
        "status" => "running", "event_seq" => 12,
        "metrics" => { "turn_records" => [{ "id" => "t0", "started_at" => "2026-11-13T10:00:00Z", "duration_ms" => 1200,
                                            "decode_tps" => 42.0, "tps_source" => "server", "cost" => 4.32,
                                            "model" => "RECORD-MODEL", "author" => "p:other", "cancellation_reason" => "x" }],
                       "tool_records" => [{ "id" => "r1", "guardrail" => { "judgment_id" => "JUDGMENT-ID" } }],
                       "active_turn" => { "id" => "live-1", "started_at" => "2026-11-13T10:01:00Z", "duration_ms" => 900,
                                          "model" => "ACTIVE-MODEL" },
                       "context" => { "used_tokens" => 1800, "window_tokens" => 10_000, "source" => "SOURCE-X" },
                       "tokens" => { "cost" => 9.87 }, "model_segments" => [{ "cost" => 6.54 }],
                       "memory_index" => { "names" => ["INDEX-MEMORY"] }, "side" => { "cost_sum" => 3.21 } }
      } }
  end
  # The keys a participant's show may have that the owner's has not: the
  # viewer's own fields beside Viewer's, and the verdicts'.
  let(:extra_top) { %w[fresh_running] }
  let(:extra_session) { %w[verify_unavailable] }

  before { allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(snapshot) }

  after { FileUtils.remove_entry(root) }

  def read(bearer, query = "")
    env = Rack::MockRequest.env_for("/api/sessions/#{session.id}#{query}")
    env["HTTP_HOST"] = "#{lan_ip}:4567"
    env["REMOTE_ADDR"] = "192.168.1.20"
    env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}"
    status, _headers, chunks = app.call(env)
    [status, JSON.parse(chunks.join)]
  end

  it "has the owner's keys and no other but the verdicts'; nothing a participant never gets has a value" do
    _status, owner = read(owner_token)
    status, body = read(issued.token)
    expect(status).to eq(200)
    expect(body.keys - owner.keys).to match_array(extra_top)
    expect(owner.keys - body.keys - %w[objectives turn_drawings]).to eq([])
    expect(body["session"].keys - owner["session"].keys).to match_array(extra_session)
    %w[history queued_commands init_tasks cards commands].each { |key| expect(body[key]).to eq([]), key }
    %w[failed_turn recap saved_recap continue_offer guardrail_warning plugin_warning pending_question editor_url].each do |key|
      expect(body[key]).to be_nil, key
    end
  end

  it "gives the conversation, the turn so far and the replay through ParticipantView" do
    body = read(issued.token).last
    expect(body["messages"].map { |m| m["content"] }).to eq(%w[earlier ok])
    expect(body["current_turn"]).to eq("prompt" => "owner's question", "turn_id" => "live-1", "text" => "Let me check",
                                       "generation" => { "thinking_only" => true, "age" => 2.5 },
                                       "tools" => [{ "tool" => "read", "path" => "docs/plan.md", "status" => "running",
                                                     "ref" => { "kind" => "file", "path" => "docs/plan.md", "line" => 3 } }])
    types = body["replay"].map { |event| event["type"] }
    expect(types).to eq(%w[turn_started generation_chunk generation_completed tool_call_started turn_enqueued turn_enqueued])
    expect(body["replay"][3]).to include("tool" => "read", "ref" => { "kind" => "file", "path" => "docs/plan.md", "line" => 3 })
    # The viewer's own queued turn as the owner's replay has it; the owner's next one bare.
    expect(body["replay"][4]).to eq("type" => "turn_enqueued", "enqueued_id" => "e1", "client_id" => client_id,
                                    "prompt" => "mine", "author" => author, "delivery" => "queue")
    expect(body["replay"][5]).to eq("type" => "turn_enqueued")
    expect(body["last_event_id"]).to eq("12-ep")
    expect(body["last_event_seq"]).to eq(12)
    expect(JSON.generate(body)).not_to include("TOOL-PARAMS", "SECRET-GEN", root)
  end

  it "lists the viewer's own queued turns in the owner's shape, never another's prompt or an image" do
    body = read(issued.token).last
    expect(body["queued"]).to eq([{ "enqueued_id" => "e1", "client_id" => client_id, "prompt" => "mine", "author" => author,
                                    "delivery" => "queue" }])
    expect(JSON.generate(body)).not_to include("owner's next", "IMAGE-FILE")
  end

  it "names the viewer: kind, id, name, can, client id, mode, cap and usage, and whether the session is stopped" do
    viewer = read(issued.token).last["viewer"]
    expect(viewer).to include("kind" => "participant", "id" => issued.grant.id, "name" => "Alex", "client_id" => client_id,
                              "can" => Samagotchi::Web::Viewer::PARTICIPANT_CAPABILITIES, "mode" => "review",
                              "cap_reached" => false, "session_stopped" => false, "participant_kind" => "human")
    expect(viewer["usage"]).to include("spent" => 0.0, "cap" => 2.0, "queued" => 1, "queue_limit" => 3)
    expect(viewer["can"] & Samagotchi::Web::Viewer::CAPABILITIES).to eq(%w[working_set])
  end

  it "says what the session waits for the owner on: the running turn's approval, a Continue offer, a question between turns" do
    expect(read(issued.token).last.dig("viewer", "waiting_for_owner")).to be_nil
    snapshot["snapshot"]["current_turn"]["pending_question"] = { "kind" => "approval", "question" => "Allow execute: APPROVAL-CMD?" }
    body = read(issued.token).last
    expect(body.dig("viewer", "waiting_for_owner")).to eq("approval")
    expect(body["current_turn"]).to include("waiting_for_owner" => true, "kind" => "approval")
    expect(JSON.generate(body)).not_to include("APPROVAL-CMD")
    snapshot["snapshot"]["current_turn"] = nil
    snapshot["snapshot"]["continue_offer"] = { "context" => "OFFER-CONTEXT" }
    expect(read(issued.token).last.dig("viewer", "waiting_for_owner")).to eq("continue")
    snapshot["snapshot"].delete("continue_offer")
    snapshot["snapshot"]["pending_question"] = { "kind" => "continue", "question" => "Go on?" }
    expect(read(issued.token).last.dig("viewer", "waiting_for_owner")).to eq("continue")
  end

  it "keeps each turn's duration and speed of the timing, nothing else" do
    timing = read(issued.token).last["timing"]
    expect(timing["turn_records"]).to eq([{ "id" => "t0", "started_at" => "2026-11-13T10:00:00Z", "duration_ms" => 1200,
                                            "decode_tps" => 42.0, "tps_source" => "server" }])
    expect(timing["active_turn"]).to eq("id" => "live-1", "started_at" => "2026-11-13T10:01:00Z", "duration_ms" => 900)
    expect(timing["context"]).to eq("used_tokens" => 1800, "window_tokens" => 10_000)
    expect(timing.values_at("tool_records", "active_tools", "model_segments")).to eq([[], [], []])
    expect(timing.values_at("tokens", "memory_index", "side")).to eq([nil, nil, nil])
    # Never sent: cost, model, author, a cancel's reason, guardrail judgments, memory names, side requests' cost.
    %w[4.32 RECORD-MODEL p:other cancellation_reason JUDGMENT-ID ACTIVE-MODEL SOURCE-X 9.87 6.54 INDEX-MEMORY 3.21].each do |leak|
      expect(JSON.generate(timing)).not_to include(leak), leak
    end
  end

  it "re-reads lightly in the owner's shape: tail, timing, cards; brief as SessionAccess::Remote#show reads it" do
    allow(app).to receive(:bridge_get_json).with(session.id, "state").and_return(snapshot.slice("session_state_snapshot"))
    status, tail = read(issued.token, "?tail=1")
    expect(status).to eq(200)
    expect(tail.keys).to match_array(%w[tail session messages markdown_warning markdown_tip capabilities editor_url timing])
    expect(tail["messages"].map { |m| m["content"] }).to eq(["ok"])
    expect(tail.dig("timing", "turn_records", 0).keys).to eq(%w[id started_at duration_ms decode_tps tps_source])
    expect(read(issued.token, "?timing=1").last["timing"]["turn_records"].first).not_to have_key("cost")
    expect(read(issued.token, "?cards=1").last).to eq("cards" => [])
    expect(read(issued.token, "?brief=1").last["session"].keys).to eq(%w[id title status participants])
  end

  it "makes a valid show from an older worker's snapshot (no generation, no event id) and without a worker" do
    snapshot["snapshot"].delete("event_id")
    snapshot["snapshot"]["current_turn"].delete("generation")
    snapshot["session_state_snapshot"].delete("metrics")
    status, body = read(issued.token)
    expect(status).to eq(200)
    expect(body["current_turn"]).not_to have_key("generation")

    allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(nil)
    status, body = read(issued.token)
    expect([status, body["current_turn"], body["replay"], body["queued"]]).to eq([200, nil, [], []])
    expect(body.dig("session", "bridge_up")).to be(false)
  end

  it "reads the working set (GET …/working_set) with the project's files only, relative" do
    snapshot["snapshot"]["working_set"] = {
      "items" => [{ "kind" => "file", "key" => File.join(root, "lib", "a.rb"), "state" => "live", "tokens" => 20, "ops" => ["read"],
                    "count" => 1, "first_id" => "FIRST-ID", "pinned" => false, "has_drop" => false },
                  { "kind" => "memory", "key" => "MEMORY-NAME", "state" => "live" }], "at" => 4
    }
    env = Rack::MockRequest.env_for("/api/sessions/#{session.id}/working_set")
    env["HTTP_HOST"] = "#{lan_ip}:4567"
    env["REMOTE_ADDR"] = "192.168.1.20"
    env["HTTP_AUTHORIZATION"] = "Bearer #{issued.token}"
    status, _headers, chunks = app.call(env)
    expect([status, JSON.parse(chunks.join)]).to eq([200, {
      "items" => [{ "kind" => "file", "key" => "lib/a.rb", "state" => "live", "ops" => ["read"], "pinned" => false,
                    "tokens" => 20, "count" => 1 }], "at" => 4, "running" => true
    }])
  end

  # Phase C serves index.html to a participant with these; today their
  # link still opens the participant page (participant_shell).
  it "stamps the main page's <body> for a participant with nothing of the owner's machine" do
    session.working_directory = File.join(root, "secret-project")
    session.save(state_dir: state_dir)
    env = Rack::MockRequest.env_for("/?dir=#{root}&from=#{root}")
    env[described_class::PRINCIPAL_ENV] = Samagotchi::Web::Principal.new(kind: :participant, grant: issued.grant)
    attrs = app.send(:index_data_attributes, Rack::Request.new(env))
    keys = attrs.scan(/data-([a-z-]+)=/).flatten
    expect(keys).to contain_exactly("version", "session", "session-title", "annotate-presets", "viewer-kind", "viewer-can")
    expect(attrs).to include(%(data-session="#{session.id}"), %(data-session-title="plan review"), %(data-viewer-kind="participant"))
    expect(attrs).not_to include(root, Dir.home, "secret-project")
  end

  it "leaves the owner's show as it was: no client id on the owner's viewer" do
    expect(read(owner_token).last["viewer"]).to eq("kind" => "owner", "id" => nil, "name" => nil,
                                                   "can" => Samagotchi::Web::Viewer::CAPABILITIES)
  end
end
