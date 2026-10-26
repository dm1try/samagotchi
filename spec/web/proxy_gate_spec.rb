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
      File.write(File.join(dir, "token_fragment.js"), "export function tradeFragmentToken() {}")
      File.write(File.join(dir, "app.js"), "// app")
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
    names.each do |name, value|
      key = { "host" => "HTTP_HOST", "content-type" => "CONTENT_TYPE" }.fetch(name) { Samagotchi::Web::PublicUrl.env_key(name) }
      env[key] = value
    end
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

  # web.host lan + web.public_url: a phone on the LAN keeps the LAN's
  # token link and cookie; Bearer-only is this machine's (a 127.0.0.1
  # cookie goes to every local port), not a LAN peer's.
  describe "a LAN peer with both LAN mode and public_url" do
    let(:lan_app) do
      described_class.new(state_dir: state_dir, public_dir: public_dir, bridge_wait_timeout: 0, grants: grants,
                          hub: Samagotchi::Web::SessionHub.new(state_dir: state_dir), lan: { ip: "192.168.1.55", token: owner_token },
                          public_url: public_url, public_token: owner_token)
    end

    def phone(path, **) = lan_app.call(env_for(path, host: "192.168.1.55:4567", peer: "192.168.1.77", **))

    it "trades the LAN link's ?token= for the chi_token cookie, and takes that cookie" do
      status, headers, = phone("/?token=#{owner_token}")
      expect(status).to eq(303)
      expect(headers["Set-Cookie"]).to start_with("chi_token=#{owner_token}; HttpOnly")
      expect(phone("/api/sessions", headers: [["Cookie", "chi_token=#{owner_token}"]]).first).to eq(200)
    end

    it "keeps this machine's loopback Bearer-only" do
      expect(lan_app.call(env_for("/api/sessions", host: "127.0.0.1:4567", headers: [["Cookie", "chi_token=#{owner_token}"]])).first)
        .to eq(401)
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
      expect([status, detail(body)]).to eq([401, "chi web with web.public_url needs its access token, on this machine too; " \
                                            "open its public address #{origin}/ instead"])
      expect(local("/api/sessions", headers: [bearer]).first).to eq(200)
    end

    # The paste box is a dead end here: loopback takes the token as Bearer
    # only, so a traded cookie is never sent back. The page says where to open
    # chi web instead (docs/configuration.md, "Every request needs the access
    # token").
    it "the 401 page of a browser on this machine links the public address, and has no paste box" do
      status, headers, body = local("/")

      expect(status).to eq(401)
      expect(headers["Content-Type"]).to start_with("text/html")
      expect(body).to include("public address").and include(%(href="#{origin}/"))
      expect(body).not_to include("<form")
      expect(body).not_to include("<input")
      # The address is not a secret; a token or a link code is.
      expect(body).not_to include(owner_token)
      expect(body).not_to include("#code=")
    end

    it "links it for every refused page path, not just the page itself" do
      %w[/ /index.html /nope /app.js].each do |path|
        status, _, body = local(path)
        expect([status, body.include?(%(href="#{origin}/"))]).to eq([401, true]), path
      end
    end

    it "escapes the address from config, and keeps the link without a token or a code" do
      odd = Samagotchi::Web::PublicUrl.new(origin: 'https://a"b&c.test', host: 'a"b&c.test', identity_header: nil, owner: nil)
      other = described_class.new(state_dir: state_dir, public_dir: public_dir, bridge_wait_timeout: 0, grants: grants,
                                  hub: Samagotchi::Web::SessionHub.new(state_dir: state_dir),
                                  public_url: odd, public_token: owner_token)

      status, _, chunks = other.call(env_for("/", host: "127.0.0.1:4567"))
      body = chunks.join
      expect(status).to eq(401)
      expect(body).to include(%(href="https://a&quot;b&amp;c.test/"))
      expect(body).not_to include(%(href="https://a"b&c))
      expect(body).not_to include(owner_token)
    end

    # A cookie for 127.0.0.1 would go to every server on any local port.
    it "takes the Bearer header only: no cookie, and no trade that would set one" do
      expect(local("/api/sessions", headers: [["Cookie", "chi_token=#{owner_token}"]]).first).to eq(401)
      status, headers, = local("/?token=#{owner_token}&dir=/r")
      expect([status, headers["Set-Cookie"]]).to eq([401, nil])
      status, headers, = local("/api/token", method: "POST", body: JSON.generate(token: owner_token),
                                             headers: [["Content-Type", "application/json"]])
      expect([status, headers["Set-Cookie"]]).to eq([401, nil])
    end

    # InfoProbe sends no token (whatever listens on the port may not be chi
    # web): the fields it checks, nothing secret.
    it "answers chi's token-less probe of /api/info with its checked fields only" do
      status, _, body = local("/api/info")
      expect(status).to eq(200)
      expect(JSON.parse(body).keys).to contain_exactly("app", "version", "pid", "features", "lan")
      expect(JSON.parse(local("/api/info", headers: [bearer]).last).keys).to include("cwd")
      expect(local("/api/info", headers: [%w[Cookie x=1]]).first).to eq(401)
      expect(call("/api/info", headers: proxied).first).to eq(401)
      expect(local("/api/info", peer: "192.0.2.4").first).to eq(401)
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

  # Through the proxy there is no GET trade: a ?token= link would ride the
  # sign-in redirect, and a crafted one (a participant's) would replace the
  # owner's cookie without a word. Codes and the paste box's POST cover it.
  describe "a ?token= page through the proxy" do
    it "trades nothing: the owner's cookie stays, no Set-Cookie" do
      grant = issued.token
      status, headers, = call("/?token=#{grant}", headers: proxied(owner, [["Cookie", "__Host-chi_token=#{owner_token}"]]))
      expect([status, headers["Set-Cookie"]]).to eq([200, nil])
      expect(call("/?token=#{owner_token}", headers: proxied).first).to eq(401)
    end

    it "the paste box's trade sets the host-only Secure __Host- cookie, its Location from public_url, never X-Forwarded-Host" do
      status, headers, = call("/api/token", method: "POST", body: "token=#{owner_token}",
                                            headers: proxied(owner, [%w[Content-Type application/x-www-form-urlencoded],
                                                                     %w[X-Forwarded-Host evil.example], %w[X-Forwarded-Proto http]]))
      expect(status).to eq(303)
      expect(headers["Location"]).to eq("#{origin}/")
      expect(headers["Set-Cookie"]).to eq("__Host-chi_token=#{owner_token}; Secure; HttpOnly; SameSite=Lax; Path=/; Max-Age=34560000")
    end
  end

  describe "the fragment trade (POST /api/token: a link's one-time #code=, or a pasted token)" do
    def trade(token, headers: proxied, **) = call("/api/token", method: "POST", body: JSON.generate(token: token),
                                                                  headers: [["Content-Type", "application/json"], *headers], **)

    def trade_code(code, headers: proxied) = call("/api/token", method: "POST", body: JSON.generate(code: code),
                                                                  headers: [["Content-Type", "application/json"], *headers])

    def codes = app.instance_variable_get(:@link_codes)

    it "trades an owner's code once, for the owner's cookie, with the owner's identity" do
      code = codes.issue(kind: :owner, ttl: 600)
      status, headers, = trade_code(code)
      expect(status).to eq(204)
      expect(headers["Set-Cookie"]).to start_with("__Host-chi_token=#{owner_token};")
      expect(trade_code(code).first).to eq(401)
    end

    it "uses up an owner's code someone else presents, and gives them nothing" do
      code = codes.issue(kind: :owner, ttl: 600)
      status, headers, = trade_code(code, headers: proxied("alex@pod.test"))
      expect([status, headers["Set-Cookie"]]).to eq([401, nil])
      expect(trade_code(code).first).to eq(401)
    end

    it "trades a grant's code for the participant's cookie, and refuses an unknown or expired one" do
      code = codes.issue(kind: :grant, token: issued.token, ttl: 600)
      _, headers, = trade_code(code, headers: proxied("alex@pod.test"))
      expect(headers["Set-Cookie"]).to start_with("__Host-chi_token=#{issued.token};")
      expect(trade_code("chc_#{"x" * 43}").first).to eq(401)
      expired = codes.issue(kind: :owner, ttl: -1)
      expect(trade_code(expired).first).to eq(401)
    end

    # Decision C, the red team's forwarded link: Alex's bound link reaches
    # Mallory (forwarded, a shared screen). Mallory signed in as herself
    # gets the refusal, the code stays, and Alex's own open still works.
    describe "a bound grant's code" do
      let(:bound) do
        Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex", identity: "alex@pod.test",
                                                public_url: public_url, state_dir: state_dir)
      end
      let(:code) { codes.issue(kind: :grant, token: bound.token, ttl: 600) }

      it "is refused to another identity and kept: the one it was sent to still opens it, once" do
        status, headers, body = trade_code(code, headers: proxied("mallory@pod.test"))
        expect([status, headers["Set-Cookie"], *JSON.parse(body).values_at("error", "detail")])
          .to eq([401, nil, "token_bound", Samagotchi::ParticipantMessages::TOKEN_BOUND])

        status, headers, = trade_code(code, headers: proxied("alex@pod.test"))
        expect(status).to eq(204)
        expect(headers["Set-Cookie"]).to start_with("__Host-chi_token=#{bound.token};")
        expect(trade_code(code, headers: proxied("alex@pod.test")).first).to eq(401)
      end

      it "is refused and kept with no identity header, or one sent twice" do
        expect(trade_code(code, headers: proxied(nil)).first).to eq(401)
        expect(trade_code(code, headers: proxied("alex@pod.test", [[identity_header, "mallory@pod.test"]])).first).to eq(401)
        expect(trade_code(code, headers: proxied("alex@pod.test")).first).to eq(204)
      end

      it "leaves an unbound grant's code as it was: anyone through the proxy uses it up" do
        unbound = codes.issue(kind: :grant, token: issued.token, ttl: 600)
        expect(trade_code(unbound, headers: proxied("mallory@pod.test")).first).to eq(204)
        expect(trade_code(unbound, headers: proxied("alex@pod.test")).first).to eq(401)
      end
    end

    it "sets the __Host- cookie for the owner's token with the owner's identity, 204 and no body" do
      status, headers, body = trade(owner_token)
      expect([status, body]).to eq([204, ""])
      expect(headers["Set-Cookie"]).to start_with("__Host-chi_token=#{owner_token}; Secure; HttpOnly; SameSite=Lax; Path=/")
    end

    it "sets a participant's grant as their cookie, and refuses a token the gate refuses" do
      _, headers, = trade(issued.token, headers: proxied("alex@pod.test"))
      expect(headers["Set-Cookie"]).to start_with("__Host-chi_token=#{issued.token};")
      status, headers, body = trade(owner_token, headers: proxied("alex@pod.test"))
      expect([status, headers["Set-Cookie"], JSON.parse(body)["error"]]).to eq([401, nil, "unauthorized"])
      expect(trade("nope").first).to eq(401)
    end

    it "is refused from another site like any POST" do
      expect(trade(owner_token, headers: proxied(owner, [%w[Origin https://evil.example], %w[Sec-Fetch-Site cross-site]])).first)
        .to eq(403)
    end

    it "serves the trade's script without a token, and the 401 page runs it" do
      expect(call("/token_fragment.js", headers: proxied).first).to eq(200)
      expect(call("/app.js", headers: proxied).first).to eq(401)
      status, _, body = call("/", headers: proxied)
      expect(status).to eq(401)
      expect(body).to include('import { tradeFragmentCode } from "/token_fragment.js";')
    end
  end

  # A GET form would put a pasted token in the URL: the proxy's access log,
  # the history, the IdP's state on a sign-in redirect.
  describe "the 401 page's paste box" do
    it "posts the token in the body to /api/token, never as a GET query" do
      _, _, body = call("/", headers: proxied)
      expect(body).to include('<form method="post" action="/api/token">')
      expect(body).not_to include('method="get"')
      # The public-address page is only for this machine's loopback.
      expect(body).not_to include("public address")
    end

    it "trades a pasted owner token for the cookie and a 303 to the public page" do
      status, headers, = call("/api/token", method: "POST", body: "token=#{owner_token}",
                                            headers: proxied(owner, [%w[Content-Type application/x-www-form-urlencoded],
                                                                     ["Origin", origin]]))
      expect(status).to eq(303)
      expect(headers["Location"]).to eq("#{origin}/")
      expect(headers["Set-Cookie"]).to start_with("__Host-chi_token=#{owner_token};")
    end
  end

  describe "Host and Origin" do
    it "answers the public host exactly (with its port) and nothing like it" do
      expect(call("/api/info", host: "47731.pod.test", headers: proxied(owner, [bearer])).first).to eq(403)
      expect(call("/api/info", host: "evil.pod.test:8543", headers: proxied(owner, [bearer])).first).to eq(403)
      status, _, body = call("/api/info", host: "evil.example", headers: proxied(owner, [bearer]))
      expect([status, detail(body)]).to eq([403, "only the host names 127.0.0.1, [::1], localhost and #{public_host} are answered"])
    end

    it "takes the public host with an explicit default port or a trailing dot (a 443 public_url)" do
      public_url = Samagotchi::Web::PublicUrl.from_config(url: "https://chi.corp.test", identity_header: identity_header, owner: owner)
      app = described_class.new(state_dir: state_dir, public_dir: public_dir, grants: grants, public_url: public_url,
                                public_token: owner_token, hub: Samagotchi::Web::SessionHub.new(state_dir: state_dir))
      ["chi.corp.test", "chi.corp.test:443", "chi.corp.test.", "CHI.corp.test.:443"].each do |host|
        expect(app.call(env_for("/api/sessions", host: host, headers: proxied(owner, [bearer]))).first).to eq(200), host
      end
      expect(app.call(env_for("/api/sessions", host: "chi.corp.test:8443", headers: proxied(owner, [bearer]))).first).to eq(403)
    end

    it "takes only the public https origin on a proxied request, never http://<public host>" do
      status, _, body = call("/api/render", method: "POST", body: '{"text":"x"}',
                                            headers: proxied(owner, [bearer, ["Origin", "http://#{public_host}"],
                                                                     ["Content-Type", "application/json"]]))
      expect([status, JSON.parse(body)["error"]]).to eq([403, "cross_origin"])
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

    # chi web on the LAN and behind a proxy at once: the proxy is on this
    # machine, so a LAN peer's proxy headers are its own words. Forged, they
    # make it neither proxied nor an identity.
    describe "a LAN peer forging the proxy's headers (web.host lan with web.public_url)" do
      let(:lan_ip) { "192.168.1.55" }
      let(:app) do
        described_class.new(state_dir: state_dir, public_dir: public_dir, bridge_wait_timeout: 0, grants: grants,
                            hub: Samagotchi::Web::SessionHub.new(state_dir: state_dir), public_url: public_url,
                            public_token: owner_token, lan: { ip: lan_ip, token: owner_token })
      end
      let(:bound) do
        Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex", identity: "alex@pod.test",
                                                public_url: public_url, state_dir: state_dir)
      end
      let(:lan) { { peer: "192.168.1.77", host: "#{lan_ip}:4567" } }

      def forged(email) = [["X-Forwarded-For", "203.0.113.9"], [identity_header, email]]

      it "is never proxied, whatever it sends: not even with the public Host" do
        req = ->(**opts) { Rack::Request.new(env_for("/", headers: forged("alex@pod.test"), **opts)) }
        expect(app.send(:proxied?, req.call(**lan))).to be(false)
        expect(app.send(:proxied?, req.call(peer: "192.168.1.77"))).to be(false)
        expect(app.send(:proxied?, req.call)).to be(true)
        expect(app.send(:proxied?, req.call(peer: "::1"))).to be(true)
        expect(app.send(:proxied?, req.call(peer: "127.0.0.2"))).to be(true)
      end

      it "gets a bound grant's token refused (token_bound), the identity header forged or not" do
        path = "/api/sessions/#{session.id}/review"
        [lan, { peer: "192.168.1.77" }].each do |where|
          status, _, body = call(path, headers: forged("alex@pod.test") + [bearer(bound.token)], **where)
          expect([status, JSON.parse(body)["error"]]).to eq([401, "token_bound"]), where.inspect
        end
        expect(call(path, headers: proxied("alex@pod.test", [bearer(bound.token)])).first).to eq(200)
      end

      it "can't spend a bound grant's code: refused and kept for the proxied account" do
        code = app.instance_variable_get(:@link_codes).issue(kind: :grant, token: bound.token, ttl: 600)
        trade = lambda do |headers, **where|
          call("/api/token", method: "POST", body: JSON.generate(code: code),
                             headers: [["Content-Type", "application/json"], *headers], **where)
        end
        status, _, body = trade.call(forged("alex@pod.test"), **lan)
        expect([status, JSON.parse(body)["error"]]).to eq([401, "token_bound"])
        expect(trade.call(proxied("alex@pod.test")).first).to eq(204)
      end

      # The owner on the LAN is the LAN token, as before this change: the
      # forged identity adds nothing, and without the token gets nothing.
      it "is the owner only with the owner's token, the identity header forged or not" do
        expect(call("/api/sessions", headers: forged(owner), **lan).first).to eq(401)
        expect(call("/api/sessions", headers: forged(owner) + [bearer], **lan).first).to eq(200)
        expect(call("/api/sessions", headers: forged("alex@pod.test") + [bearer], **lan).first).to eq(200)
      end
    end

    it "refuses an identity header that isn't ASCII (it could never match a grant or the owner)" do
      status, _, body = call("/api/sessions", headers: proxied("ow\u00e9ner@pod.test", [bearer]))
      expect([status, detail(body)]).to eq([401, "chi web behind the proxy: identity header not ASCII"])
    end

    describe "a grant bound to an identity" do
      let(:bound) do
        Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex", identity: "alex@pod.test",
                                                public_url: public_url, state_dir: state_dir)
      end
      let(:path) { "/api/sessions/#{session.id}/review" }
      let(:refused) { [401, "token_bound", Samagotchi::ParticipantMessages::TOKEN_BOUND] }

      def answer(path, **) = call(path, **).then { |status, _, body| [status, *JSON.parse(body).values_at("error", "detail")] }

      def audit = File.readlines(File.join(Samagotchi::Session.session_dir(session.id, state_dir: state_dir),
                                           Samagotchi::Participants::LOG)).map { |line| JSON.parse(line) }

      it "is honoured only proxied and only for that identity (any case)" do
        expect(call(path, headers: proxied("alex@pod.test", [bearer(bound.token)])).first).to eq(200)
        expect(call(path, headers: proxied("Alex@Pod.Test", [bearer(bound.token)])).first).to eq(200)
      end

      it "refuses another identity, no identity, and this machine's loopback with one message (token_bound)" do
        expect(answer(path, headers: proxied(owner, [bearer(bound.token)]))).to eq(refused)
        expect(answer(path, headers: proxied("mallory@pod.test", [bearer(bound.token)]))).to eq(refused)
        expect(answer(path, headers: proxied(nil, [bearer(bound.token)]))).to eq(refused)
        expect(answer(path, host: "127.0.0.1:4567", headers: [bearer(bound.token)])).to eq(refused)
        # The cookie a browser kept from when it was signed in as Alex.
        expect(answer(path, headers: proxied("mallory@pod.test", [["Cookie", "__Host-chi_token=#{bound.token}"]])))
          .to eq(refused)
      end

      it "says so on the page too, never naming either identity" do
        status, _, body = call("/", headers: proxied("mallory@pod.test", [bearer(bound.token)]))
        expect(status).to eq(401)
        expect(body).to include("This review link is for another account: open it through the proxy, signed in as the person it was sent to.")
        expect(body).not_to include("alex@pod.test")
        expect(body).not_to include("mallory@pod.test")
      end

      it "audits a bound refusal once a minute per identity, whatever path it is sent to" do
        40.times { |i| call("#{path}x#{i}", headers: proxied("mallory@pod.test", [bearer(bound.token)])) }
        expect(audit.count { |line| line["event"] == "refused" }).to eq(1)
      end

      it "audits the refusal in the session, naming who presented it, once a minute per route and identity" do
        3.times { call(path, headers: proxied("mallory@pod.test", [bearer(bound.token)])) }
        call(path, headers: proxied(nil, [bearer(bound.token)]))
        refusals = audit.select { |line| line["event"] == "refused" }
        expect(refusals.map { |line| line.slice("participant", "reason", "identity", "path") })
          .to eq([{ "participant" => bound.grant.id, "reason" => "token_bound", "identity" => "mallory@pod.test", "path" => path },
                  { "participant" => bound.grant.id, "reason" => "token_bound", "identity" => "(none)", "path" => path }])
      end
    end

    # Every proxied request comes from 127.0.0.1: a new peer is a new
    # identity there, and the audit line names it.
    it "audits each identity that uses a grant once, behind the proxy" do
      2.times { call("/api/sessions/#{session.id}/review", headers: proxied("alex@pod.test", [bearer(issued.token)])) }
      call("/api/sessions/#{session.id}/review", headers: proxied("sam@pod.test", [bearer(issued.token)]))
      peers = File.readlines(File.join(Samagotchi::Session.session_dir(session.id, state_dir: state_dir),
                                       Samagotchi::Participants::LOG)).map { |line| JSON.parse(line) }
                  .select { |line| line["event"] == "peer" }
      expect(peers.map { |line| line.slice("identity", "ip", "peer") })
        .to eq([{ "identity" => "alex@pod.test", "ip" => "127.0.0.1", "peer" => "proxy:alex@pod.test" },
                { "identity" => "sam@pod.test", "ip" => "127.0.0.1", "peer" => "proxy:sam@pod.test" }])
    end

    it "makes the invite link the public one, a one-time code for the grant in the fragment, never the token" do
      status, _, body = call("/api/sessions/#{session.id}/participants", method: "POST", body: '{"name":"Sam"}',
                                                                         headers: proxied(owner, [bearer]))
      expect(status).to eq(201)
      answer = JSON.parse(body)
      expect(answer["link"]).to match(%r{\A#{Regexp.escape(origin)}/#code=(chc_[A-Za-z0-9_-]{43})&s=#{session.id}\z})
      expect(answer["link"]).not_to include(answer["token"])
      expect(answer["lan"]).to be(true)
      code = answer["link"][/code=([^&]+)/, 1]
      expect(app.instance_variable_get(:@link_codes).redeem(code)).to eq([:grant, answer["token"]])
    end

    it "invites a participant bound to an identity, and refuses one that isn't an address" do
      path = "/api/sessions/#{session.id}/participants"
      status, _, body = call(path, method: "POST", body: '{"name":"Alex","identity":"Alex@Pod.Test"}',
                                   headers: proxied(owner, [bearer]))
      expect(status).to eq(201)
      answer = JSON.parse(body)
      expect(answer["participant"]).to include("identity" => "alex@pod.test")
      expect(grants.lookup(answer["token"]).identity).to eq("alex@pod.test")

      status, _, body = call(path, method: "POST", body: '{"name":"Kim","identity":"kim"}', headers: proxied(owner, [bearer]))
      expect([status, JSON.parse(body)]).to eq([400, { "error" => "invalid_participant",
                                                       "detail" => Samagotchi::Web::Grants::BadIdentity.new.message }])
      expect(grants.list.size).to eq(1)
    end

    it "names the identity header on the owner's /api/info (the Invite dialog's email field), never a participant's" do
      _, _, body = call("/api/info", headers: proxied(owner, [bearer]))
      expect(JSON.parse(body)).to include("proxy" => { "identity_header" => identity_header })
      _, _, body = call("/api/info", headers: proxied("alex@pod.test", [bearer(issued.token)]))
      expect(JSON.parse(body)).not_to have_key("proxy")
      _, _, body = call("/api/sessions/#{session.id}/participants", headers: proxied(owner, [bearer]))
      expect(JSON.parse(body)).to include("identity_header" => identity_header)
    end

    it "keeps the owner's token out of what a participant reads (a secret of their view)" do
      req = Rack::Request.new(env_for("/", headers: proxied("alex@pod.test", [bearer(issued.token)])))
      req.env[described_class::PRINCIPAL_ENV] = app.send(:principal_for, req)
      expect(app.send(:participant_viewer, req, session).secrets).to eq([owner_token])
    end
  end

  # Every proxied request comes from 127.0.0.1: a per-peer limit would log
  # one refusal a minute for everyone behind the proxy.
  it "rate-limits the refusal's log line per client behind the proxy (its identity, else the proxy's X-Forwarded-For hop)" do
    allow(Samagotchi::Log).to receive(:warn)
    call("/api/sessions", headers: proxied("alex@pod.test"))
    call("/api/sessions", headers: proxied("alex@pod.test"))
    call("/api/sessions", headers: proxied("sam@pod.test"))
    call("/api/sessions", headers: [["X-Forwarded-For", "6.6.6.6, 203.0.113.7"]])
    call("/api/sessions", headers: [["X-Forwarded-For", "1.1.1.1, 203.0.113.7"]])
    peers = []
    expect(Samagotchi::Log).to have_received(:warn).with(:web, "unauthorized", anything).exactly(3).times do |*_, fields|
      peers << fields[:peer]
    end
    expect(peers).to contain_exactly("proxy:alex@pod.test", "proxy:sam@pod.test", "proxy:203.0.113.7")
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
