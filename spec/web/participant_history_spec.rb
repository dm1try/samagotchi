# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/grants"
require "samagotchi/participants"
require "samagotchi/participant_prompts"
require "samagotchi/prompt_history"
require "samagotchi/session_manager"

# GET /api/sessions/:id/prompt_history, the leak test: a participant's ↑
# list holds only what chi web accepted from their grant, redacted as their
# conversation shows it; never the owner's prompts (this session's or the
# machine-wide history) nor another participant's.
RSpec.describe Samagotchi::Web::App, "a participant's own prompt history" do
  let(:owner_token) { "t0ken-t0ken-t0ken-t0ken-t0ken-t0ken-t0ken" }
  let(:lan_ip) { "192.168.1.55" }
  let(:root) { File.realpath(Dir.mktmpdir("web-participant-history")) }
  let(:state_dir) { File.join(root, "samagotchi", "sessions") }
  let(:project) { File.join(root, "proj") }
  let(:grants) { Samagotchi::Grants.new(Samagotchi::Grants.path(state_dir: state_dir)) }
  let(:hub) { nil }
  let(:app) do
    described_class.new(state_dir: state_dir, bridge_wait_timeout: 0, grants: grants, hub: hub,
                        lan: { ip: lan_ip, token: owner_token })
  end
  let(:session) { new_session }
  let(:alex) { Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex", state_dir: state_dir) }
  let(:blair) { Samagotchi::Participants.invite(grants, session_id: session.id, name: "Blair", state_dir: state_dir) }
  let(:delivered) { [] }

  def new_session
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: project).tap do |s|
      s.save(state_dir: state_dir)
      FileUtils.mkdir_p(Samagotchi::Session.session_dir(s.id, state_dir: state_dir))
    end
  end

  before do
    FileUtils.mkdir_p(project)
    allow(Samagotchi::SessionManager).to receive(:deliver_turn) do |_id, **kwargs|
      delivered << kwargs
      Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :bridge,
                                                    ack: { "status" => "accepted", "enqueued_id" => "e-#{delivered.size}" })
    end
    allow(Samagotchi::PromptHistory).to receive(:append)
    allow(Samagotchi::PromptHistory).to receive(:entries).and_return(["OWNER-GLOBAL"])
  end

  after { FileUtils.remove_entry(root) }

  def call(path, method: "GET", body: nil, token: nil, owner: false)
    env = Rack::MockRequest.env_for(path, method: method, input: body ? JSON.generate(body) : nil,
                                          "CONTENT_TYPE" => "application/json")
    env["HTTP_HOST"] = "#{owner ? "127.0.0.1" : lan_ip}:4567"
    env["REMOTE_ADDR"] = owner ? "127.0.0.1" : "192.168.1.20"
    env["HTTP_AUTHORIZATION"] = "Bearer #{owner ? owner_token : token}"
    status, headers, chunks = app.call(env)
    [status, headers, chunks.join]
  end

  def turn(invite, body) = call("/api/sessions/#{session.id}/turn", method: "POST", body: body, token: invite.token).first

  def history_of(invite, id: session.id) = call("/api/sessions/#{id}/prompt_history", token: invite.token)

  def entries_of(invite)
    status, _headers, raw = history_of(invite)
    expect(status).to eq(200)
    JSON.parse(raw)["entries"]
  end

  def refused_lines
    file = File.join(Samagotchi::Session.session_dir(session.id, state_dir: state_dir), "participants.jsonl")
    File.readlines(file).map { |line| JSON.parse(line) }.select { |line| line["event"] == "refused" }
  end

  it "serves each participant only their own accepted sends, oldest first: never the owner's or the other's" do
    expect(call("/api/sessions/#{session.id}/turn", method: "POST", body: { prompt: "OWNER-HERE" }, owner: true).first)
      .to eq(202)
    expect(turn(alex, { prompt: "A-1" })).to eq(202)
    expect(turn(alex, { prompt: "A-2", delivery: "queue" })).to eq(202)
    expect(turn(blair, { prompt: "B-1" })).to eq(202)
    expect(turn(alex, { prompt: "!ls" })).to eq(403)
    expect(turn(alex, { prompt: "A-image-only", history: false })).to eq(202)
    # A forged author or client id still records under the sender's grant.
    expect(turn(blair, { prompt: "B-forged", author: alex.grant.author, client_id: "participant:#{alex.grant.id}" }))
      .to eq(202)

    status, headers, raw = history_of(alex)
    expect(status).to eq(200)
    expect(headers["Cache-Control"]).to eq("no-store")
    expect(JSON.parse(raw)).to eq("entries" => %w[A-1 A-2])
    expect(entries_of(blair)).to eq(%w[B-1 B-forged])
    [alex, blair].each do |invite|
      body = history_of(invite).last
      expect(body).not_to include("OWNER")
      expect(body).not_to include(invite == alex ? "B-" : "A-")
      expect(body).not_to include("ls")
      expect(body).not_to include("grant", "p_")
    end
  end

  it "reads each entry as the conversation shows it: secret shapes and the owner's token redacted, the folder relative" do
    key = "sk-ant-#{"a" * 20}"
    turn(alex, { prompt: "use #{key} please" })
    turn(alex, { prompt: "the token is #{owner_token}" })
    turn(alex, { prompt: "see #{project}/docs/plan.md" })

    raw = history_of(alex).last
    expect(raw).not_to include(key)
    expect(raw).not_to include(owner_token)
    expect(raw).not_to include(project)
    expect(JSON.parse(raw)["entries"]).to eq(["use [redacted] please", "the token is [redacted]", "see docs/plan.md"])
    # The file keeps what they sent.
    expect(Samagotchi::ParticipantPrompts.entries(Samagotchi::Session.session_dir(session.id, state_dir: state_dir),
                                                  alex.grant.id).first).to include(key)
  end

  context "with a hub that knows the session's folder" do
    let(:hub) { instance_double(Samagotchi::Web::SessionHub, working_directory: project) }

    it "redacts against the hub's cached folder, loading no session" do
      turn(alex, { prompt: "see #{project}/a.rb" })
      allow(Samagotchi::Session).to receive(:load).and_call_original
      expect(entries_of(alex)).to eq(["see a.rb"])
      expect(Samagotchi::Session).not_to have_received(:load)
    end
  end

  it "answers the owner a plain 403 with no audit line: the owner's list is /api/history" do
    turn(alex, { prompt: "A-1" })
    status, _headers, raw = call("/api/sessions/#{session.id}/prompt_history", owner: true)
    expect([status, JSON.parse(raw)]).to eq([403, { "error" => "not_permitted",
                                                    "detail" => Samagotchi::Participants::NOT_PERMITTED }])
    expect(raw).not_to include("A-1")
    expect(refused_lines).to eq([])
  end

  it "answers another session's id as an unknown session, a revoked link 401, and /api/history 403" do
    turn(alex, { prompt: "A-1" })
    other = new_session
    status, _headers, raw = history_of(alex, id: other.id)
    expect(status).to eq(404)
    expect(raw).not_to include("A-1")

    status, _headers, raw = call("/api/history", token: alex.token)
    expect(status).to eq(403)
    expect(raw).not_to include("OWNER-GLOBAL")

    Samagotchi::Participants.revoke(grants, session_id: session.id, id: alex.grant.id, state_dir: state_dir)
    status, _headers, raw = history_of(alex)
    expect(status).to eq(401)
    expect(raw).not_to include("A-1")
  end

  it "reads no query: a ?grant= naming the other participant still answers the caller's own" do
    turn(alex, { prompt: "A-1" })
    turn(blair, { prompt: "B-1" })
    status, _headers, raw = call("/api/sessions/#{session.id}/prompt_history?grant=#{blair.grant.id}", token: alex.token)
    expect([status, JSON.parse(raw)]).to eq([200, { "entries" => ["A-1"] }])
  end
end
