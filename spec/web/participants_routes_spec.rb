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

# The owner's participants routes (GET/POST/DELETE /api/sessions/:id/
# participants, GET/DELETE /api/participants), and an archive or a delete
# ending a session's grants.
RSpec.describe Samagotchi::Web::App, "participants routes" do
  let(:root) { Dir.mktmpdir("web-participants") }
  let(:state_dir) { File.join(root, "samagotchi", "sessions") }
  let(:grants) { Samagotchi::Web::Grants.new(Samagotchi::Web::Grants.path(state_dir: state_dir)) }
  let(:lan) { { ip: "192.168.1.55", token: "owner-token" } }
  let(:app) { described_class.new(state_dir: state_dir, bridge_wait_timeout: 0, grants: grants, lan: lan) }
  let(:session) { new_session }

  def new_session
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: root).tap do |session|
      session.save(state_dir: state_dir)
      FileUtils.mkdir_p(Samagotchi::Session.session_dir(session.id, state_dir: state_dir))
    end
  end

  after { FileUtils.remove_entry(root) }

  def call(path, method: "GET", body: nil, host: "127.0.0.1:4567")
    opts = { method: method }
    opts[:input] = JSON.generate(body) if body
    env = Rack::MockRequest.env_for(path, **opts, "CONTENT_TYPE" => "application/json")
    env["HTTP_HOST"] = host
    env["REMOTE_ADDR"] = "127.0.0.1"
    # On the LAN this machine's loopback needs the owner's token too.
    env["HTTP_AUTHORIZATION"] = "Bearer #{lan[:token]}" if lan
    status, _headers, chunks = app.call(env)
    [status, JSON.parse(chunks.join)]
  end

  describe "GET /api/sessions/:id/participants" do
    it "gives each participant's spend and turns from the saved analytics; the invite gives the link's QR once" do
      status, invited = call("/api/sessions/#{session.id}/participants", method: "POST", body: { name: "Alex" })
      expect(status).to eq(201)
      expect(invited["qr_svg"]).to start_with("<svg").and include("QR code of the review link")
      id = invited["participant"]["id"]
      dir = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)
      File.write(Samagotchi::AnalyticsFile.path(dir), JSON.generate({ "turn_records" => [
        { "id" => "t1", "author" => "p:#{id}", "cost" => 0.25 }, { "id" => "t2", "author" => "p:#{id}", "cost_estimate" => 0.5 },
        { "id" => "t3", "cost" => 9.0 }
      ] }))

      _, body = call("/api/sessions/#{session.id}/participants")
      expect(body["participants"]).to contain_exactly(include("id" => id, "name" => "Alex", "spend" => 0.75, "turns" => 2))
      expect(call("/api/participants").last["participants"].first).not_to have_key("spend")
      expect(JSON.generate(body)).not_to include(invited["token"])
    end
  end

  describe "POST /api/sessions/:id/participants with an identity" do
    it "refuses it on a chi web with no auth proxy (400, Unbindable's words), issuing nothing" do
      status, body = call("/api/sessions/#{session.id}/participants", method: "POST",
                                                                      body: { name: "Alex", identity: "alex@corp.test" })
      expect([status, body]).to eq([400, { "error" => "invalid_participant",
                                           "detail" => Samagotchi::Web::Grants::Unbindable.new.message }])
      expect(grants.list).to eq([])
    end

    it "says on the owner's /api/info that it has bound grants, and no proxy" do
      _, info = call("/api/info")
      expect(info["features"]).to include("bound_grants")
      expect(info).to include("proxy" => nil)
      expect(call("/api/sessions/#{session.id}/participants").last).to include("identity_header" => nil)
    end

    it "says where a participant's link opens, without a token: the LAN address (a claim link's base)" do
      _, body = call("/api/sessions/#{session.id}/participants")
      expect(body["link_base"]).to eq("http://192.168.1.55:4567/")
      expect(call("/api/participants").last).not_to have_key("link_base")
    end
  end

  describe "POST /api/sessions/:id/participants/:participant/cap" do
    it "sets an active participant's cap (grant and sidecar), and takes one at the invite" do
      _, invited = call("/api/sessions/#{session.id}/participants", method: "POST", body: { name: "Alex", cap: 4 })
      id = invited["participant"]["id"]
      expect(invited["participant"]).to include("cap" => 4.0, "queue" => 3)

      status, body = call("/api/sessions/#{session.id}/participants/#{id}/cap", method: "POST", body: { cap: 0.5 })
      expect(status).to eq(200)
      expect(body["participant"]).to include("id" => id, "cap" => 0.5)
      expect(Samagotchi::Participants.read(session.id, state_dir: state_dir).first.cap).to eq(0.5)
    end

    it "refuses a cap out of range, an unknown participant and a bad id (400 invalid_participant)" do
      _, invited = call("/api/sessions/#{session.id}/participants", method: "POST", body: { name: "Alex" })
      id = invited["participant"]["id"]
      expect(call("/api/sessions/#{session.id}/participants/#{id}/cap", method: "POST", body: { cap: "5" }))
        .to eq([400, { "error" => "invalid_participant", "detail" => Samagotchi::Web::Grants::CAP_RANGE }])
      expect(call("/api/sessions/#{session.id}/participants/p_00000000/cap", method: "POST", body: { cap: 1 }).first).to eq(400)
      expect(call("/api/sessions/#{session.id}/participants/x/cap", method: "POST", body: { cap: 1 }).first).to eq(400)
      expect(call("/api/sessions/#{session.id}/participants", method: "POST", body: { name: "B", cap: 5000 }).first).to eq(400)
      expect(grants.find(id).spend_cap).to eq(2.0)
    end
  end

  describe "POST /api/sessions/:id/participants" do
    it "issues a grant and answers its token and LAN link once; chi keeps only the digest" do
      status, body = call("/api/sessions/#{session.id}/participants", method: "POST", body: { name: "Alex", kind: "agent", ttl: 3 * 86_400 })

      expect(status).to eq(201)
      expect(body["participant"]).to include("name" => "Alex", "kind" => "agent", "role" => "reviewer", "state" => "active",
                                             "session_id" => session.id)
      expect(body["participant"]).not_to have_key("digest")
      expect(body["token"]).to start_with("chp_")
      expect(body["link"]).to eq("http://192.168.1.55:4567/?token=#{body["token"]}#s=#{session.id}")
      expect(body["lan"]).to be(true)
      expect(grants.lookup(body["token"]).id).to eq(body["participant"]["id"])
    end

    it "stamps the grant pair only when the warning it answers says their turns act" do
      _status, body = call("/api/sessions/#{session.id}/participants", method: "POST", body: { name: "Alex" })
      expect(body["warning"]).to include("a participant's turns act in it")
      expect(grants.lookup(body["token"]).mode).to eq("pair")
      entry = Samagotchi::Participants.read(session.id, state_dir: state_dir).first
      expect(entry.mode).to eq("pair")

      sidecar = Samagotchi::WorkerSidecar.new(port: 1, session_id: session.id, features: %w[delivery review_turns])
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(Samagotchi::WorkerLink::Live.new(sidecar: sidecar))
      _status, older = call("/api/sessions/#{session.id}/participants", method: "POST", body: { name: "Bo" })
      expect(older["warning"]).to include("a participant invited now only reads")
      expect(grants.lookup(older["token"]).mode).to be_nil

      review = new_session.tap do |s|
        s.review = { subjects: ["x.md"] }
        s.save(state_dir: state_dir)
      end
      _status, reviewing = call("/api/sessions/#{review.id}/participants", method: "POST", body: { name: "Kim" })
      expect(reviewing["warning"]).to be_nil
      expect(grants.lookup(reviewing["token"]).mode).to be_nil
      expect(File.read(File.join(Samagotchi::Session.session_dir(review.id, state_dir: state_dir), "participants.json")))
        .not_to include("mode")
    end

    it "refuses a bad name, kind or ttl (400 invalid_participant) and an unknown session (404)" do
      expect(call("/api/sessions/#{session.id}/participants", method: "POST", body: { name: " " }))
        .to eq([400, { "error" => "invalid_participant", "detail" => "a participant needs a name" }])
      expect(call("/api/sessions/#{session.id}/participants", method: "POST", body: { name: "A", kind: "bot" }).first).to eq(400)
      expect(call("/api/sessions/#{session.id}/participants", method: "POST", body: { name: "A", ttl: "3d" }).first).to eq(400)
      expect(call("/api/sessions/nope/participants", method: "POST", body: { name: "A" }).first).to eq(404)
      expect(grants.list).to eq([])
    end
  end

  describe "GET and DELETE" do
    it "lists a session's or every grant, never a token or digest, and revokes one, a session's or all" do
      a = Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex", state_dir: state_dir)
      b = Samagotchi::Participants.invite(grants, session_id: session.id, name: "Sam", state_dir: state_dir)
      other = new_session
      c = Samagotchi::Participants.invite(grants, session_id: other.id, name: "Kim", state_dir: state_dir)

      status, body = call("/api/sessions/#{session.id}/participants")
      expect(status).to eq(200)
      expect(body["participants"].map { |p| p["name"] }).to eq(%w[Alex Sam])
      expect(JSON.generate(body)).not_to include(a.token, a.grant.digest)
      expect(call("/api/participants").last["participants"].size).to eq(3)

      expect(call("/api/sessions/#{session.id}/participants?id=#{a.grant.id}", method: "DELETE").last["revoked"].map { |p| p["id"] })
        .to eq([a.grant.id])
      expect(call("/api/sessions/#{session.id}/participants?id=nope", method: "DELETE").first).to eq(400)
      expect(call("/api/sessions/#{session.id}/participants", method: "DELETE").last["revoked"].map { |p| p["id"] })
        .to eq([b.grant.id])
      expect(call("/api/participants", method: "DELETE").last["revoked"].map { |p| p["id"] }).to eq([c.grant.id])
      expect(call("/api/participants").last["participants"].map { |p| p["state"] }.uniq).to eq(["revoked"])
    end
  end

  # A store chi won't write over (Grants::Corrupt, Grants::Newer): every
  # route refuses with the store's own words, never a 500.
  describe "a grants store chi can't write" do
    def refusals(routes)
      routes.map { |path, method, body| call(path, method: method, body: body) }
    end

    it "refuses every route with 409 grants_unwritable and the store's message when it doesn't read" do
      allow(Samagotchi::Log).to receive(:warn) # the store says so itself (grants_unreadable)
      FileUtils.mkdir_p(File.dirname(grants.path))
      File.write(grants.path, "{not json")
      message = Samagotchi::Web::Grants::Corrupt.new(grants.path, "not JSON").message
      routes = [["/api/sessions/#{session.id}/participants", "GET"], ["/api/participants", "GET"],
                ["/api/sessions/#{session.id}/participants", "POST", { name: "Alex" }],
                ["/api/sessions/#{session.id}/participants", "DELETE"], ["/api/participants", "DELETE"],
                ["/api/sessions/#{session.id}/participants/p_00000000/cap", "POST", { cap: 1 }]]
      expect(refusals(routes)).to all(eq([409, { "error" => "grants_unwritable", "detail" => message }]))
    end

    it "refuses a write into a newer chi's store with that store's message, and still lists it" do
      invited = Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex", state_dir: state_dir)
      File.write(grants.path, JSON.generate(JSON.parse(File.read(grants.path)).merge("version" => 99)))
      message = Samagotchi::Web::Grants::Newer.new(grants.path, 99).message
      routes = [["/api/sessions/#{session.id}/participants", "POST", { name: "Sam" }],
                ["/api/sessions/#{session.id}/participants", "DELETE"],
                ["/api/sessions/#{session.id}/participants/#{invited.grant.id}/cap", "POST", { cap: 1 }]]
      expect(refusals(routes)).to all(eq([409, { "error" => "grants_unwritable", "detail" => message }]))
      expect(call("/api/participants").first).to eq(200)
    end
  end

  describe "an archive or a delete" do
    it "revokes the session's grants (archive) and the deleted one's (delete)" do
      archived = Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex", state_dir: state_dir)
      Samagotchi::SessionManager.archive_session(session.id, state_dir: state_dir)
      expect(grants.find(archived.grant.id)).to have_attributes(revoked_by: "archive")

      other = new_session
      deleted = Samagotchi::Participants.invite(grants, session_id: other.id, name: "Kim", state_dir: state_dir)
      Samagotchi::SessionManager.delete_session(other.id, state_dir: state_dir)
      expect(grants.find(deleted.grant.id)).to have_attributes(revoked_by: "delete")
    end

    it "writes no grants store for a session nobody was invited to" do
      Samagotchi::SessionManager.archive_session(session.id, state_dir: state_dir)
      expect(File.exist?(grants.path)).to be(false)
    end
  end
end
