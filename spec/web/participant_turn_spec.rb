# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/grants"
require "samagotchi/participants"
require "samagotchi/prompt_history"
require "samagotchi/session_manager"
require "samagotchi/analytics_file"
require "samagotchi/participant_uploads"
require "samagotchi/participant_prompts"
require "samagotchi/image_store"
require "samagotchi/vision_support"

# POST /api/sessions/:id/turn and …/turn/:eid/dequeue from a participant:
# a turn whose author and client id are the grant's, queued or at the next
# step of their own running turn (the worker decides), never a cut, with
# no shell line, command or image, nothing in the owner's prompt history,
# and every answer audited.
RSpec.describe Samagotchi::Web::App, "a participant's turn" do
  let(:owner_token) { "t0ken-t0ken-t0ken-t0ken-t0ken-t0ken-t0ken" }
  let(:lan_ip) { "192.168.1.55" }
  let(:root) { Dir.mktmpdir("web-participant-turn") }
  let(:state_dir) { File.join(root, "samagotchi", "sessions") }
  let(:grants) { Samagotchi::Grants.new(Samagotchi::Grants.path(state_dir: state_dir)) }
  let(:app) do
    described_class.new(state_dir: state_dir, bridge_wait_timeout: 0, grants: grants, lan: { ip: lan_ip, token: owner_token })
  end
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: root).tap do |s|
      s.save(state_dir: state_dir)
      FileUtils.mkdir_p(Samagotchi::Session.session_dir(s.id, state_dir: state_dir))
    end
  end
  let(:issued) { Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex", state_dir: state_dir) }
  let(:grant) { issued.grant }
  let(:delivered) { [] }
  let(:accepted) do
    Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :bridge,
                                                  ack: { "status" => "accepted", "enqueued_id" => "e-#{delivered.size}",
                                                         "session_id" => session.id })
  end

  before do
    allow(Samagotchi::SessionManager).to receive(:deliver_turn) do |_id, **kwargs|
      delivered << kwargs
      accepted
    end
    allow(Samagotchi::PromptHistory).to receive(:append)
  end

  after { FileUtils.remove_entry(root) }

  def call(path, body: nil, method: "POST", token: issued.token)
    env = Rack::MockRequest.env_for(path, method: method, input: body ? JSON.generate(body) : nil,
                                          "CONTENT_TYPE" => "application/json")
    env["HTTP_HOST"] = "#{lan_ip}:4567"
    env["REMOTE_ADDR"] = "192.168.1.20"
    env["HTTP_AUTHORIZATION"] = "Bearer #{token}"
    status, _headers, chunks = app.call(env)
    [status, JSON.parse(chunks.join)]
  end

  def turn(body) = call("/api/sessions/#{session.id}/turn", body: body)

  def audit = File.readlines(File.join(Samagotchi::Session.session_dir(session.id, state_dir: state_dir), "participants.jsonl"))
                  .map { |line| JSON.parse(line) }.select { |line| line["event"] == "turn" }

  it "stamps the author and client id from the grant, whatever the body says; the delivery the body's queue or next step" do
    status, body = turn({ prompt: "Is step 3 safe?", client_id: "cli:answer", author: "owner", delivery: "queue",
                          no_interrupt: true })

    expect(status).to eq(202)
    # A file (no delivery in the worker's ack) reads as a queue.
    expect(body).to include("status" => "accepted", "delivery" => "queue")
    expect(delivered.first).to include(prompt: "Is step 3 safe?", client_id: "participant:#{grant.id}", author: grant.author,
                                       delivery: "queue", pending_limit: 4)
    expect(delivered.first).not_to include(no_interrupt: true)
    expect(delivered.first).not_to have_key(:images)
    expect(Samagotchi::PromptHistory).not_to have_received(:append)
    expect(audit.map { |line| line.slice("participant", "status", "enqueued_id", "chars") })
      .to eq([{ "participant" => grant.id, "status" => "accepted", "enqueued_id" => "e-1", "chars" => 15 }])
  end

  # Pick 1 (R3, Q2): a participant restarts no session its owner stopped;
  # the refusal is passed through, audited. (An archive revokes the grant
  # first: token_revoked.)
  it "refuses a turn to a stopped session (409), starting nothing, audited" do
    allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_call_original
    allow(Samagotchi::SessionManager).to receive(:resume_session)
    Samagotchi::Session.mark_stopped(session.id, state_dir: state_dir)

    expect(turn({ prompt: "still there?" })).to eq([409, Samagotchi::SessionManager::DeliverResult::STOPPED])
    expect(Samagotchi::Session.stopped_marker?(session.id, state_dir: state_dir)).to be(true)
    expect(Samagotchi::SessionManager).not_to have_received(:resume_session)
    expect(audit.map { |line| line["reason"] }).to eq(%w[session_stopped])
  end

  it "passes a valid verify anchor but silently drops a malformed one" do
    verify = { turn_id: "123e4567-e89b-12d3-a456-426614174000", quote: "the claim" }

    expect(turn({ prompt: "check", verify: verify }).first).to eq(202)
    expect(delivered.last[:anchors].verify).to eq(Samagotchi::VerifyAnchor.new(**verify))

    expect(turn({ prompt: "check", verify: { turn_id: "bad", quote: "the claim" } }).first).to eq(202)
    expect(delivered.last[:anchors]).to be_empty
  end

  describe "a Revise draft (ParticipantRevise)" do
    let(:own) { "123e4567-e89b-12d3-a456-426614174001" }
    let(:owners) { "123e4567-e89b-12d3-a456-426614174002" }
    let(:history) do
      [{ role: "user", content: "Say pong", turn_id: owners }, { role: "assistant", content: "pong" },
       { role: "user", content: "Is step 3 safe?", turn_id: own, author: grant.author }, { role: "assistant", content: "Yes, long" }]
    end
    let(:messages) { Samagotchi::ParticipantMessages }

    def save(list)
      session.messages = list
      session.save(state_dir: state_dir)
    end

    # A live worker: its features, and the snapshot's messages (string keys).
    def live(features, snapshot_messages = nil)
      allow(Samagotchi::WorkerLink).to receive(:live_features).and_return(features)
      return unless snapshot_messages

      snapshot = { "snapshot" => { "messages" => JSON.parse(JSON.generate(snapshot_messages)) } }
      allow(app).to receive(:bridge_get_json).and_call_original
      allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(snapshot)
    end

    it "delivers a Revise of their own answer with its draft, keeping their Verify claim; the audit line names it" do
      save(history)
      verify = { turn_id: "123e4567-e89b-12d3-a456-426614174000", quote: "the claim" }

      expect(turn({ prompt: "shorter", verify: verify, revises: { turn_id: own } }).first).to eq(202)
      expect(delivered.last[:anchors]).to eq(Samagotchi::TurnAnchors.new(verify: verify, revises: { turn_id: own }))
      expect(audit.last.values_at("status", "revises")).to eq(["accepted", own])
    end

    it "refuses one of the owner's answer and one of no turn with the same 403 revise_not_own, audited" do
      save(history)
      [owners, "123e4567-e89b-12d3-a456-426614174999"].each do |turn_id|
        expect(turn({ prompt: "shorter", revises: { turn_id: turn_id } }))
          .to eq([403, { "error" => "revise_not_own", "detail" => messages::REVISE_NOT_OWN }])
      end
      expect(delivered).to eq([])
      expect(audit.map { |line| line.values_at("reason", "revises") })
        .to eq([["revise_not_own", owners], %w[revise_not_own 123e4567-e89b-12d3-a456-426614174999]])
    end

    it "refuses one someone else's turn came after (409 revise_overtaken)" do
      save(history + [{ role: "user", content: "next", turn_id: "o2" }, { role: "assistant", content: "ok" }])
      expect(turn({ prompt: "shorter", revises: { turn_id: own } }))
        .to eq([409, { "error" => "revise_overtaken", "detail" => messages::REVISE_OVERTAKEN }])
      expect(delivered).to eq([])
    end

    it "refuses one to a live worker without participant_revise in the participant's words (409 revise_unavailable)" do
      save(history)
      live([Samagotchi::ReviseAnchor::FEATURE])
      expect(turn({ prompt: "shorter", revises: { turn_id: own } }))
        .to eq([409, { "error" => "revise_unavailable", "detail" => messages::REVISE_UNAVAILABLE }])
      expect(delivered).to eq([])
    end

    it "reads a live worker's snapshot, not the file: an answer not saved yet is theirs to revise" do
      save(history.first(3))
      live([Samagotchi::ReviseAnchor::FEATURE, Samagotchi::ReviseAnchor::PARTICIPANT_FEATURE], history)
      expect(turn({ prompt: "shorter", revises: { turn_id: own } }).first).to eq(202)
      expect(delivered.last[:anchors].revises).to eq(Samagotchi::ReviseAnchor.new(turn_id: own))
    end

    it "gives a worker without Revise at all the participant's words, never ReviseAnchor::UNAVAILABLE's" do
      save(history)
      refused = Samagotchi::SessionManager::DeliverResult.new(status: :refused, via: :bridge, code: 409,
                                                              ack: Samagotchi::ReviseAnchor::UNAVAILABLE)
      allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return(refused)
      status, body = turn({ prompt: "shorter", revises: { turn_id: own } })
      expect([status, body]).to eq([409, { "error" => "revise_unavailable", "detail" => messages::REVISE_UNAVAILABLE }])
      expect(body["detail"]).not_to eq(Samagotchi::ReviseAnchor::UNAVAILABLE["detail"])
    end

    it "checks the cap first (429 cap_reached), before any Revise check" do
      dir = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)
      record = { "id" => "t1", "author" => grant.author, "cost" => 9.0 }
      File.write(Samagotchi::AnalyticsFile.path(dir), JSON.generate({ "turn_records" => [record] }))
      expect(turn({ prompt: "shorter", revises: { turn_id: owners } }).first).to eq(429)
      expect(audit.last.values_at("reason", "revises")).to eq(["cap_reached", owners])
    end

    it "keeps the images' ownership on a Revise (403 not_permitted for an image not theirs)" do
      save(history)
      dir = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)
      png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==".unpack1("m")
      ref = Samagotchi::ImageStore.ingest(dir, bytes: png, name: "owner.png")
      expect(turn({ prompt: "shorter", revises: { turn_id: own }, images: [{ file: ref[:file], name: "owner.png" }] }))
        .to eq([403, { "error" => "not_permitted", "detail" => messages::NOT_PERMITTED }])
      expect(delivered).to eq([])
    end
  end

  it "refuses a shell line and a command (403 not_permitted), audited, never delivered" do
    ["!ls", "  /toolkit full", "/title mine"].each do |line|
      expect(turn({ prompt: line })).to eq([403, { "error" => "not_permitted", "detail" => Samagotchi::Participants::NOT_PERMITTED }])
    end
    expect(delivered).to eq([])
    expect(audit.map { |line| line.values_at("status", "reason") }).to all(eq(%w[refused not_permitted]))
    expect(audit.size).to eq(3)
  end

  describe "with images" do
    let(:dir) { Samagotchi::Session.session_dir(session.id, state_dir: state_dir) }
    let(:png) { "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==".unpack1("m") }
    let(:yes) { Samagotchi::VisionSupport::Answer.new(value: true, reason: "the model card says so") }
    let(:no) { Samagotchi::VisionSupport::Answer.new(value: false, reason: "models: sets vision: false") }

    before { allow(Samagotchi::SendCommand).to receive(:vision_answer).and_return(yes) }

    # An image in the session's store (+name+ its bytes' tag), +grant_id+'s when given.
    def stored(tag, grant_id: nil)
      ref = Samagotchi::ImageStore.ingest(dir, bytes: png + tag, name: "#{tag}.png")
      Samagotchi::ParticipantUploads.add(dir, file: ref[:file], grant_id: grant_id) if grant_id
      { file: ref[:file], name: "#{tag}.png" }
    end

    it "delivers their own uploads with the turn; the audit line counts them" do
      mine = stored("mine", grant_id: grant.id)
      expect(turn({ prompt: "look", images: [mine] }).first).to eq(202)
      expect(delivered.last[:images]).to eq([mine])
      expect(audit.last.values_at("status", "images")).to eq(["accepted", 1])
    end

    it "refuses an image they didn't upload with the same 403, whether its file is there or not, before any file check" do
      owners = stored("owner")
      theirs = stored("bo", grant_id: "p_bbbbbbbb")
      missing = { file: "images/0123456789abcdef.png", name: "x.png" }
      mine = stored("mine", grant_id: grant.id)
      [[owners], [theirs], [missing], [mine, owners], [{ file: owners[:file], name: "x", source: "participant" }]].each do |images|
        expect(turn({ prompt: "look", images: images }))
          .to eq([403, { "error" => "not_permitted", "detail" => Samagotchi::ParticipantMessages::NOT_PERMITTED }])
      end
      expect(delivered).to eq([])
    end

    it "refuses a body that isn't a list of at most 20 {file, name} refs (400 bad_images), a path too" do
      mine = stored("mine", grant_id: grant.id)
      ["x", [1], [{ name: "a" }], [mine.merge(path: "/etc/passwd")], Array.new(21) { mine }].each do |images|
        expect(turn({ prompt: "look", images: images }).first(1)).to eq([400]), images.to_s[0, 40]
      end
      expect(delivered).to eq([])
    end

    it "refuses an owned image whose file is gone in their own words (400 bad_images), the file named only in the audit" do
      mine = stored("mine", grant_id: grant.id)
      File.delete(File.join(dir, mine[:file]))
      expect(turn({ prompt: "look", images: [mine] }))
        .to eq([400, { "error" => "bad_images", "detail" => Samagotchi::ParticipantMessages::IMAGE_GONE }])
      expect(audit.last["detail"]).to include(mine[:file])
    end

    it "says the shape in its own words, as many refs as ImageStore takes" do
      expect(Samagotchi::ParticipantMessages::IMAGES_SHAPE).to include("at most #{Samagotchi::ImageStore::MAX_TURN_REFS} ")
      expect(turn({ prompt: "look", images: "x" }))
        .to eq([400, { "error" => "bad_images", "detail" => Samagotchi::ParticipantMessages::IMAGES_SHAPE }])
    end

    it "counts the images in a refused delivery's audit line too" do
      refused = Samagotchi::SessionManager::DeliverResult.new(status: :refused, via: :bridge, code: 429,
                                                              ack: { "error" => "too_many_turns" })
      allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return(refused)
      expect(turn({ prompt: "look", images: [stored("mine", grant_id: grant.id)] }).first).to eq(429)
      expect(audit.last.values_at("status", "reason", "images")).to eq(["refused", "too_many_turns", 1])
    end

    it "refuses images to a model that can't take them in their own words (422 no_vision); the full refusal only in the audit" do
      allow(Samagotchi::SendCommand).to receive(:vision_answer).and_return(no)
      mine = stored("mine", grant_id: grant.id)
      expect(turn({ prompt: "look", images: [mine] }))
        .to eq([422, { "error" => "no_vision", "detail" => Samagotchi::ParticipantMessages::NO_VISION }])
      expect(audit.last.values_at("status", "reason")).to eq(%w[refused no_vision])
      expect(audit.last["detail"]).to eq("m can't take images (models: sets vision: false); send text only or switch the model (/model)")
      expect(turn({ prompt: "text only" }).first).to eq(202)
    end
  end

  it "refuses a turn once the grant spent its cap (429 cap_reached), from the saved analytics" do
    dir = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)
    record = { "id" => "t1", "author" => grant.author, "cost" => 1.5, "cost_estimate" => 0.25 }
    side = { "requests" => 1, "by_author" => { grant.author => { "requests" => 1, "cost_sum" => 0.25 } } }
    File.write(Samagotchi::AnalyticsFile.path(dir), JSON.generate({ "turn_records" => [record], "side" => side }))

    expect(turn({ prompt: "one more" })).to eq([429, { "error" => "cap_reached",
                                                       "detail" => Samagotchi::ParticipantMessages::CAP_REACHED }])
    expect(delivered).to eq([])
    expect(audit.last.values_at("status", "reason")).to eq(%w[refused cap_reached])

    Samagotchi::Participants.set_cap(grants, session_id: session.id, id: grant.id, cap: 5, state_dir: state_dir)
    expect(turn({ prompt: "one more" }).first).to eq(202)
  end

  it "passes the Bridge's 429 too_many_turns through, audited" do
    allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return(
      Samagotchi::SessionManager::DeliverResult.new(status: :refused, code: 429,
                                                    ack: { "error" => "too_many_turns",
                                                           "detail" => Samagotchi::ParticipantMessages::TOO_MANY_TURNS })
    )
    expect(turn({ prompt: "one more" })).to eq([429, { "error" => "too_many_turns",
                                                       "detail" => Samagotchi::ParticipantMessages::TOO_MANY_TURNS }])
    expect(audit.last.values_at("status", "reason")).to eq(%w[refused too_many_turns])
  end

  it "sends a message without a delivery at the next step, the ack saying what the worker says will happen" do
    accepted.ack["delivery"] = "next_step"
    expect(turn({ prompt: "only step 3" })).to match([202, include("delivery" => "next_step")])
    expect(delivered.last).to include(delivery: "next_step", author: grant.author)
    accepted.ack["delivery"] = "queue"
    expect(turn({ prompt: "and then", delivery: "next_step" })).to match([202, include("delivery" => "queue")])
  end

  it "refuses a cut (403 not_permitted), audited: a participant's message never cuts a turn" do
    expect(turn({ prompt: "stop thinking", delivery: "cut" }))
      .to eq([403, { "error" => "not_permitted", "detail" => Samagotchi::Participants::NOT_PERMITTED }])
    expect(delivered).to eq([])
    expect(audit.map { |line| line.slice("status", "reason") }).to eq([{ "status" => "refused", "reason" => "not_permitted" }])
  end

  it "sends the owner's turn as before: the body's client id, its delivery, the history" do
    env = Rack::MockRequest.env_for("/api/sessions/#{session.id}/turn", method: "POST",
                                                                        input: JSON.generate({ prompt: "go", client_id: "web:t", delivery: "cut" }))
    env["HTTP_HOST"] = "127.0.0.1:4567"
    env["REMOTE_ADDR"] = "127.0.0.1"
    env["HTTP_AUTHORIZATION"] = "Bearer #{owner_token}"
    expect(app.call(env).first).to eq(202)
    expect(delivered.first).to include(client_id: "web:t", delivery: "cut", author: nil)
    expect(Samagotchi::PromptHistory).to have_received(:append).with("go")
  end

  describe "their own prompts (ParticipantPrompts, the list their ↑ walks)" do
    let(:dir) { Samagotchi::Session.session_dir(session.id, state_dir: state_dir) }

    def own = Samagotchi::ParticipantPrompts.entries(dir, grant.id)

    it "records an accepted turn under the grant, whatever author or client id the body names; never the owner's history" do
      expect(turn({ prompt: "A-1", author: "p:p_bbbbbbbb", client_id: "participant:p_bbbbbbbb" }).first).to eq(202)
      expect(turn({ prompt: "A-2", delivery: "queue" }).first).to eq(202)

      expect(own).to eq(%w[A-1 A-2])
      expect(Samagotchi::ParticipantPrompts.entries(dir, "p_bbbbbbbb")).to eq([])
      expect(Samagotchi::PromptHistory).not_to have_received(:append)
    end

    it "records nothing for a send chi web refuses, one with history: false, a worker refusal, a timeout or a failure" do
      turn({ prompt: "!ls" })
      turn({ prompt: "/model x" })
      turn({ prompt: "cut it", delivery: "cut" })
      expect(turn({ prompt: "image only", history: false }).first).to eq(202)
      allow(Samagotchi::SessionManager).to receive(:deliver_turn)
        .and_return(Samagotchi::SessionManager::DeliverResult.new(status: :refused, code: 429, ack: { "error" => "too_many_turns" }),
                    Samagotchi::SessionManager::DeliverResult.new(status: :timeout, ack: { "detail" => "slow" }),
                    Samagotchi::SessionManager::DeliverResult.new(status: :failed))
      expect(turn({ prompt: "too many" }).first).to eq(429)
      expect(turn({ prompt: "timed out" }).first).to eq(504)
      expect(turn({ prompt: "failed" }).first).to eq(500)

      expect(own).to eq([])
    end

    it "still answers 202 when the record can't be written, and delivers an over-long prompt without recording it" do
      long = "x" * (Samagotchi::ParticipantPrompts::MAX_ENTRY_BYTES + 1)
      expect(turn({ prompt: long }).first).to eq(202)
      expect(delivered.last[:prompt]).to eq(long)
      expect(own).to eq([])

      allow(Samagotchi::ParticipantPrompts).to receive(:append).and_raise(Errno::EACCES)
      expect(turn({ prompt: "kept going" }).first).to eq(202)
    end
  end

  describe "dequeue" do
    let(:bridge) { instance_double(Samagotchi::BridgeClient) }

    before do
      allow(app).to receive(:bridge_client).and_return(bridge)
      allow(bridge).to receive(:dequeue).and_return(
        Samagotchi::BridgeClient::Response.new(status: 200, body: '{"status":"removed","prompt":"x"}')
      )
    end

    it "takes back the participant's own queued turn, as theirs" do
      turn({ prompt: "mine" })
      status, = call("/api/sessions/#{session.id}/turn/e-1/dequeue", body: { client_id: "web:owner" })
      expect(status).to eq(200)
      expect(bridge).to have_received(:dequeue).with(enqueued_id: "e-1", client_id: "participant:#{grant.id}")
    end

    it "refuses another author's queued turn (403 not_permitted), whatever the body says" do
      other = Samagotchi::Participants.invite(grants, session_id: session.id, name: "Kim", state_dir: state_dir)
      call("/api/sessions/#{session.id}/turn", body: { prompt: "kim's" }, token: other.token)

      expect(call("/api/sessions/#{session.id}/turn/e-1/dequeue", body: { client_id: "participant:#{other.grant.id}" }).first).to eq(403)
      expect(call("/api/sessions/#{session.id}/turn/owner-eid/dequeue").first).to eq(403)
      expect(bridge).not_to have_received(:dequeue)
    end

    it "knows a turn by its waiting file's author after chi web restarted" do
      dir = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)
      Samagotchi::SessionInbox.write_input(dir, prompt: "mine", client_id: "participant:#{grant.id}", enqueued_id: "e-old",
                                                author: grant.author, delivery: "queue")
      Samagotchi::SessionInbox.write_input(dir, prompt: "owner's", client_id: "web:o", enqueued_id: "e-owner", delivery: "queue")

      expect(call("/api/sessions/#{session.id}/turn/e-old/dequeue").first).to eq(200)
      expect(call("/api/sessions/#{session.id}/turn/e-owner/dequeue").first).to eq(403)
    end
  end

  # A chi web restarted while their turn is claimed or after it ended (a
  # fresh App, nothing in memory) knows it as theirs from the session's
  # files: the claimed input file's author, then last_turn's or the settled
  # record's. Another grant's turn stays 403.
  describe "their wait after chi web restarted" do
    let(:dir) { Samagotchi::Session.session_dir(session.id, state_dir: state_dir) }
    let(:other) { Samagotchi::Participants.invite(grants, session_id: session.id, name: "Kim", state_dir: state_dir) }

    def wait_on(eid, token: issued.token)
      call("/api/sessions/#{session.id}/wait", body: { turn: eid, timeout: 0.05 }, token: token)
    end

    def prepare(eid, token: issued.token) = call("/api/sessions/#{session.id}/wait/prepare", body: { turn: eid }, token: token)

    it "knows their claimed, running turn by the claimed file's author" do
      file = Samagotchi::SessionInbox.write_input(dir, prompt: "mine", client_id: "participant:#{grant.id}", enqueued_id: "e-run",
                                                       author: grant.author, delivery: "queue")
      Samagotchi::SessionInbox.claim_input_file(file)
      session.status = Samagotchi::Session::STATUS_RUNNING
      session.interrupted_turn = Samagotchi::InterruptedTurn.new(enqueued_id: "e-run")
      session.save(state_dir: state_dir)

      status, body = prepare("e-run")
      expect([status, body["known_turn"]]).to eq([200, true])
      expect(prepare("e-run", token: other.token).first).to eq(403)
    end

    it "reads their ended turn's outcome from last_turn, and a refused one's from its settled record" do
      session.last_turn = Samagotchi::LastTurn.new(outcome: "failed", ended_at: "2026-10-26T10:00:00Z", enqueued_id: "e-done",
                                                   author: grant.author)
      session.save(state_dir: state_dir)
      Samagotchi::TurnCheckpoint.record_refused(dir, "e-refused", reason: "cap_reached", author: grant.author)

      expect(prepare("e-done")).to eq([200, { "session_id" => session.id, "baseline" => { "last_turn" => "2026-10-26T10:00:00Z" },
                                              "known_turn" => true,
                                              "live" => false, "last_turn_id" => "e-done" }])
      expect(wait_on("e-done").last.slice("status", "outcome")).to eq("status" => "no_reply", "outcome" => "failed")
      expect(wait_on("e-refused").last.slice("status", "outcome", "cancel_reason"))
        .to eq("status" => "no_reply", "outcome" => "canceled", "cancel_reason" => "cap_reached")
      expect([prepare("e-done", token: other.token).first, wait_on("e-refused", token: other.token).first]).to eq([403, 403])
    end

    it "knows their turn whose worker died by its settled worker_stopped record's author" do
      session.interrupted_turn = Samagotchi::InterruptedTurn.new(enqueued_id: "e-died", author: grant.author)
      Samagotchi::TurnCheckpoint.settle(session, session_dir: dir)
      session.save(state_dir: state_dir)

      expect(wait_on("e-died").last.slice("status", "outcome", "cancel_reason"))
        .to eq("status" => "no_reply", "outcome" => "canceled", "cancel_reason" => "worker_stopped")
      expect([prepare("e-died").first, wait_on("e-died", token: other.token).first]).to eq([200, 403])
    end

    it "keeps an owner's ended turn the owner's (403)" do
      session.last_turn = Samagotchi::LastTurn.new(outcome: "completed", ended_at: "2026-10-26T10:00:00Z",
                                                   enqueued_id: "e-owner")
      session.save(state_dir: state_dir)

      expect([prepare("e-owner").first, wait_on("e-owner").first]).to eq([403, 403])
    end
  end

  describe "resolve and wait (an agent participant's send --wait)" do
    let(:access) { instance_double(Samagotchi::SessionAccess::Local) }
    let(:start) do
      Samagotchi::SessionAccess::WaitStart.new(cursor: "c1", baseline: Samagotchi::ReplyWait::Baseline.new(messages: 2),
                                               own_turn: true, known_turn: true, running: false, live: true,
                                               settled: false, last_turn_id: nil)
    end

    before do
      allow(app).to receive(:session_access).and_return(access)
      allow(access).to receive(:show).and_return(session)
      allow(access).to receive(:prepare_wait).and_return(start)
    end

    def get(path)
      env = Rack::MockRequest.env_for(path)
      env["HTTP_HOST"] = "#{lan_ip}:4567"
      env["REMOTE_ADDR"] = "192.168.1.20"
      env["HTTP_AUTHORIZATION"] = "Bearer #{issued.token}"
      status, _headers, chunks = app.call(env)
      [status, JSON.parse(chunks.join)]
    end

    it "resolves only the grant's session, by its id or a prefix; anything else is no session" do
      expect(get("/api/sessions/resolve?id=#{session.id[0, 8]}")).to eq([200, { "id" => session.id }])
      expect(get("/api/sessions/resolve?id=#{session.id}")).to eq([200, { "id" => session.id }])
      expect(get("/api/sessions/resolve?id=ffffffff")).to eq([404, { "error" => "not_found", "detail" => "no session ffffffff" }])
      expect(get("/api/sessions/resolve?id=a").first).to eq(404) unless session.id.start_with?("a")
    end

    it "prepares and waits only on a turn of theirs, the answer trimmed to their reply" do
      turn({ prompt: "Is step 3 safe?" })
      result = Samagotchi::ReplyWait::Result.new(status: :done, text: "Yes.", file: "/home/owner/x.md", turn_id: "t9",
                                                 origin: { client_id: "web:o" })
      allow(access).to receive(:wait_reply).and_return(result)
      allow(access).to receive(:parent_strategy)

      status, body = call("/api/sessions/#{session.id}/wait/prepare", body: { turn: "e-1", busy: true })
      expect([status, body]).to eq([200, { "session_id" => session.id, "baseline" => {}, "known_turn" => true, "live" => true }])
      expect(access).to have_received(:prepare_wait).with(session.id, session: session, question_id: :pending, turn: "e-1")

      expect(call("/api/sessions/#{session.id}/wait", body: { turn: "e-1", cursor: "c1" }))
        .to eq([200, { "status" => "done", "text" => "Yes.", "turn_id" => "t9" }])
      expect(access).to have_received(:wait_reply).with(session.id, hash_including(turn: "e-1", queued: false, cursor: nil))
    end

    # L-P9: what their wait needs (the last turn's end, whether their turn
    # is known or was the last to end, whether a worker runs it), never the
    # owner's cursor, question, message count or running turn.
    it "prepares their wait with only what it needs, none of the owner's wait state" do
      turn({ prompt: "q" })
      owner_state = start.with(baseline: Samagotchi::ReplyWait::Baseline.new(messages: 7, question_id: "q-owner",
                                                                             last_turn: "2026-10-24T10:00:00Z"),
                               own_turn: "e-owner", running: true, settled: true, last_turn_id: "e-owner")
      allow(access).to receive(:prepare_wait).and_return(owner_state, owner_state.with(last_turn_id: "e-1"))

      expect(call("/api/sessions/#{session.id}/wait/prepare", body: { turn: "e-1" }))
        .to eq([200, { "session_id" => session.id, "baseline" => { "last_turn" => "2026-10-24T10:00:00Z" },
                       "known_turn" => true, "live" => true }])
      expect(call("/api/sessions/#{session.id}/wait/prepare", body: { turn: "e-1" }).last["last_turn_id"]).to eq("e-1")
    end

    def wait_on(result)
      turn({ prompt: "q" })
      allow(access).to receive(:wait_reply).and_return(result)
      call("/api/sessions/#{session.id}/wait", body: { turn: "e-1" })
    end

    it "redacts their reply as the stream does: no secret, no thinking, no host path" do
      text = "<think>THOUGHT-SECRET</think>Saved #{root}/docs/x.md and #{Dir.home}/notes; key sk-ant-abcdefghijklmnopqrstuvwx, " \
             "password: hunter2, Authorization: Bearer abc.def\n-----BEGIN RSA PRIVATE KEY-----\nKEYBYTES\n" \
             "-----END RSA PRIVATE KEY-----\nbye<tool_call>{\"cmd\":\"TOOL-ARG\"}"
      status, body = wait_on(Samagotchi::ReplyWait::Result.new(status: :done, text: text, turn_id: "t9"))
      expect(status).to eq(200)
      expect(body["text"]).to include("Saved docs/x.md and ~/notes", "password: [redacted]", "bye")
      %w[THOUGHT-SECRET sk-ant hunter2 abc.def KEYBYTES TOOL-ARG].each { |leak| expect(body["text"]).not_to include(leak), leak }
      expect(body["text"]).not_to include(root)
    end

    it "says their turn failed in fixed words, never the exception's or the failure summary's" do
      crash = "Errno::ENOENT: No such file #{Dir.home}/.config/samagotchi/x key sk-ant-abcdefghijklmnopqrstu"
      [Samagotchi::ReplyWait::Result.new(status: :error, text: crash),
       Samagotchi::ReplyWait::Result.new(status: :no_reply, outcome: "failed", text: "failed: #{crash}")].each do |result|
        status, body = wait_on(result)
        expect(body["text"].to_s).not_to include("ENOENT", "sk-ant", Dir.home)
        expect([status, body["status"], body["text"]]).to eq([200, result.status.to_s, Samagotchi::ParticipantMessages::TURN_FAILED])
        expect(body["outcome"]).to eq(result.outcome)
      end
    end

    it "names a turn that ended without a reply by its outcome, so their chi send --wait reads failed or canceled as such" do
      %w[failed canceled limit].each do |outcome|
        _status, body = wait_on(Samagotchi::ReplyWait::Result.new(status: :no_reply, outcome: outcome, cancel_reason: "stop"))
        expect(body.slice("status", "outcome", "cancel_reason")).to eq("status" => "no_reply", "outcome" => outcome, "cancel_reason" => "stop")
      end
    end

    it "says an owner's question or approval in their turn is the owner's, with nothing of it" do
      turn({ prompt: "q" })
      question = Struct.new(:to_file).new({ "question" => "Allow write?" })
      allow(access).to receive(:wait_reply).and_return(Samagotchi::ReplyWait::Result.new(status: :waiting_for_answer, question: question))
      expect(call("/api/sessions/#{session.id}/wait", body: { turn: "e-1" }))
        .to eq([200, { "status" => "waiting_for_owner", "detail" => "waiting for the session's owner" }])
    end

    it "refuses a wait without a turn of theirs (403 not_permitted): another's, none, an unknown one" do
      [{}, { turn: "owner-eid" }, { turn: 5 }].each do |body|
        expect(call("/api/sessions/#{session.id}/wait/prepare", body: body).first).to eq(body[:turn] == 5 ? 400 : 403)
        expect(call("/api/sessions/#{session.id}/wait", body: body).first).to eq(body[:turn] == 5 ? 400 : 403)
      end
      expect(access).not_to have_received(:prepare_wait)
    end
  end
end
