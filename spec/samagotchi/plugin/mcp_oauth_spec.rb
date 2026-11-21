# frozen_string_literal: true

require "spec_helper"
require "digest"
require "samagotchi/testing/rspec"

# The mcp bundle's sign-in (OAuth, lib/samagotchi/bundles/mcp/oauth.rb) on
# the bundle test kit: ctx.http stubbed as a provider and a remote MCP
# server (never the network), the kit's sign-ins (no port) and its
# in-memory secrets. The real sockets and the tool calls are
# mcp_bundle_sign_in_spec's.
RSpec.describe "The mcp bundle's sign-in", :bundle do
  let(:mcp_dir) { File.expand_path("../../../lib/samagotchi/bundles/mcp", __dir__) }
  let(:url) { "https://mcp.example.com/mcp" }
  let(:issuer) { "https://auth.example.com" }
  let(:resource_doc) { "https://mcp.example.com/.well-known/oauth-protected-resource/mcp" }
  let(:provider_doc) { "https://auth.example.com/.well-known/oauth-authorization-server" }
  let(:secrets_name) { "oauth-#{Digest::SHA256.hexdigest(url)[0, 16]}" }

  let(:config) { { "url" => url } }
  let(:settings) { { "servers" => { "linear" => config }, "startup_timeout" => 2 } }
  let(:bundle) { load_bundle(mcp_dir, settings: settings) }
  let(:challenge) { %(Bearer error="invalid_token", resource_metadata="#{resource_doc}") }
  let(:resource) { { resource: url, authorization_servers: [issuer], scopes_supported: %w[read write] } }
  let(:provider) do
    { issuer: issuer, authorization_endpoint: "#{issuer}/authorize", token_endpoint: "#{issuer}/token",
      registration_endpoint: "#{issuer}/register", revocation_endpoint: "#{issuer}/revoke",
      code_challenge_methods_supported: %w[plain S256], authorization_response_iss_parameter_supported: true }
  end
  # The access token the fake MCP server takes.
  let(:valid) { ["ACCESS-TOKEN-1"] }
  let(:token_answers) { [] }
  let(:logged) { [] }

  before do
    allow(Addrinfo).to receive(:getaddrinfo).and_return([Addrinfo.ip("203.0.113.7")])
    %i[debug info warn error].each do |level|
      allow(Samagotchi::Log).to receive(level).and_wrap_original do |original, *args, **fields|
        logged << [args, fields].inspect
        original.call(*args, **fields)
      end
    end
    stub_mcp
    bundle.http.stub(:get, resource_doc) { { json: resource } }
    bundle.http.stub(:get, provider_doc) { { json: provider } }
    bundle.http.stub(:post, "#{issuer}/register", status: 201, json: { client_id: "CLIENT-1" })
    bundle.http.stub(:post, "#{issuer}/token") do |request|
      form = URI.decode_www_form(request.body).to_h
      token_answers.shift || if form["grant_type"] == "authorization_code" && form["code"] == "AUTH-CODE-1"
                               { json: { access_token: "ACCESS-TOKEN-1", token_type: "bearer", refresh_token: "REFRESH-TOKEN-1",
                                         expires_in: 3600 } }
                             elsif form["grant_type"] == "refresh_token" && form["refresh_token"] == "REFRESH-TOKEN-1"
                               { json: { access_token: "ACCESS-TOKEN-2", token_type: "Bearer", refresh_token: "REFRESH-TOKEN-2",
                                         expires_in: 3600 } }
                             else
                               { status: 400, json: { error: "invalid_grant" } }
                             end
    end
    bundle.http.stub(:post, "#{issuer}/revoke", status: 200, body: "")
  end

  # The remote server: its tools with a valid token, a 401 and the
  # challenge without one.
  def stub_mcp
    bundle.http.stub(:post, url) do |request|
      next { status: 401, headers: { "WWW-Authenticate" => challenge } } unless valid.include?(request.headers["Authorization"].to_s.delete_prefix("Bearer "))

      message = request.json
      result = case message["method"]
               when "server/discover" then { supportedVersions: ["2026-07-28"] }
               when "tools/list" then { tools: [{ name: "search", inputSchema: { type: "object" } }, { name: "get" }] }
               else { content: [{ type: "text", text: "ok" }] }
               end
      { json: { jsonrpc: "2.0", id: message["id"], result: result } }
    end
  end

  def requests_to(address) = bundle.http.requests.select { |request| request.url == address }
  def form(request) = URI.decode_www_form(request.body).to_h
  def card(title) = bundle.cards.reverse.find { |c| c[:title] == title }
  def listing = bundle.command("/mcp").then { bundle.cards.reverse.find { |c| c[:id] == "mcp-servers" }[:body] }
  def query(flow) = URI.decode_www_form(URI(flow.address).query).to_h

  # /mcp login, the flow it starts and its authorize address's query.
  def login
    count = bundle.sign_ins.size
    expect(bundle.command("/mcp login linear")).to eq("Opening sign-in for linear…")
    flow = wait_for("the sign-in flow") { bundle.sign_ins[count] }
    [flow, query(flow)]
  end

  def finish(flow, params = {})
    bundle.complete_sign_in({ "code" => "AUTH-CODE-1", "state" => query(flow)["state"], "iss" => issuer }.merge(params))
  end

  def signed_in!
    bundle.run_inits
    flow, = login
    finish(flow)
    wait_for("the signed-in card") { card("Signed in to linear") }
    flow
  end

  describe "a server that answers 401" do
    it "needs sign-in after the first run: /mcp says so and one card offers the command, nothing opened" do
      expect(bundle.run_inits).to eq(["linear needs sign-in (/mcp login linear)"])

      expect(listing).to start_with("**linear**: needs sign-in (/mcp login linear)")
      sign_in = card("linear needs sign-in")
      expect(sign_in).to include(actions: [{ label: "Sign in", command: "/mcp login linear" }], between_turns: true)
      expect(bundle.sign_ins).to be_empty
      expect(bundle.http.requests.map(&:url).uniq).to eq([url])
    end

    it "shows the card once per server, none on a one-shot, and holds it on a participant's turn for the owner's" do
      bundle.set(turn_author: "p:p_0123abcd")
      bundle.run_inits
      expect(card("linear needs sign-in")).to be_nil

      bundle.set(turn_author: nil)
      bundle.fire(:after_turn, status: "completed")
      bundle.fire(:after_turn, status: "completed")
      bundle.plugin.send(:offer_sign_in, bundle.plugin.instance_variable_get(:@servers).first, bundle.plugin.instance_variable_get(:@ctx))
      expect(bundle.cards.count { |c| c[:title] == "linear needs sign-in" }).to eq(1)
    end

    it "shows no card on a one-shot" do
      bundle.set(frontend: :non_interactive)
      bundle.run_inits

      expect(card("linear needs sign-in")).to be_nil
      expect(bundle.command("/mcp login linear")).to eq("sign-in needs the web or a terminal: this run is one-shot")
    end
  end

  describe "/mcp login" do
    it "discovers, registers chi, sends the browser with PKCE and the resource, exchanges the code and connects" do
      bundle.run_inits
      flow, params = login

      expect(flow.title).to eq("Sign in to linear")
      expect(flow.address).to start_with("#{issuer}/authorize?")
      expect(params.keys).to eq(%w[response_type client_id redirect_uri state code_challenge code_challenge_method resource scope])
      expect(params).to include("response_type" => "code", "client_id" => "CLIENT-1", "redirect_uri" => flow.redirect_uri,
                                "code_challenge_method" => "S256", "resource" => url, "scope" => "read write")
      expect(params["state"]).to match(/\A[A-Za-z0-9_-]{43}\z/)
      registration = JSON.parse(requests_to("#{issuer}/register").first.body)
      expect(registration).to eq("client_name" => "chi", "redirect_uris" => ["http://127.0.0.1/callback", flow.redirect_uri],
                                 "application_type" => "native", "grant_types" => %w[authorization_code refresh_token],
                                 "response_types" => ["code"], "token_endpoint_auth_method" => "none")

      finish(flow)
      wait_for("the signed-in card") { card("Signed in to linear") }
      exchange = form(requests_to("#{issuer}/token").first)
      expect(exchange.keys).to eq(%w[grant_type code redirect_uri client_id code_verifier resource])
      expect(exchange).to include("grant_type" => "authorization_code", "code" => "AUTH-CODE-1",
                                  "redirect_uri" => flow.redirect_uri, "client_id" => "CLIENT-1", "resource" => url)
      expect([Digest::SHA256.digest(exchange["code_verifier"])].pack("m0").tr("+/", "-_").delete("="))
        .to eq(params["code_challenge"])
      expect(card("Signed in to linear")).to include(id: flow.card_id, body: "2 tools, ready to use.", between_turns: true)
      expect(card("linear needs sign-in")).to include(id: "mcp-sign-in-linear", body: "Signed in since.", actions: [])
      kept = JSON.parse(bundle.secrets[secrets_name])
      expect(kept).to include("access_token" => "ACCESS-TOKEN-1", "refresh_token" => "REFRESH-TOKEN-1", "resource" => url,
                              "issuer" => issuer, "token_endpoint" => "#{issuer}/token", "client_id" => "CLIENT-1")
      expect(kept["expires_at"]).to be_within(5).of(Time.now.to_i + 3600)
      expect(listing).to start_with("**linear**: connected (https://mcp.example.com), 2 tools")
      expect(requests_to(url).last.headers["Authorization"]).to eq("Bearer ACCESS-TOKEN-1")
    end

    it "keeps chi's registration per provider and reuses it at the next login" do
      signed_in!
      login

      expect(requests_to("#{issuer}/register").size).to eq(1)
      expect(bundle.secrets.keys).to include("client-#{Digest::SHA256.hexdigest(issuer)[0, 16]}")
    end

    it "registers once more when the provider no longer knows chi's kept client, then refuses a second time" do
      signed_in!
      token_answers.push({ status: 401, json: { error: "invalid_client" } }, { status: 401, json: { error: "invalid_client" } })
      first, = login
      finish(first)
      again = wait_for("a new flow") { bundle.sign_ins[2] }
      expect(card("Signing in to linear again")).to include(id: first.card_id)
      finish(again)

      wait_for("the refusal") { card("Sign-in to linear failed") }
      expect(card("Sign-in to linear failed")).to include(id: again.card_id, level: :warn,
                                                          body: "linear's provider refused chi's client (invalid_client)")
      expect(requests_to("#{issuer}/register").size).to eq(2)
    end

    it "asks for the challenge's scope over the metadata's, and config's over both" do
      bundle.run_inits
      valid.clear
      challenge.replace(%(Basic realm="x", Bearer resource_metadata="#{resource_doc}", scope="read:issues"))
      _, params = login
      expect(params["scope"]).to eq("read:issues")
    end

    context "with oauth: scopes:" do
      let(:config) { { "url" => url, "oauth" => { "scopes" => %w[a b] } } }

      it "asks for them" do
        bundle.run_inits
        _, params = login
        expect(params["scope"]).to eq("a b")
      end
    end

    it "finds the sign-in data at the well-known addresses without a header: the path's first, then the root's" do
      challenge.replace("Bearer")
      bundle.http.stub(:get, resource_doc, status: 404, body: "")
      bundle.http.stub(:get, "https://mcp.example.com/.well-known/oauth-protected-resource", json: resource)
      bundle.run_inits
      login

      expect(bundle.http.requests.map(&:url).grep(/well-known/).first(2)).to eq([resource_doc, "https://mcp.example.com/.well-known/oauth-protected-resource"])
    end

    {
      "sign-in data for another address" => [-> { resource[:resource] = "https://other.example.com/mcp" },
                                             "linear's sign-in data is for another address"],
      "a provider's metadata for another provider" => [-> { provider[:issuer] = "https://evil.example.com" },
                                                       "linear's provider metadata is for another provider"],
      "no S256" => [-> { provider[:code_challenge_methods_supported] = ["plain"] },
                    "linear's sign-in provider doesn't offer PKCE (S256): chi can't sign in there"],
      "no PKCE methods at all" => [-> { provider.delete(:code_challenge_methods_supported) },
                                   "linear's sign-in provider doesn't offer PKCE (S256): chi can't sign in there"],
      "an http endpoint" => [-> { provider[:token_endpoint] = "http://auth.example.com/token" },
                             "linear's token endpoint isn't https (http://auth.example.com)"],
      "an internal provider" => [-> { resource[:authorization_servers] = ["https://10.0.0.5"] },
                                 "linear's sign-in provider is an internal address (https://10.0.0.5)"],
      "no registration and no client" => [-> { provider.delete(:registration_endpoint) },
                                          "linear's sign-in provider needs a client you register yourself: set oauth: client_id: " \
                                          "and issuer: (and redirect_port: when it wants one exact redirect address)"]
    }.each do |what, (change, line)|
      it "refuses #{what} on a card, before any browser" do
        instance_exec(&change)
        bundle.run_inits
        bundle.command("/mcp login linear")

        wait_for("the refusal") { card("Sign-in to linear failed") }
        expect(card("Sign-in to linear failed")).to include(body: line, level: :warn)
        expect(bundle.sign_ins).to be_empty
      end
    end

    it "refuses a name that resolves to an internal address" do
      allow(Addrinfo).to receive(:getaddrinfo).with("auth.example.com", any_args).and_return([Addrinfo.ip("192.168.1.9")])
      bundle.run_inits
      bundle.command("/mcp login linear")

      wait_for("the refusal") { card("Sign-in to linear failed") }
      expect(card("Sign-in to linear failed")[:body]).to eq("linear's sign-in provider is an internal address (https://auth.example.com)")
    end

    {
      "a redirect" => [{ status: 302, headers: { "Location" => "https://elsewhere.example.com/x" } },
                       "linear asks for sign-in but gives no sign-in data (https://mcp.example.com)"],
      "a document over 256 KB" => [{ chunks: Array.new(5) { "x" * 60_000 } }, "linear's sign-in data is larger than 256 KB"],
      "a document that isn't an object" => [{ json: [1, 2] }, "linear's sign-in data isn't a JSON object"]
    }.each do |what, (answer, line)|
      it "refuses #{what} for the sign-in data" do
        bundle.http.stub(:get, resource_doc) { answer }
        bundle.run_inits
        bundle.command("/mcp login linear")

        wait_for("the refusal") { card("Sign-in to linear failed") }
        expect(card("Sign-in to linear failed")[:body]).to eq(line)
      end
    end

    describe "the callback" do
      before { bundle.run_inits }

      it "shows the provider's error code and at most 200 plain characters of its description" do
        flow, = login
        finish(flow, "code" => "", "error" => "access_denied", "error_description" => "No\u0007 #{"x" * 300}")

        wait_for("the refusal") { card("Sign-in to linear failed") }
        expect(card("Sign-in to linear failed")[:body]).to eq("the provider refused: access_denied: No #{"x" * 197}")
        expect(bundle.secrets).not_to have_key(secrets_name)
      end

      it "refuses another provider's iss without showing its error, and a missing one when the provider names it" do
        flow, = login
        finish(flow, "iss" => "https://evil.example.com", "error" => "SHOWN-ERROR")
        wait_for("the refusal") { card("Sign-in to linear failed") }
        expect(card("Sign-in to linear failed")[:body]).to eq("the sign-in answer came from another provider")
        expect(bundle.cards.map { |c| c[:body] }.join).not_to include("SHOWN-ERROR")

        flow, = login
        bundle.complete_sign_in("code" => "AUTH-CODE-1", "state" => query(flow)["state"])
        wait_for("the second refusal") { bundle.cards.count { |c| c[:title] == "Sign-in to linear failed" } == 2 }
        expect(card("Sign-in to linear failed")[:body]).to eq("the sign-in answer doesn't name its provider (iss)")
        expect(requests_to("#{issuer}/token")).to be_empty
      end

      it "ignores a wrong state (core's check) and refuses an answer without a code" do
        flow, = login
        expect(bundle.complete_sign_in("code" => "AUTH-CODE-1", "state" => "wrong", "iss" => issuer)).to be(false)
        finish(flow, "code" => "")

        wait_for("the refusal") { card("Sign-in to linear failed") }
        expect(card("Sign-in to linear failed")[:body]).to eq("the sign-in answer has no code")
      end

      it "shows the exchange's OAuth error code only" do
        token_answers << { status: 400, json: { error: "invalid_grant", error_description: "SECRET-ISH detail" } }
        flow, = login
        finish(flow)

        wait_for("the refusal") { card("Sign-in to linear failed") }
        expect(card("Sign-in to linear failed")[:body]).to eq("linear's sign-in provider gave no token (invalid_grant)")
      end

      it "keeps nothing when the flow times out, and core's card stays" do
        login
        bundle.fail_sign_in(:timed_out)

        expect(wait_until(timeout: 0.3) { card("Sign-in to linear failed") }).to be_nil # wait-ok: nothing comes
        expect(card("Sign-in timed out")).not_to be_nil
        expect(bundle.secrets).to be_empty.or(satisfy { |kept| !kept.key?(secrets_name) })
      end
    end

    describe "refusals" do
      let(:settings) do
        { "servers" => { "linear" => config, "local" => { "command" => ["true"] },
                         "github" => { "url" => "https://api.example.com/mcp", "bearer_token_env" => "GH_TOKEN" } },
          "startup_timeout" => 2 }
      end

      it "answers one line for an unknown, a local or a static-token server, and for a second login while one waits" do
        bundle.http.stub(:post, "https://api.example.com/mcp", status: 401)
        bundle.plugin.send(:boot, bundle.plugin.instance_variable_get(:@servers).first, bundle.plugin.instance_variable_get(:@ctx))

        expect(bundle.command("/mcp login nope")).to eq("no MCP server nope (linear, local, github)")
        expect(bundle.command("/mcp login local")).to eq("local is a local server: sign-in is for remote ones (url:)")
        expect(bundle.command("/mcp login github"))
          .to eq("github has a static token (bearer_token_env: or an Authorization header): it doesn't sign in")
        expect(bundle.command("/mcp login")).to eq("usage: /mcp login NAME")
        login
        expect(bundle.command("/mcp login linear"))
          .to eq("a sign-in to linear is already waiting: finish it in the browser, or let it time out")
      end
    end

    context "with a client registered by hand" do
      let(:config) do
        { "url" => url, "oauth" => { "client_id" => "MY-CLIENT", "issuer" => issuer, "client_secret_env" => "LINEAR_SECRET" } }
      end

      around { |example| with_env("LINEAR_SECRET" => "CLIENT-SECRET-1") { example.run } }

      it "signs in as it, its secret sent to the token endpoint only" do
        flow = signed_in!

        expect(query(flow)["client_id"]).to eq("MY-CLIENT")
        expect(form(requests_to("#{issuer}/token").first)).to include("client_id" => "MY-CLIENT", "client_secret" => "CLIENT-SECRET-1")
        others = bundle.http.requests.reject { |request| request.url == "#{issuer}/token" }
        expect(others.map { |request| [request.url, request.headers, request.body].inspect }.join).not_to include("CLIENT-SECRET-1")
        expect(flow.address).not_to include("CLIENT-SECRET-1")
        expect(requests_to("#{issuer}/register")).to be_empty
        expect(JSON.parse(bundle.secrets[secrets_name])).not_to have_key("client_secret")
      end

      it "refuses when the server now names another provider" do
        resource[:authorization_servers] = ["https://other-auth.example.com"]
        bundle.run_inits
        bundle.command("/mcp login linear")

        wait_for("the refusal") { card("Sign-in to linear failed") }
        expect(card("Sign-in to linear failed")[:body])
          .to eq("linear now points at another sign-in provider (https://other-auth.example.com); your client is registered " \
                 "with #{issuer}")
      end
    end
  end

  describe "chi's client document (CIMD)" do
    let(:document) { JSON.parse(File.read(File.expand_path("../../../pages/oauth/client.json", __dir__))) }

    it "is in the repo at the address the plugin's constant names, a loopback redirect with any port, no localhost" do
      expect(document["client_id"]).to eq(bundle.namespace::Plugin::CLIENT_METADATA_DOCUMENT)
      expect(document["client_id"]).to start_with("https://").and(end_with("/oauth/client.json"))
      expect(document).to include("client_name" => "chi", "redirect_uris" => ["http://127.0.0.1/callback"],
                                  "grant_types" => %w[authorization_code refresh_token], "response_types" => ["code"],
                                  "token_endpoint_auth_method" => "none")
      expect(bundle.namespace::Plugin::CLIENT_METADATA_URL).to be_nil # set once Pages serves it
    end

    it "isn't used while no address is set: a provider that takes it gets a registration" do
      provider[:client_id_metadata_document_supported] = true
      bundle.run_inits
      _, params = login

      expect(params["client_id"]).to eq("CLIENT-1")
    end

    context "with bundles: mcp: client_metadata_url:" do
      let(:document_url) { "https://chi.example.org/oauth/client.json" }
      let(:settings) { { "servers" => { "linear" => config }, "startup_timeout" => 2, "client_metadata_url" => document_url } }

      before { provider[:client_id_metadata_document_supported] = true }

      it "signs in as the document's address at a provider that takes it, with no registration" do
        bundle.run_inits
        flow, params = login
        finish(flow)

        wait_for("the signed-in card") { card("Signed in to linear") }
        expect(params["client_id"]).to eq(document_url)
        expect(form(requests_to("#{issuer}/token").first)["client_id"]).to eq(document_url)
        expect(requests_to("#{issuer}/register")).to be_empty
      end

      it "registers instead when the provider refuses it, and remembers that for the worker only" do
        bundle.run_inits
        first, = login
        finish(first, "code" => "", "error" => "invalid_client")
        again = wait_for("the registration's flow") { bundle.sign_ins[1] }
        expect(query(again)["client_id"]).to eq("CLIENT-1")
        bundle.fail_sign_in(:cancelled)
        wait_for("the login's thread to end") { !bundle.plugin.instance_variable_get(:@sign_ins)["linear"].alive? }

        _, params = login
        expect(params["client_id"]).to eq("CLIENT-1")
        expect(bundle.secrets.keys.grep(/cimd|refused/)).to eq([])
      end

      it "is used only where the provider says it takes one" do
        provider.delete(:client_id_metadata_document_supported)
        bundle.run_inits
        _, params = login

        expect(params["client_id"]).to eq("CLIENT-1")
      end
    end

    context "with a client_metadata_url: that isn't an https address with a path" do
      let(:settings) { { "servers" => { "linear" => config }, "client_metadata_url" => "http://chi.example.org" } }

      it "refuses the login with one line" do
        bundle.run_inits

        expect(bundle.command("/mcp login linear"))
          .to eq("bundles: mcp: client_metadata_url: must be an https address with a path (chi's client document)")
      end
    end
  end

  describe "the kept token" do
    it "is sent only to the url it was kept for" do
      bundle.set(secrets: { secrets_name => JSON.generate(access_token: "ACCESS-TOKEN-1", resource: "https://other.example.com/mcp") })
      bundle.run_inits

      expect(requests_to(url).map { |request| request.headers["Authorization"] }.uniq).to eq([nil])
      expect(listing).to start_with("**linear**: needs sign-in")
    end

    it "fails a renew with a line naming the store when the store is busy, the token untouched" do
      oauth = bundle.namespace::Plugin::OAuth
      kept = JSON.generate(access_token: "ACCESS-TOKEN-1", refresh_token: "REFRESH-TOKEN-1", resource: url,
                           token_endpoint: "#{issuer}/token")
      secrets = instance_double(Samagotchi::Plugin::Secrets, get: kept)
      allow(secrets).to receive(:update)
        .and_raise(Samagotchi::Plugin::Secrets::Busy, "secret #{secrets_name} is held by another process (waited 18 s)")
      token = oauth::Token.new(secrets: secrets, resource: url, http: bundle.plugin.instance_variable_get(:@ctx).http)

      expect(token.call).to eq("ACCESS-TOKEN-1")
      expect { token.refresh_token!("ACCESS-TOKEN-1") }
        .to raise_error(bundle.namespace::Plugin::Client::Unavailable,
                        "the sign-in can't be renewed: secret #{secrets_name} is held by another process (waited 18 s)")
      expect(token.call).to eq("ACCESS-TOKEN-1")
      expect(requests_to("#{issuer}/token")).to be_empty
    end

    it "is used by a later session at once" do
      bundle.set(secrets: { secrets_name => JSON.generate(access_token: "ACCESS-TOKEN-1", resource: url) })

      expect(bundle.run_inits).to eq(["linear ready, 2 tools"])
    end
  end

  it "/mcp logout forgets the token, asks the provider to revoke it and needs sign-in again; the registration stays" do
    signed_in!
    expect(bundle.command("/mcp logout linear")).to eq("Signed out of linear.")

    expect(bundle.secrets).not_to have_key(secrets_name)
    expect(bundle.secrets.keys).to include(start_with("client-"))
    expect(form(requests_to("#{issuer}/revoke").first))
      .to eq("token" => "REFRESH-TOKEN-1", "token_type_hint" => "refresh_token", "client_id" => "CLIENT-1")
    expect(listing).to start_with("**linear**: needs sign-in (/mcp login linear)")
  end

  it "never puts a token, a code, a verifier, a client secret or the authorize address in a log line, card or notice" do
    flow = signed_in!
    exchange = form(requests_to("#{issuer}/token").first)
    valid.replace(["ACCESS-TOKEN-2"]) # a 401: one renew, the request again
    server = bundle.plugin.instance_variable_get(:@servers).first
    expect(server.client.request("tools/list", nil, timeout: 5)["tools"].size).to eq(2)
    expect(form(requests_to("#{issuer}/token").last)).to include("grant_type" => "refresh_token", "resource" => url)
    bundle.command("/mcp logout linear")
    secrets = ["ACCESS-TOKEN-1", "REFRESH-TOKEN-1", "ACCESS-TOKEN-2", "REFRESH-TOKEN-2", "AUTH-CODE-1", exchange["code_verifier"],
               query(flow)["state"], query(flow)["code_challenge"]]

    shown = bundle.cards.map { |c| [c[:title], c[:body]].join(" ") } + bundle.notices.map(&:text) + logged
    secrets.each { |secret| expect(shown.grep(/#{Regexp.escape(secret)}/)).to eq([]), "#{secret} shown" }
    expect(shown.join).not_to include(flow.address)
    expect(bundle.plugin.inspect + bundle.plugin.instance_variable_get(:@servers).first.token.inspect)
      .not_to match(/ACCESS-TOKEN|REFRESH-TOKEN/)
  end
end
