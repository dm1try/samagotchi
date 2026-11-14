# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/grants"
require "samagotchi/participants"
require "samagotchi/analytics_file"

# A participant's GET /api/sessions/:id (the main page's show) with a live
# worker's snapshot: the turn in progress, their own queue, waiting for the
# owner, their usage. The leak cases of the read the participant page had
# (GET …/review, gone with that page), on the show.
RSpec.describe Samagotchi::Web::App, "participant reads" do
  let(:owner_token) { "t0ken-t0ken-t0ken-t0ken-t0ken-t0ken-t0ken" }
  let(:lan_ip) { "192.168.1.55" }
  let(:root) { File.realpath(Dir.mktmpdir("web-review")) }
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

  def show(bearer, query = "") = read("/api/sessions/#{session.id}#{query}", bearer)

  def read(path, bearer)
    env = Rack::MockRequest.env_for(path)
    env["HTTP_HOST"] = "#{lan_ip}:4567"
    env["REMOTE_ADDR"] = "192.168.1.20"
    env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}"
    status, _headers, chunks = app.call(env)
    [status, JSON.parse(chunks.join)]
  end

  it "gives a participant the turn so far, their own queued turns and how many others wait, and that the owner is asked" do
    status, body = show(issued.token)
    expect(status).to eq(200)
    # Invited without the pair stamp: their turns are review turns.
    expect(body["viewer"]).to include("kind" => "participant", "id" => issued.grant.id, "name" => "Alex",
                                      "mode" => "pair", "cap_reached" => false, "waiting_for_owner" => "question")
    expect(body["session"]).to include("id" => session.id, "title" => "plan review", "status" => "running",
                                       "verify_unavailable" => false, "verdicts" => [])
    expect(body["messages"].map { |m| m["content"] }).to eq(%w[earlier ok])
    expect(body["current_turn"]).to include("prompt" => "owner's question", "turn_id" => "live-1", "text" => "Let me check",
                                            "tools" => [{ "tool" => "execute", "status" => "running" }],
                                            "waiting_for_owner" => true, "kind" => "question")
    expect(body["queued"]).to eq([{ "enqueued_id" => "e1", "client_id" => "review:#{issued.grant.id}", "prompt" => "mine",
                                    "author" => author }])
    expect(body["last_event_id"]).to eq("12-ep")
    expect(JSON.generate(body)).not_to include("env?", "CARD", "owner's next", "metrics")
  end

  it "never sends a participant the owner's question, cards, recap, continue offer, commands, cost or queued prompts" do
    turn = snapshot["snapshot"]
    turn.merge!("recap" => { "text" => "RECAP-TEXT" }, "continue_offer" => { "context" => "OFFER-CONTEXT" },
                "commands" => [{ "name" => "/SECRET-COMMAND" }], "guardrail_warning" => "GUARD-WARN",
                "plugin_warning" => "PLUGIN-WARN", "init_tasks" => [{ "name" => "INIT-TASK" }],
                "objectives" => { "items" => [{ "text" => "OBJECTIVE-TEXT" }] },
                "working_set" => { "items" => [{ "kind" => "memory", "key" => "MEMORY-NAME" }], "at" => 3 })
    turn["current_turn"]["parts"] << { "kind" => "thinking", "text" => "THINKING-TEXT" }
    turn["current_turn"]["parts"] << { "kind" => "tool", "tool" => "read", "params" => "TOOL-PARAMS", "output" => "TOOL-OUT",
                                       "ref" => { "kind" => "file", "path" => "/etc/passwd" } }
    snapshot["session_state_snapshot"]["metrics"] = {
      "cost" => 9.87, "model_segments" => [{ "model" => "SEGMENT-MODEL", "cost" => 6.54 }],
      "memory_index" => { "names" => ["INDEX-MEMORY"] }, "side" => { "cost_sum" => 3.21 },
      "turn_records" => [{ "id" => "t0", "cost" => 4.32, "model" => "RECORD-MODEL" }],
      "tool_records" => [{ "id" => "r1", "guardrail" => { "judgment_id" => "JUDGMENT-ID" } }]
    }
    show(issued.token).then do |status, body|
      read = :show
      expect(status).to eq(200), read.to_s
      ["env?", "CARD", "owner's next", "RECAP-TEXT", "OFFER-CONTEXT", "SECRET-COMMAND", "GUARD-WARN", "PLUGIN-WARN", "INIT-TASK", "OBJECTIVE-TEXT", "MEMORY-NAME", "THINKING-TEXT", "TOOL-PARAMS", "TOOL-OUT", "/etc/passwd", "9.87", "6.54", "SEGMENT-MODEL", "INDEX-MEMORY", "3.21", "4.32", "RECORD-MODEL", "JUDGMENT-ID"].each do |leak|
        expect(JSON.generate(body)).not_to include(leak), "#{read}: #{leak}"
      end
    end
  end

  it "shows a filtered verdict card to participants without exposing reply metadata" do
    session.verdicts = [{
      anchor: { turn_id: "123e4567-e89b-12d3-a456-426614174000", quote: "claim" },
      verdict: "confirmed", reason: "supported", by: author,
      check_turn_id: "123e4567-e89b-12d3-a456-426614174001", at: "now", private: "secret"
    }]
    session.save(state_dir: state_dir)

    body = show(issued.token).last

    expect(body.dig("session", "verdicts")).to eq([{
      "anchor" => { "turn_id" => "123e4567-e89b-12d3-a456-426614174000", "quote" => "claim" },
      "verdict" => "confirmed", "reason" => "supported", "by" => author,
      "check_turn_id" => "123e4567-e89b-12d3-a456-426614174001"
    }])
    expect(JSON.generate(body)).not_to include("private", "secret", '"at":"now"')
  end

  it "hides an automatic turn's prompt by the live worker's record, before analytics.json has it" do
    snapshot["snapshot"]["current_turn"] = nil
    snapshot["session_state_snapshot"]["metrics"] = { "turn_records" => [{ "id" => "t0", "automatic" => true }] }
    body = show(issued.token).last
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
    body = show(issued.token).last
    expect(body["messages"].map { |m| m.slice("role", "content", "automatic", "turn_id") }).to eq([
      { "role" => "user", "content" => "earlier", "turn_id" => "t0" }, { "role" => "assistant", "content" => "ok" },
      { "role" => "user", "content" => "", "automatic" => true, "turn_id" => "t1" },
      { "role" => "assistant", "content" => "child done" },
      { "role" => "user", "content" => "", "automatic" => true, "turn_id" => "t2" },
      { "role" => "assistant", "content" => "noted" }
    ])
    expect(JSON.generate(body)).not_to include("CHILD REPORT", "DEPLOY FROZEN", "slack")
  end

  it "renders markdown only for the replies it sends, from their redacted text: never the dropped report's" do
    renderer = instance_double(Samagotchi::Web::MarkdownRenderer, available?: true)
    allow(renderer).to receive(:render) { |text| "<p>#{text}</p>" }
    app.instance_variable_set(:@markdown_renderer, renderer)
    snapshot["snapshot"]["current_turn"] = nil
    snapshot["snapshot"]["messages"] = [
      { "role" => "user", "kind" => "input", "source" => "delegate_report", "turn_start" => true, "turn_id" => "t1",
        "content" => "## CHILD REPORT" },
      { "role" => "model", "content" => "child done" }
    ]
    body = show(issued.token).last
    expect(renderer).to have_received(:render).with("child done").at_least(:once)
    expect(renderer).not_to have_received(:render).with(include("CHILD REPORT"))
    expect(body["messages"].map { |m| m["html"] }).to eq([nil, "<p>child done</p>"])
  end

  it "is waiting for the owner while a Continue offer stands between turns" do
    snapshot["snapshot"]["current_turn"] = nil
    snapshot["snapshot"]["continue_offer"] = { "context" => "step limit" }
    body = show(issued.token).last
    expect([body["current_turn"], body.dig("viewer", "waiting_for_owner")]).to eq([nil, "continue"])
  end

  it "shows idle when the worker says running but no turn is active" do
    snapshot["snapshot"]["current_turn"] = nil
    expect(show(issued.token).last.dig("session", "status")).to eq("idle")
  end

  it "says a participant is at their cap" do
    dir = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)
    File.write(Samagotchi::AnalyticsFile.path(dir), JSON.generate({ "turn_records" => [{ "id" => "t1", "author" => author, "cost" => 5.0 }] }))
    expect(show(issued.token).last["viewer"]).to include("cap_reached" => true)
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
      usage = show(issued.token).last.dig("viewer", "usage")
      expect(usage).to eq("spent" => 0.5, "cap" => 2.0, "queued" => 1, "queue_limit" => 3,
                          "expires_at" => issued.grant.expires_at, "model" => "m")
    end

    it "counts their running turn from the live worker, never adding the saved spend it already holds" do
      snapshot["session_state_snapshot"]["metrics"] = { "cost" => 9.0, "spend_by_author" => {
        author => { "turns" => 1, "cost" => 0.875 }, other.author => { "turns" => 1, "cost" => 4.0 }
      } }
      snapshot["session_state_snapshot"]["model_name"] = "live-model"
      usage = show(issued.token).last.dig("viewer", "usage")
      expect(usage).to include("spent" => 0.875, "model" => "live-model")
    end

    it "keeps the saved spend when the worker counts less (no turn of theirs in it yet), and reads it without a worker" do
      snapshot["session_state_snapshot"]["metrics"] = { "spend_by_author" => { other.author => { "cost" => 4.0 } } }
      expect(show(issued.token).last.dig("viewer", "usage", "spent")).to eq(0.5)

      allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(nil)
      usage = show(issued.token).last.dig("viewer", "usage")
      expect(usage).to include("spent" => 0.5, "queue_limit" => 3, "model" => "m")
      expect(usage).not_to have_key("queued")
    end

    it "shows a level this chi doesn't know as its own, the narrowest" do
      store = JSON.parse(File.read(grants.path))
      store["grants"].find { |row| row["id"] == issued.grant.id }["exposure"] = "session"
      File.write(grants.path, JSON.generate(store))
      expect(grants.find(issued.grant.id).exposure).to eq("session")
      usage = show(issued.token).last.dig("viewer", "usage")
      expect(usage.keys).to eq(%w[spent cap queued queue_limit expires_at model])
    end
  end

  # A dev server that logs request headers may print the owner's
  # 127.0.0.1 cookie (the loopback value) into a tool's output.
  it "never shows the owner's token or its loopback cookie value to a participant" do
    loopback = Samagotchi::Web::Token.loopback_cookie(owner_token)
    snapshot["snapshot"]["current_turn"]["parts"] << { "kind" => "text", "text" => "seen #{loopback} and #{owner_token}" }
    _status, body = show(issued.token)
    expect(body.dig("current_turn", "text")).to include("seen")
    expect(JSON.generate(body)).not_to include(loopback, owner_token)
  end

  it "names every participant pair, whatever worker holds the session" do
    pair = Samagotchi::Participants.invite(grants, session_id: session.id, name: "Sam", state_dir: state_dir)
    _status, body = show(pair.token)
    expect(body["viewer"]).to include("mode" => "pair")
  end
end
