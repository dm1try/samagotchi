# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/web/grants"
require "samagotchi/participants"
require "samagotchi/prompt_history"
require "samagotchi/session_manager"

# POST /api/sessions/:id/turn and …/turn/:eid/dequeue from a participant:
# a review turn whose author and client id are the grant's, always queued,
# with no shell line, command or image, nothing in the owner's prompt
# history, and every answer audited.
RSpec.describe Samagotchi::Web::App, "a participant's turn" do
  let(:owner_token) { "t0ken-t0ken-t0ken-t0ken-t0ken-t0ken-t0ken" }
  let(:lan_ip) { "192.168.1.55" }
  let(:root) { Dir.mktmpdir("web-participant-turn") }
  let(:state_dir) { File.join(root, "samagotchi", "sessions") }
  let(:grants) { Samagotchi::Web::Grants.new(Samagotchi::Web::Grants.path(state_dir: state_dir)) }
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

  it "stamps the author and client id from the grant and queues it, whatever the body says" do
    status, body = turn({ prompt: "Is step 3 safe?", client_id: "cli:answer", author: "owner", delivery: "cut",
                          no_interrupt: true })

    expect(status).to eq(202)
    expect(body).to include("status" => "accepted", "delivery" => "queue")
    expect(delivered.first).to include(prompt: "Is step 3 safe?", client_id: "review:#{grant.id}", author: grant.author,
                                       delivery: "queue", pending_limit: 4)
    expect(delivered.first).not_to include(no_interrupt: true)
    expect(delivered.first).not_to have_key(:images)
    expect(Samagotchi::PromptHistory).not_to have_received(:append)
    expect(audit.map { |line| line.slice("participant", "status", "enqueued_id", "chars") })
      .to eq([{ "participant" => grant.id, "status" => "accepted", "enqueued_id" => "e-1", "chars" => 15 }])
  end

  it "refuses a shell line, a command and images (403 not_permitted), audited, never delivered" do
    ["!ls", "  /toolkit full", "/title mine"].each do |line|
      expect(turn({ prompt: line })).to eq([403, { "error" => "not_permitted", "detail" => Samagotchi::Participants::NOT_PERMITTED }])
    end
    expect(turn({ prompt: "look", images: [{ file: "a.png", name: "a" }] }).first).to eq(403)
    expect(delivered).to eq([])
    expect(audit.map { |line| line.values_at("status", "reason") }).to all(eq(%w[refused not_permitted]))
    expect(audit.size).to eq(4)
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

  it "sends the owner's turn as before: the body's client id, its delivery, the history" do
    env = Rack::MockRequest.env_for("/api/sessions/#{session.id}/turn", method: "POST",
                                                                        input: JSON.generate({ prompt: "go", client_id: "web:t", delivery: "cut" }))
    env["HTTP_HOST"] = "127.0.0.1:4567"
    env["REMOTE_ADDR"] = "127.0.0.1"
    expect(app.call(env).first).to eq(202)
    expect(delivered.first).to include(client_id: "web:t", delivery: "cut", author: nil)
    expect(Samagotchi::PromptHistory).to have_received(:append).with("go")
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
      expect(bridge).to have_received(:dequeue).with(enqueued_id: "e-1", client_id: "review:#{grant.id}")
    end

    it "refuses another author's queued turn (403 not_permitted), whatever the body says" do
      other = Samagotchi::Participants.invite(grants, session_id: session.id, name: "Kim", state_dir: state_dir)
      call("/api/sessions/#{session.id}/turn", body: { prompt: "kim's" }, token: other.token)

      expect(call("/api/sessions/#{session.id}/turn/e-1/dequeue", body: { client_id: "review:#{other.grant.id}" }).first).to eq(403)
      expect(call("/api/sessions/#{session.id}/turn/owner-eid/dequeue").first).to eq(403)
      expect(bridge).not_to have_received(:dequeue)
    end

    it "knows a turn by its waiting file's author after chi web restarted" do
      dir = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)
      Samagotchi::SessionInbox.write_input(dir, prompt: "mine", client_id: "review:#{grant.id}", enqueued_id: "e-old",
                                                author: grant.author, delivery: "queue")
      Samagotchi::SessionInbox.write_input(dir, prompt: "owner's", client_id: "web:o", enqueued_id: "e-owner", delivery: "queue")

      expect(call("/api/sessions/#{session.id}/turn/e-old/dequeue").first).to eq(200)
      expect(call("/api/sessions/#{session.id}/turn/e-owner/dequeue").first).to eq(403)
    end
  end
end
