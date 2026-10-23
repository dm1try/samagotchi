# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/web/grants"
require "samagotchi/participants"
require "samagotchi/archive_store"

# chi web's gate for a participant's token (a Web::Grants grant): who they
# are, the three routes they reach, and every refusal that is theirs.
RSpec.describe Samagotchi::Web::App, "participant gate" do
  let(:owner_token) { "t0ken-t0ken-t0ken-t0ken-t0ken-t0ken-t0ken" }
  let(:lan_ip) { "192.168.1.55" }
  let(:phone) { "192.168.1.20" }
  let(:root) { Dir.mktmpdir("web-participant") }
  let(:state_dir) { File.join(root, "samagotchi", "sessions") }
  let(:public_dir) do
    Dir.mktmpdir("web-participant-public").tap do |dir|
      File.write(File.join(dir, "index.html"), "<html><body>owner page</body></html>")
      File.write(File.join(dir, "participant.html"), "<html><body>participant page</body></html>")
    end
  end
  let(:now) { [Time.now] }
  let(:grants) { Samagotchi::Web::Grants.new(Samagotchi::Web::Grants.path(state_dir: state_dir), clock: -> { now.first }) }
  let(:app) do
    described_class.new(state_dir: state_dir, public_dir: public_dir, bridge_wait_timeout: 0, grants: grants,
                        lan: { ip: lan_ip, token: owner_token })
  end
  let(:session) { new_session("plan review") }
  let(:other) { new_session("secret work") }
  let(:issued) { Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex", state_dir: state_dir) }
  let(:token) { issued.token }

  def new_session(title)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: root).tap do |session|
      session.title = title
      session.save(state_dir: state_dir)
      FileUtils.mkdir_p(Samagotchi::Session.session_dir(session.id, state_dir: state_dir))
    end
  end

  after do
    FileUtils.remove_entry(root)
    FileUtils.remove_entry(public_dir)
  end

  def call(path, method: "GET", peer: phone, bearer: token, headers: {})
    env = Rack::MockRequest.env_for(path, method: method, **headers)
    env["HTTP_HOST"] = "#{lan_ip}:4567"
    env["REMOTE_ADDR"] = peer
    env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}" if bearer
    status, headers, chunks = app.call(env)
    text = +""
    chunks.each { |chunk| text << chunk }
    [status, headers, text]
  end

  def json(path, **) = call(path, **).then { |status, _h, body| [status, JSON.parse(body)] }

  def audit = File.readlines(File.join(Samagotchi::Session.session_dir(session.id, state_dir: state_dir),
                                       Samagotchi::Participants::LOG)).map { |line| JSON.parse(line) }

  describe "who a request is" do
    it "is the owner for the owner's token, whatever grants exist" do
      token
      expect(app.send(:principal_for, Rack::Request.new(Rack::MockRequest.env_for("/", "HTTP_AUTHORIZATION" => "Bearer #{owner_token}",
                                                                                     "REMOTE_ADDR" => phone)))).to be_owner
    end

    it "is a participant for a live grant's token, authoring as p:<id>" do
      req = Rack::Request.new(Rack::MockRequest.env_for("/", "HTTP_AUTHORIZATION" => "Bearer #{token}", "REMOTE_ADDR" => phone))
      principal = app.send(:principal_for, req)
      expect(principal).not_to be_owner
      expect(principal.kind).to eq(:participant)
      expect(principal.author).to eq("p:#{issued.grant.id}")
    end
  end

  describe "a participant's token on this machine (a loopback peer, or chi web not on the LAN)" do
    let(:loopback) { "127.0.0.1" }

    it "is the participant, never the owner: Bearer, cookie and the page's trade" do
      expect(json("/api/info", peer: loopback).last.keys).to contain_exactly("app", "version", "features")
      expect(json("/api/sessions", peer: loopback)).to eq([403, { "error" => "not_permitted",
                                                                  "detail" => Samagotchi::ParticipantMessages::NOT_PERMITTED }])
      cookie = { "HTTP_COOKIE" => "chi_token=#{token}" }
      expect(call("/", peer: loopback, bearer: nil, headers: cookie)[2]).to include(%(data-name="Alex"))
      status, headers, = call("/?token=#{token}", peer: loopback, bearer: nil)
      expect([status, headers["Location"], headers["Set-Cookie"].to_s[/\Achi_token=[^;]*/]]).to eq([303, "/", "chi_token=#{token}"])

      plain = described_class.new(state_dir: state_dir, public_dir: public_dir, bridge_wait_timeout: 0, grants: grants)
      req = Rack::Request.new(Rack::MockRequest.env_for("/api/info", "HTTP_AUTHORIZATION" => "Bearer #{token}",
                                                                     "REMOTE_ADDR" => phone))
      expect(plain.send(:principal_for, req)&.author).to eq("p:#{issued.grant.id}")
    end

    it "is refused once the grant ended (401), and an ended cookie is cleared so the owner's browser is the owner again" do
      token
      Samagotchi::Participants.revoke(grants, session_id: session.id, state_dir: state_dir)
      expect(json("/api/info", peer: loopback).last["error"]).to eq("token_revoked")
      status, headers, = call("/", peer: loopback, bearer: nil, headers: { "HTTP_COOKIE" => "chi_token=#{token}" })
      expect([status, headers["Set-Cookie"].to_s]).to match([401, a_string_starting_with("chi_token=; ")])
      expect(call("/", peer: loopback, bearer: nil)[2]).to include("owner page")
    end

    it "is the owner with the owner's token or no token at all, whatever cookie a participant link left" do
      cookie = { "HTTP_COOKIE" => "chi_token=#{token}" }
      expect(json("/api/info", peer: loopback, bearer: owner_token, headers: cookie).last.keys).to include("pid", "cwd")
      expect(json("/api/info", peer: loopback, bearer: nil).last.keys).to include("pid", "cwd")
    end
  end

  describe "the routes a participant reaches" do
    it "GET /api/sessions/:id: their session's title, status and participants only" do
      status, body = json("/api/sessions/#{session.id}")
      expect(status).to eq(200)
      expect(body).to eq("session" => { "id" => session.id, "title" => "plan review", "status" => session.status,
                                        "participants" => [{ "id" => issued.grant.id, "name" => "Alex", "kind" => "human",
                                                             "role" => "reviewer" }] })
      %w[brief=1 cards=1 tail=1 timing=1].each do |query|
        expect(json("/api/sessions/#{session.id}?#{query}")).to eq([200, body]), query
      end
    end

    it "GET /api/info: app, version and features, not this machine's pid, cwd or LAN address" do
      status, body = json("/api/info")
      expect(status).to eq(200)
      expect(body.keys).to contain_exactly("app", "version", "features")
      expect(body["features"]).to include(Samagotchi::Web::SessionAccessRoutes::FEATURE)
    end

    it "GET /: the participant page's shell, naming their session and name, never the owner's page" do
      status, headers, body = call("/")
      expect(status).to eq(200)
      expect(headers["Content-Type"]).to start_with("text/html")
      expect(body).to include("participant page", %(data-viewer="participant"), %(data-session="#{session.id}"), %(data-name="Alex"))
      expect(body).not_to include("owner page")
      expect(call("/?as=owner")[2]).to include("participant page")
    end

    it "never shows an untitled session's first prompt as its title (Session#display_title's fallback)" do
      session.title = nil
      session.messages << { role: "user", content: "the secret plan for the launch" }
      session.compute_first_preview!
      session.save(state_dir: state_dir)
      expect(session.display_title).to include("secret plan")

      expect(json("/api/sessions/#{session.id}").last.dig("session", "title")).to eq("an untitled session")
      expect(json("/api/sessions/#{session.id}/review").last.dig("session", "title")).to eq("an untitled session")
      expect(call("/")[2]).not_to include("secret plan")
    end

    it "escapes what the page shows" do
      named = Samagotchi::Participants.invite(grants, session_id: session.id, name: "<b>Kim</b>", state_dir: state_dir)
      body = call("/", bearer: named.token)[2]
      expect(body).to include(%(data-name="&lt;b&gt;Kim&lt;/b&gt;"))
      expect(body).not_to include("<b>Kim</b>")
    end

    it "trades ?token= for the cookie holding the participant's token, and the cookie lets them in" do
      status, headers, = call("/?token=#{token}&x=1", bearer: nil)
      expect(status).to eq(303)
      expect(headers["Location"]).to eq("/?x=1")
      expect(headers["Set-Cookie"]).to start_with("chi_token=#{token};")
      expect(call("/", bearer: nil, headers: { "HTTP_COOKIE" => "chi_token=#{token}" })[2]).to include(%(data-name="Alex"))
    end
  end

  describe "what a participant is refused" do
    # A concrete path for a route's pattern: its first capture the
    # participant's session, any other "x".
    def path_for(pattern, id)
      first = true
      source = pattern.source.delete_prefix("\\A").delete_suffix("\\z").gsub("(?:index\\.html)?", "").gsub("\\.", ".")
      source.gsub("([^/]+)") { first ? (first = false) || id : "x" }
    end

    it "gets 403 not_permitted on every :owner route, worded for a participant (generated from ROUTES)" do
      rows = described_class.const_get(:ROUTES).select { |row| row[3] == :owner }
      expect(rows.size).to be >= 40
      rows.each do |verb, pattern, handler|
        path = path_for(pattern, session.id)
        expect(pattern).to match(path), "#{handler}: #{path} isn't its own route"
        status, body = json(path, method: verb)
        expect([status, body["error"]]).to eq([403, "not_permitted"]), "#{verb} #{path} (#{handler})"
        expect(body["detail"]).to eq("a participant can't do that: only the session's owner can")
      end
    end

    it "reaches POST …/turn as a review turn (P3b; spec/web/participant_turn_spec.rb)" do
      expect(json("/api/sessions/#{session.id}/turn", method: "POST").first).to eq(400)
    end

    it "gets 404 for another session on any session route, as if it didn't exist" do
      rows = described_class.const_get(:ROUTES).select { |row| row[1].source.include?("/api/sessions/([^/]+)") }
      rows.each do |verb, pattern, handler|
        missing = json(path_for(pattern, "no-such-session"), method: verb)
        existing = json(path_for(pattern, other.id), method: verb)
        expect(existing.first).to eq(404), "#{verb} #{handler}"
        expect(existing.last["error"]).to eq("not_found")
        expect(existing.last["detail"]).to eq(missing.last["detail"].sub("no-such-session", other.id)), handler.to_s
      end
    end

    it "audits a refused route once a minute, with the participant and the reason" do
      3.times { call("/api/sessions") }
      refused = audit.select { |line| line["event"] == "refused" }
      expect(refused.map { |line| line.slice("participant", "method", "path", "reason") })
        .to eq([{ "participant" => issued.grant.id, "method" => "GET", "path" => "/api/sessions", "reason" => "not_permitted" }])
    end

    it "records the first use and each new peer" do
      call("/api/info")
      call("/api/info")
      call("/api/info", peer: "192.168.1.21")
      peers = audit.select { |line| line["event"] == "peer" }.map { |line| line["ip"] }
      expect(peers).to eq([phone, "192.168.1.21"])
      expect(grants.find(issued.grant.id).last_used_at).not_to be_nil
    end
  end

  describe "an ended grant" do
    it "answers 401 token_revoked once revoked, on the API and as a page" do
      token
      Samagotchi::Participants.revoke(grants, session_id: session.id, state_dir: state_dir)
      status, body = json("/api/info")
      expect([status, body["error"], body["detail"]]).to eq([401, "token_revoked", "this review link was revoked by the session's owner"])
      status, _h, page = call("/")
      expect(status).to eq(401)
      expect(page).to include("This review link has expired or was revoked. Ask the session's owner for a new one.")
    end

    it "answers 401 token_expired after its expiry (an injected clock), and audits it once" do
      token
      now[0] += Samagotchi::Web::Grants::DEFAULT_TTL
      2.times do
        status, body = json("/api/sessions/#{session.id}")
        expect([status, body["error"], body["detail"]])
          .to eq([401, "token_expired", "this review link expired: ask the session's owner for a new one"])
      end
      expect(audit.count { |line| line["event"] == "expired" }).to eq(1)
    end

    it "is revoked when its session was archived or is gone, whoever did it" do
      token
      Samagotchi::ArchiveStore.archive(session.id, state_dir: state_dir)
      expect(json("/api/info").last["error"]).to eq("token_revoked")
      expect(grants.find(issued.grant.id).revoked_by).to eq("archive")

      gone = Samagotchi::Participants.invite(grants, session_id: other.id, name: "Kim", state_dir: state_dir)
      File.delete(Samagotchi::Session.session_file(other.id, state_dir: state_dir))
      expect(json("/api/info", bearer: gone.token).last["error"]).to eq("token_revoked")
      expect(grants.find(gone.grant.id).revoked_by).to eq("gone")
    end

    it "is a plain 401 for a token no grant was issued for" do
      expect(json("/api/info", bearer: "chp_#{"x" * 43}").last["error"]).to eq("unauthorized")
    end
  end

  describe "a participant's stream (#stream_running)" do
    it "runs while the grant works and stops once it is revoked or expired; the owner's follows the server only" do
      principal = app.send(:principal_for, Rack::Request.new(Rack::MockRequest.env_for("/", "HTTP_AUTHORIZATION" => "Bearer #{token}",
                                                                                               "REMOTE_ADDR" => phone)))
      running = app.send(:stream_running, principal)
      expect(running.call).to be(true)
      Samagotchi::Participants.revoke(grants, session_id: session.id, state_dir: state_dir)
      expect(running.call).to be(false)

      other_grant = Samagotchi::Participants.invite(grants, session_id: session.id, name: "Kim", state_dir: state_dir)
      expiring = app.send(:stream_running, Samagotchi::Web::Principal.new(kind: :participant, grant: other_grant.grant))
      expect(expiring.call).to be(true)
      now[0] += Samagotchi::Web::Grants::DEFAULT_TTL
      expect(expiring.call).to be(false)

      expect(app.send(:stream_running, Samagotchi::Web::Principal::OWNER).call).to be(true)
    end
  end

  it "leaves the owner's requests as they were (loopback, and the owner's token on the LAN)" do
    token
    expect(call("/", peer: "127.0.0.1", bearer: nil)[2]).to include("owner page")
    expect(call("/", bearer: owner_token)[2]).to include("owner page")
    expect(json("/api/info", bearer: owner_token).last.keys).to include("pid", "cwd", "lan")
  end
end
