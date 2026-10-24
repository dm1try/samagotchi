# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"
require "webrick"

require "samagotchi/web/app"
require "samagotchi/web/grants"
require "samagotchi/web/public_url"
require "samagotchi/web/server"
require "samagotchi/web/session_hub"
require "samagotchi/participants"

# chi web behind an auth proxy (web.public_url, Web::ProxyGate). The rows
# are the spike's matrix (p6-local-spike.md §2 Q2, §7): a request through
# the proxy carries a trace (oauth2-proxy always adds X-Forwarded-For) and
# the identity header the proxy sets; with public_url every request needs a
# token, this machine's too.
RSpec.describe Samagotchi::Web::App, "behind an auth proxy" do
  let(:owner_token) { "t0ken-t0ken-t0ken-t0ken-t0ken-t0ken-t0ken" }
  let(:public_host) { "47731.pod.test:8543" }
  let(:origin) { "https://#{public_host}" }
  let(:identity_header) { "X-Forwarded-Email" }
  let(:owner) { "owner@pod.test" }
  let(:public_url) do
    Samagotchi::Web::PublicUrl.from_config(url: origin, identity_header: identity_header, owner: owner)
  end
  let(:root) { Dir.mktmpdir("web-proxy") }
  let(:state_dir) { File.join(root, "samagotchi", "sessions") }
  let(:public_dir) do
    Dir.mktmpdir("web-proxy-public").tap do |dir|
      File.write(File.join(dir, "index.html"), "<html><body>owner page</body></html>")
      File.write(File.join(dir, "participant.html"), "<html><body>participant page</body></html>")
    end
  end
  let(:grants) { Samagotchi::Web::Grants.new(Samagotchi::Web::Grants.path(state_dir: state_dir)) }
  let(:app) do
    described_class.new(state_dir: state_dir, public_dir: public_dir, bridge_wait_timeout: 0, grants: grants,
                        hub: Samagotchi::Web::SessionHub.new(state_dir: state_dir),
                        public_url: public_url, public_token: owner_token)
  end
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: root).tap do |s|
      s.title = "plan review"
      s.save(state_dir: state_dir)
      FileUtils.mkdir_p(Samagotchi::Session.session_dir(s.id, state_dir: state_dir))
    end
  end
  let(:issued) { Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex", state_dir: state_dir) }

  after do
    FileUtils.remove_entry(root)
    FileUtils.remove_entry(public_dir)
  end

  # +headers+: [name, value] pairs as a client or proxy sends them. The env
  # is what WEBrick makes of them: a repeated name joined with ", ", two
  # names folding to one key the last one winning, the raw names beside.
  def env_for(path, method: "GET", host: public_host, headers: [], peer: "127.0.0.1", raw: true, body: nil)
    env = Rack::MockRequest.env_for(path, method: method, input: body)
    env["REMOTE_ADDR"] = peer
    names = {}
    ([["Host", host]] + headers).each do |name, value|
      key = name.downcase
      names[key] = names.key?(key) ? "#{names[key]}, #{value}" : value
    end
    names.each { |name, value| env[name == "host" ? "HTTP_HOST" : Samagotchi::Web::PublicUrl.env_key(name)] = value }
    env[Samagotchi::Web::ProxyGate::RAW_NAMES_ENV] = names.keys if raw
    env
  end

  def call(path, **)
    status, headers, chunks = app.call(env_for(path, **))
    text = +""
    chunks.each { |c| text << c } unless headers["Content-Type"].to_s.start_with?("text/event-stream")
    [status, headers, text]
  end

  # What oauth2-proxy sends upstream for a signed-in +email+ (its XFF and
  # identity), plus the client's own headers.
  def proxied(email = owner, extra = []) = [["X-Forwarded-For", "203.0.113.9"], *([[identity_header, email]] if email), *extra]
  def bearer(value = owner_token) = ["Authorization", "Bearer #{value}"]
  def detail(body) = JSON.parse(body)["detail"]

  describe "the owner (identity AND token)" do
    it "is the owner with the owner's identity and the token (Bearer or the __Host- cookie)" do
      expect(call("/api/sessions", headers: proxied(owner, [bearer])).first).to eq(200)
      expect(call("/api/sessions", headers: proxied(owner, [["Cookie", "__Host-chi_token=#{owner_token}"]])).first).to eq(200)
      expect(call("/api/sessions", headers: proxied("Owner@Pod.Test", [bearer])).first).to eq(200)
    end

    it "is refused with the identity but no token, naming the identity" do
      status, _, body = call("/api/sessions", headers: proxied)
      expect(status).to eq(401)
      expect(detail(body)).to eq("chi web behind the proxy: no token (identity owner@pod.test)")
    end

    it "is refused with the token and another identity, or none" do
      status, _, body = call("/api/sessions", headers: proxied("alex@pod.test", [bearer]))
      expect([status, detail(body)]).to eq([401, "chi web behind the proxy: owner token with identity alex@pod.test"])
      status, _, body = call("/api/sessions", headers: proxied(nil, [bearer]))
      expect([status, detail(body)]).to eq([401, "chi web behind the proxy: owner token with identity (none)"])
    end

    it "doesn't take the LAN cookie through the proxy (chi_token is this machine's http cookie)" do
      expect(call("/api/sessions", headers: proxied(owner, [["Cookie", "chi_token=#{owner_token}"]])).first).to eq(401)
    end

    it "refuses an identity header repeated, with a comma, empty, under two names or with an underscore" do
      cases = {
        [[identity_header, owner], [identity_header, "alex@pod.test"]] => "repeated or with a comma",
        [[identity_header, "owner@pod.test,alex@pod.test"]] => "repeated or with a comma",
        [[identity_header, " "]] => "identity header empty",
        [[identity_header, "alex@pod.test"], ["X_Forwarded_Email", owner]] => "under 2 names (x-forwarded-email, x_forwarded_email)",
        [["X_Forwarded_Email", owner]] => "with an underscore (x_forwarded_email)"
      }
      cases.each do |identity, words|
        status, _, body = call("/api/sessions", headers: [["X-Forwarded-For", "203.0.113.9"], *identity, bearer])
        expect(status).to eq(401), identity.inspect
        expect(detail(body)).to include(words), identity.inspect
      end
    end

    it "refuses the identity when the server gave no raw header names to check it against" do
      expect(call("/api/sessions", headers: proxied(owner, [bearer]), raw: false).first).to eq(401)
    end

    it "is nobody by identity when web.proxy.owner is unset" do
      public_url = Samagotchi::Web::PublicUrl.from_config(url: origin, identity_header: identity_header)
      app = described_class.new(state_dir: state_dir, public_dir: public_dir, grants: grants, public_url: public_url,
                                public_token: owner_token, hub: Samagotchi::Web::SessionHub.new(state_dir: state_dir))
      expect(app.call(env_for("/api/sessions", headers: proxied(owner, [bearer]))).first).to eq(401)
    end
  end

  describe "token only (web.proxy.identity_header unset)" do
    let(:identity_header) { nil }
    let(:owner) { nil }

    it "is the owner with the token alone, whatever identity headers come along" do
      expect(call("/api/sessions", headers: [["X-Forwarded-For", "203.0.113.9"], bearer]).first).to eq(200)
      expect(call("/api/sessions", headers: [["X-Forwarded-For", "203.0.113.9"], ["X-Forwarded-Email", "x@y"], bearer]).first)
        .to eq(200)
      expect(call("/api/sessions", headers: [["X-Forwarded-For", "203.0.113.9"]]).first).to eq(401)
    end

    it "says once that the proxy sends an identity header chi could check" do
      allow(Samagotchi::Log).to receive(:info).and_call_original
      2.times { call("/api/sessions", headers: [["X-Forwarded-For", "1.2.3.4"], ["X-Forwarded-Email", "a@b"], bearer]) }
      expect(Samagotchi::Log).to have_received(:info).with(:web, "proxy_identity_header", hash_including(sent: "X-Forwarded-Email"))
                                                     .once
    end
  end

  describe "the misconfiguration hint (a header the proxy doesn't send)" do
    let(:identity_header) { "X-Auth-Request-Email" }

    it "names the header the proxy sends in the owner's 401 and warns once" do
      allow(Samagotchi::Log).to receive(:warn).and_call_original
      2.times do
        status, _, body = call("/api/sessions", headers: [["X-Forwarded-For", "1.2.3.4"], ["X-Forwarded-Email", owner], bearer])
        expect(status).to eq(401)
        expect(detail(body)).to eq("chi web behind the proxy: owner token with identity (none); the proxy sends " \
                                   "X-Forwarded-Email, not X-Auth-Request-Email")
      end
      expect(Samagotchi::Log).to have_received(:warn).with(:web, "proxy_identity_header", hash_including(sent: "X-Forwarded-Email"))
                                                     .once
    end
  end

  describe "this machine (no proxy trace, D-d (b): the token everywhere)" do
    def local(path, **) = call(path, host: "127.0.0.1:4567", **)

    it "needs the token on loopback too, and the token alone is the owner there" do
      status, _, body = local("/api/sessions")
      expect([status, detail(body)]).to eq([401, "chi web with web.public_url needs its access token, on this machine too"])
      expect(local("/api/sessions", headers: [bearer]).first).to eq(200)
      expect(local("/api/info", headers: [["Cookie", "chi_token=#{owner_token}"]]).first).to eq(200)
    end

    it "trades ?token= for the http cookie with a relative Location" do
      status, headers, = local("/?token=#{owner_token}&dir=/r")
      expect(status).to eq(303)
      expect(headers["Location"]).to eq("/?dir=/r")
      expect(headers["Set-Cookie"]).to start_with("chi_token=#{owner_token}; HttpOnly")
    end

    it "takes the public Host as proxied even without any other trace (a proxy that passes Host and adds nothing)" do
      expect(call("/api/sessions", headers: [bearer]).first).to eq(401)
      expect(call("/api/sessions", headers: [bearer, [identity_header, owner]]).first).to eq(200)
    end

    it "takes any known trace as proxied: Forwarded, X-Real-IP, a Cf-/Tailscale- header, an underscore twin" do
      [%w[Forwarded for=1.2.3.4], %w[X-Real-IP 1.2.3.4], %w[Cf-Connecting-Ip 1.2.3.4], %w[Tailscale-User-Login a@b],
       %w[X_Forwarded_For 1.2.3.4]].each do |trace|
        expect(local("/api/sessions", headers: [trace, bearer]).first).to eq(401), trace.inspect
      end
    end
  end

  describe "the token trade through the proxy" do
    it "sets the host-only Secure __Host- cookie and an absolute Location from public_url, never X-Forwarded-Host" do
      status, headers, = call("/?token=#{owner_token}&dir=/r",
                              headers: proxied(owner, [%w[X-Forwarded-Host evil.example], %w[X-Forwarded-Proto http]]))
      expect(status).to eq(303)
      expect(headers["Location"]).to eq("#{origin}/?dir=/r")
      expect(headers["Set-Cookie"]).to eq("__Host-chi_token=#{owner_token}; Secure; HttpOnly; SameSite=Lax; Path=/; Max-Age=34560000")
      expect(headers["Set-Cookie"]).not_to include("Domain")
    end

    it "trades nothing for a refused identity" do
      expect(call("/?token=#{owner_token}", headers: proxied("alex@pod.test")).first).to eq(401)
    end
  end

  describe "Host and Origin" do
    it "answers the public host exactly (with its port) and nothing like it" do
      expect(call("/api/info", host: "47731.pod.test", headers: proxied(owner, [bearer])).first).to eq(403)
      expect(call("/api/info", host: "evil.pod.test:8543", headers: proxied(owner, [bearer])).first).to eq(403)
      status, _, body = call("/api/info", host: "evil.example", headers: proxied(owner, [bearer]))
      expect([status, detail(body)]).to eq([403, "only the host names 127.0.0.1, [::1], localhost and #{public_host} are answered"])
    end

    it "takes a POST from the public origin, refuses a sibling port on the same site" do
      ok = call("/api/render", method: "POST", body: '{"text":"x"}',
                               headers: proxied(owner, [bearer, ["Origin", origin], %w[Sec-Fetch-Site same-origin],
                                                        ["Content-Type", "application/json"]]))
      expect(ok.first).to eq(200)
      sibling = call("/api/render", method: "POST", body: '{"text":"x"}',
                                    headers: proxied(owner, [bearer, ["Origin", "https://4599.pod.test:8543"],
                                                             %w[Sec-Fetch-Site same-site]]))
      expect(sibling.first).to eq(403)
      expect(JSON.parse(sibling.last)["error"]).to eq("cross_origin")
    end

    it "never offers a proxied viewer the editor (not a viewer on this machine)" do
      req = Rack::Request.new(env_for("/", headers: proxied))
      expect(app.send(:local_viewer?, req)).to be(false)
      expect(app.send(:local_viewer?, Rack::Request.new(env_for("/", host: "127.0.0.1:4567")))).to be(true)
    end
  end

  describe "participants" do
    it "is the participant with a grant through the proxy, whatever their identity" do
      grant_token = issued.token
      expect(call("/api/sessions/#{session.id}/review", headers: proxied("alex@pod.test", [bearer(grant_token)])).first)
        .to eq(200)
      expect(call("/api/sessions", headers: proxied("alex@pod.test", [bearer(grant_token)])).first).to eq(403)
      expect(call("/api/sessions", headers: proxied("alex@pod.test")).first).to eq(401)
    end

    it "honours a grant bound to an identity only proxied and only for that identity" do
      id = issued.grant.id
      grants.send(:update) { |all| [all.map { |g| g.id == id ? g.with(identity: "alex@pod.test") : g }, nil] }
      path = "/api/sessions/#{session.id}/review"
      expect(call(path, headers: proxied("alex@pod.test", [bearer(issued.token)])).first).to eq(200)
      status, _, body = call(path, headers: proxied(owner, [bearer(issued.token)]))
      expect([status, detail(body)]).to eq([401, "chi web behind the proxy: grant #{id} is bound to another identity than #{owner}"])
      expect(call(path, host: "127.0.0.1:4567", headers: [bearer(issued.token)]).first).to eq(401)
    end

    it "makes the invite link the public one, the token in the fragment" do
      status, _, body = call("/api/sessions/#{session.id}/participants", method: "POST", body: '{"name":"Sam"}',
                                                                         headers: proxied(owner, [bearer]))
      expect(status).to eq(201)
      answer = JSON.parse(body)
      expect(answer["link"]).to eq("#{origin}/#token=#{answer["token"]}&s=#{session.id}")
      expect(answer["lan"]).to be(true)
    end

    it "keeps the owner's token out of what a participant reads (a secret of their view)" do
      req = Rack::Request.new(env_for("/", headers: proxied("alex@pod.test", [bearer(issued.token)])))
      req.env[described_class::PRINCIPAL_ENV] = app.send(:principal_for, req)
      expect(app.send(:participant_viewer, req, session).secrets).to eq([owner_token])
    end
  end

  it "tells the owner's /api/info the public origin" do
    _, _, body = call("/api/info", headers: proxied(owner, [bearer]))
    expect(JSON.parse(body)["public_url"]).to eq(origin)
  end

  describe "the WEBrick hook (Server prepends ProxyGate::RawHeaderNames)" do
    it "puts the raw header names next to the env, where the last of two folding names wins" do
      req = WEBrick::HTTPRequest.new(WEBrick::Config::HTTP)
      req.parse(StringIO.new("GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-Email: a@x\r\nX_Forwarded_Email: b@x\r\n\r\n"))
      vars = req.meta_vars
      expect(vars[Samagotchi::Web::ProxyGate::RAW_NAMES_ENV]).to eq(%w[host x-forwarded-email x_forwarded_email])
      expect(vars["HTTP_X_FORWARDED_EMAIL"]).to eq("b@x")
    end
  end
end
