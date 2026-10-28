# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/web/grants"
require "samagotchi/participants"
require "samagotchi/session_manager"
require "samagotchi/analytics_file"
require "samagotchi/verify_fresh"

# POST /api/sessions/:id/verdicts/:check_turn_id/fresh: the owner's and a
# participant's Verify fresh. A participant's is refused as their turn
# would be, audited like one, and their child gets their grant's mode.
RSpec.describe Samagotchi::Web::App, "Verify fresh" do
  let(:owner_token) { "t0ken-t0ken-t0ken-t0ken-t0ken-t0ken-t0ken" }
  let(:lan_ip) { "192.168.1.55" }
  let(:root) { Dir.mktmpdir("web-verify-fresh") }
  let(:state_dir) { File.join(root, "samagotchi", "sessions") }
  let(:grants) { Samagotchi::Web::Grants.new(Samagotchi::Web::Grants.path(state_dir: state_dir)) }
  let(:app) do
    described_class.new(state_dir: state_dir, bridge_wait_timeout: 0, grants: grants, lan: { ip: lan_ip, token: owner_token })
  end
  let(:source_turn) { "11111111-2222-3333-4444-555555555555" }
  let(:check_turn) { "22222222-3333-4444-5555-666666666666" }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: root).tap do |s|
      s.verdicts = [{ anchor: { turn_id: source_turn, quote: "a claim" }, verdict: "unclear", reason: "?", by: nil,
                      check_turn_id: check_turn }]
      s.save(state_dir: state_dir)
      FileUtils.mkdir_p(Samagotchi::Session.session_dir(s.id, state_dir: state_dir))
    end
  end
  let(:mode) { "pair" }
  let(:issued) { Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex", mode: mode, state_dir: state_dir) }
  let(:grant) { issued.grant }
  let(:spawned) { [] }

  before do
    allow(Samagotchi::SessionManager).to receive(:spawn_session) do |**options|
      spawned << options
      Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: root, parent_id: session.id,
                                      delegate: true).tap do |child|
        child.verify_fresh = options[:verify_fresh]
        child.status = Samagotchi::Session::STATUS_RUNNING
        child.save(state_dir: state_dir)
      end
    end
  end

  after { FileUtils.remove_entry(root) }

  def call(of: check_turn, token: issued.token)
    env = Rack::MockRequest.env_for("/api/sessions/#{session.id}/verdicts/#{of}/fresh", method: "POST", input: "{}",
                                    "CONTENT_TYPE" => "application/json")
    if token
      env["HTTP_HOST"] = "#{lan_ip}:4567"
      env["REMOTE_ADDR"] = "192.168.1.20"
      env["HTTP_AUTHORIZATION"] = "Bearer #{token}"
    else
      env["HTTP_HOST"] = "127.0.0.1:4567"
      env["REMOTE_ADDR"] = "127.0.0.1"
    end
    status, _headers, chunks = app.call(env)
    [status, JSON.parse(chunks.join)]
  end

  def audit = File.readlines(File.join(Samagotchi::Session.session_dir(session.id, state_dir: state_dir), "participants.jsonl"))
                  .map { |line| JSON.parse(line) }.select { |line| line["event"] == "verify_fresh" }

  it "starts the owner's child and names it" do
    status, body = call(token: nil)

    expect(status).to eq(202)
    expect(body).to include("of" => check_turn, "running" => true, "child_id" => a_kind_of(String))
    expect(spawned.first[:verify_fresh].author).to be_nil
    expect(spawned.first).to include(parent_id: session.id, delegate: true, working_directory: root)
  end

  it "starts a pair participant's child under their grant's mode, never naming it to them, audited" do
    status, body = call

    expect([status, body]).to eq([202, { "of" => check_turn, "running" => true }])
    expect(spawned.first[:verify_fresh].to_file).to include("author" => grant.author, "mode" => "pair")
    expect(audit.last).to include("participant" => grant.id, "status" => "accepted", "mode" => "pair", "of" => check_turn)
  end

  context "with a review grant" do
    let(:mode) { nil }

    it "saves review on the child" do
      expect(call.first).to eq(202)
      expect(spawned.first[:verify_fresh].turn_mode).to eq(:review)
    end
  end

  it "refuses one past the cap, counting the participant's fresh children, audited" do
    expect(call.first).to eq(202)
    child_id = Samagotchi::VerifyFresh.ledger(Samagotchi::Session.session_dir(session.id, state_dir: state_dir))
                                                      .first[:child_id]
    FileUtils.mkdir_p(Samagotchi::Session.session_dir(child_id, state_dir: state_dir))
    File.write(Samagotchi::AnalyticsFile.path(Samagotchi::Session.session_dir(child_id, state_dir: state_dir)),
               JSON.generate({ "turn_records" => [{ "id" => "t", "author" => grant.author, "cost" => 2.5 }] }))

    expect(call).to eq([429, { "error" => "cap_reached", "detail" => Samagotchi::ParticipantMessages::CAP_REACHED }])
    turn = Rack::MockRequest.env_for("/api/sessions/#{session.id}/turn", method: "POST",
                                                                         input: JSON.generate({ prompt: "more" }))
    turn.merge!("HTTP_HOST" => "#{lan_ip}:4567", "REMOTE_ADDR" => "192.168.1.20", "HTTP_AUTHORIZATION" => "Bearer #{issued.token}")
    expect(app.call(turn).first).to eq(429)
    expect(audit.last.values_at("status", "reason")).to eq(%w[refused cap_reached])
    expect(spawned.size).to eq(1)
  end

  it "refuses a second check while one runs, an unknown verdict and one that isn't unclear" do
    expect(call.first).to eq(202)
    expect(call.first(2)).to eq([409, { "error" => "fresh_running", "detail" => Samagotchi::VerifyFresh::RUNNING }])
    expect(call(of: "33333333-3333-4444-5555-666666666666").first).to eq(404)
    session.verdicts = [session.verdicts.first.merge(verdict: "confirmed")]
    session.save(state_dir: state_dir)
    expect(call(token: nil).first(2)).to eq([409, { "error" => "not_unclear", "detail" => Samagotchi::VerifyFresh::NOT_UNCLEAR }])
    expect(audit.map { |line| line["status"] }).to eq(%w[accepted refused refused])
  end

  describe "a participant's verdict" do
    let(:sam) { Samagotchi::Participants.invite(grants, session_id: session.id, name: "Sam", state_dir: state_dir) }

    before do
      session.verdicts = [session.verdicts.first.merge(by: grant.author)]
      session.save(state_dir: state_dir)
    end

    it "runs as its participant when the owner clicks: their author, their grant's mode, no owner power" do
      status, body = call(token: nil)

      expect(status).to eq(202)
      expect(body).to include("child_id" => a_kind_of(String))
      expect(spawned.first[:verify_fresh].to_file).to include("author" => grant.author, "mode" => "pair")
      expect(audit.last).to include("participant" => grant.id, "asked_by" => "owner", "status" => "accepted")
    end

    it "runs as its participant when another participant clicks, after the clicker's own checks" do
      expect(call(token: sam.token).first).to eq(202)
      expect(spawned.first[:verify_fresh].author).to eq(grant.author)
      expect(audit.last).to include("participant" => grant.id, "asked_by" => sam.grant.id)
    end

    it "refuses once its participant's link has ended, saying whose" do
      Samagotchi::Participants.revoke(grants, session_id: session.id, id: grant.id, state_dir: state_dir)

      status, body = call(token: nil)
      expect([status, body["error"]]).to eq([409, "author_link_ended"])
      expect(body["detail"]).to start_with("Alex's link has ended")
      expect(spawned).to eq([])
    end

    it "refuses when its participant spent their cap, whoever clicks" do
      File.write(Samagotchi::AnalyticsFile.path(Samagotchi::Session.session_dir(session.id, state_dir: state_dir)),
                 JSON.generate({ "turn_records" => [{ "id" => "t", "author" => grant.author, "cost" => 2.5 }] }))
      expect(call(token: nil).first(2).last).to include("error" => "cap_reached")
      expect(spawned).to eq([])
    end
  end

  it "refuses a participant's while the session's live worker predates participants' turns" do
    allow(Samagotchi::ParticipantMode).to receive(:live_features).and_return(%w[delivery verify])
    expect(call.first(2).last).to include("error" => "review_unavailable")
    expect(spawned).to eq([])
  end

  it "refuses Verify fresh for the owner and participant when the live worker lacks Verify" do
    allow(Samagotchi::ParticipantMode).to receive(:live_features).and_return(%w[delivery review_turns])

    [nil, issued.token].each do |token|
      expect(call(token: token)).to eq([409, Samagotchi::VerifyAnchor::UNAVAILABLE])
    end
    expect(spawned).to be_empty
  end
end
