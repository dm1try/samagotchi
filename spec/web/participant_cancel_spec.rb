# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/grants"
require "samagotchi/participants"
require "samagotchi/bridge_client"
require "samagotchi/bridge"

# POST /api/sessions/:id/cancel from a participant
# (ParticipantAccess#participant_cancel): their own running turn only, by
# its turn_id, which the worker compares under its lock.
RSpec.describe Samagotchi::Web::App, "a participant stopping a turn" do
  let(:lan_ip) { "192.168.1.55" }
  let(:root) { File.realpath(Dir.mktmpdir("web-participant-cancel")) }
  let(:state_dir) { File.join(root, "samagotchi", "sessions") }
  let(:grants) { Samagotchi::Grants.new(Samagotchi::Grants.path(state_dir: state_dir)) }
  let(:app) do
    described_class.new(state_dir: state_dir, bridge_wait_timeout: 0, grants: grants,
                        lan: { ip: lan_ip, token: "t0ken-t0ken-t0ken-t0ken-t0ken-t0ken-t0ken" })
  end
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: root).tap do |s|
      s.save(state_dir: state_dir)
      FileUtils.mkdir_p(Samagotchi::Session.session_dir(s.id, state_dir: state_dir))
    end
  end
  let(:issued) { Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex", state_dir: state_dir) }
  let(:other) { Samagotchi::Participants.invite(grants, session_id: session.id, name: "Sam", state_dir: state_dir) }
  let(:client) { instance_double(Samagotchi::BridgeClient) }
  let(:running) { { "turn_id" => "t-alex", "author" => issued.grant.author, "origin" => { "client_id" => "review:x" } } }
  let(:not_permitted) { [403, { "error" => "not_permitted", "detail" => Samagotchi::Participants::NOT_PERMITTED }] }
  # A worker whose cancel compares the turn_id it is named (TurnState#cancel!).
  let(:features) { ["delivery", Samagotchi::Delivery::CANCEL_TURN_ID_FEATURE] }

  before do
    allow(app).to receive(:bridge_get_json).with(session.id, "snapshot") { { "snapshot" => { "current_turn" => running } } }
    allow(app).to receive(:bridge_client).with(session.id).and_return(client)
    allow(Samagotchi::ParticipantMode).to receive(:live_features).and_return(features)
  end

  after { FileUtils.remove_entry(root) }

  def cancel(body, token: issued.token)
    env = Rack::MockRequest.env_for("/api/sessions/#{session.id}/cancel", method: "POST", input: JSON.generate(body),
                                                                         "CONTENT_TYPE" => "application/json")
    env["HTTP_HOST"] = "#{lan_ip}:4567"
    env["REMOTE_ADDR"] = "192.168.1.20"
    env["HTTP_AUTHORIZATION"] = "Bearer #{token}"
    status, _headers, chunks = app.call(env)
    [status, JSON.parse(chunks.join)]
  end

  def reply(status, json) = instance_double(Samagotchi::BridgeClient::Response, status: status, json: json, secret_refused?: false)

  def refusals
    log = File.join(Samagotchi::Session.session_dir(session.id, state_dir: state_dir), Samagotchi::Participants::LOG)
    File.readlines(log).map { |line| JSON.parse(line) }.select { |line| line["event"] == "refused" }
  end

  it "stops their own running turn by its turn_id, with the server's reason, never the body's" do
    allow(client).to receive(:cancel).and_return(reply(202, { "reason" => "user" }))
    status, body = cancel({ turn_id: "t-alex", reason: "session_stopped" })
    expect([status, body["status"]]).to eq([202, "cancel_requested"])
    expect(client).to have_received(:cancel).with(reason: "user", turn_id: "t-alex")
  end

  it "is refused (403, audited) without a turn_id, for the owner's turn, another participant's, or a turn not running" do
    allow(client).to receive(:cancel)
    expect(cancel({})).to eq(not_permitted)
    expect(cancel({ reason: "user" })).to eq(not_permitted)
    expect(cancel({ turn_id: "t-other" })).to eq(not_permitted)
    running.replace("turn_id" => "t-owner", "origin" => { "client_id" => "web:1" })
    expect(cancel({ turn_id: "t-owner" })).to eq(not_permitted)
    running.replace("turn_id" => "t-sam", "author" => other.grant.author)
    expect(cancel({ turn_id: "t-sam" })).to eq(not_permitted)
    # An author named only in the turn's origin counts the same.
    running.replace("turn_id" => "t-sam", "origin" => { "client_id" => "review:#{other.grant.id}", "author" => other.grant.author })
    expect(cancel({ turn_id: "t-sam" })).to eq(not_permitted)
    expect(client).not_to have_received(:cancel)
    expect(refusals.map { |line| [line["participant"], line["path"], line["reason"]] })
      .to include([issued.grant.id, "/api/sessions/#{session.id}/cancel", "not_permitted"])
  end

  it "answers not_running when no turn runs, and not_live without a worker" do
    allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return({ "snapshot" => { "current_turn" => nil } })
    expect(cancel({ turn_id: "t-alex" })).to eq([409, { "error" => "not_running", "detail" => "no active turn to cancel",
                                                        "session_id" => session.id }])
    allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(nil)
    expect(cancel({ turn_id: "t-alex" }).first).to eq(503)
  end

  # The race: their turn ends and the owner's starts between chi web's read
  # and the worker's cancel. The worker compares the named turn under its
  # lock (TurnState#cancel!) and refuses: the owner's turn runs on.
  it "never stops the turn that started after the read: the worker answers turn_mismatch" do
    allow(client).to receive(:cancel).with(reason: "user", turn_id: "t-alex")
                                     .and_return(reply(409, { "error" => "turn_mismatch" }))
    expect(cancel({ turn_id: "t-alex" })).to eq([409, { "error" => "turn_mismatch", "detail" => "the running turn is not the one named",
                                                        "session_id" => session.id }])
  end

  # An older worker's Bridge ignores turn_id: their turn ending and the
  # owner's queued one starting before the cancel lands would stop the
  # owner's. Refused, audited, nothing relayed; the owner's cancel goes on.
  it "refuses (409 cancel_unavailable, audited) on a worker that can't cancel by turn_id: nothing is relayed" do
    features.delete(Samagotchi::Delivery::CANCEL_TURN_ID_FEATURE)
    allow(client).to receive(:cancel)
    expect(cancel({ turn_id: "t-alex" })).to eq([409, { "error" => "cancel_unavailable",
                                                        "detail" => Samagotchi::ParticipantMessages::CANCEL_UNAVAILABLE }])
    expect(client).not_to have_received(:cancel)
    expect(refusals.map { |line| line["reason"] }).to include("cancel_unavailable")
    expect(Samagotchi::Bridge::FEATURES).to include(Samagotchi::Delivery::CANCEL_TURN_ID_FEATURE)
  end

  it "leaves the owner's cancel as it was: any turn, the body's reason, a turn_id when given" do
    allow(client).to receive(:cancel).and_return(reply(202, { "reason" => "ctrl_c" }))
    running.replace("turn_id" => "t-owner")
    status, = cancel({ reason: "ctrl_c" }, token: "t0ken-t0ken-t0ken-t0ken-t0ken-t0ken-t0ken")
    expect(status).to eq(202)
    expect(client).to have_received(:cancel).with(reason: "ctrl_c")
  end
end
