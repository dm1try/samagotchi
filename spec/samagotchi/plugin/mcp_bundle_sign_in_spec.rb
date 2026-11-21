# frozen_string_literal: true

require "spec_helper"
require "net/http"
require_relative "../../support/mcp_bundle"
require_relative "../../support/fake_provider_server"
require_relative "../../support/fake_mcp_http_server"
require_relative "../../support/fake_oauth_provider"

# The mcp bundle's sign-in end to end, through an Engine: FakeMcpHttpServer
# answers 401 without a token FakeOAuthProvider issued, ctx.sign_in's
# listener is real (the browser leg is an HTTP GET to the flow's loopback
# address, or /callback), the secrets are the real file store. Real
# sockets, never the network.
RSpec.describe "The mcp bundle's sign-in, end to end" do
  include_context "the mcp bundle in an Engine"

  around { |example| FakeProviderServer.without_webmock { example.run } }
  around { |example| with_env("SAMAGOTCHI_KEYCHAIN" => "off") { example.run } }

  let(:provider) { FakeOAuthProvider.start }
  let(:remote) do
    FakeMcpHttpServer.start.tap do |server|
      server.token = ->(token) { provider.valid?(token) }
      server.challenge = provider.challenge
    end
  end
  let(:fake) { { "url" => remote.url } }
  let(:cards) { [] }

  before do
    provider.resource = remote.url
    allow_any_instance_of(Samagotchi::Plugin::Context).to receive(:frontend).and_return(:worker)
  end

  after do
    remote.stop
    provider.stop
  end

  def commands(on = engine)
    Samagotchi::SessionCommands.new(engine: on, turn_flow: Samagotchi::TurnFlow.new(engine: on), default_model: "Gemma-4B-it",
                                    registry: on.command_registry)
  end

  # A command as the web runs an anytime one; the cards it and its threads show are in #cards.
  def command(line, on: engine)
    @watching ||= {}
    @watching[on] ||= on.subscribe(observer: ->(e) { cards << e if e[:type] == :card })
    on.running_anytime { commands(on).run(line) }.output
  end

  def card(title) = cards.reverse.find { |c| c[:title] == title }

  # The sign-in card's address, opened as a browser would: the provider
  # approves and redirects to the flow's loopback listener.
  def browse(address)
    approved = Net::HTTP.get_response(URI(address))
    expect(approved.code).to eq("302")
    Net::HTTP.get_response(URI(approved["location"]))
  end

  def sign_in_card = wait_for("the sign-in card") { card("Sign in to fake") }

  def signed_in!(on: engine)
    expect(command("/mcp login fake", on: on)).to eq("Opening sign-in for fake…")
    landed = browse(sign_in_card[:actions].first[:url])
    expect(landed.body).to include("Signed in")
    wait_for("the signed-in card") { card("Signed in to fake") }
  end

  it "needs sign-in on a first run's 401, signs in through the browser, and the tools work" do
    engine
    expect(load_events.select { |e| e[:type] == :card }.map { |c| c[:title] }).to eq(["fake needs sign-in"])
    expect(mcp("echo", { "text" => "x" })).to eq("Error: fake needs sign-in: the user runs /mcp login fake")
    expect(find("echo")).to include("fake (fake needs sign-in: the user runs /mcp login fake)")

    signed_in!
    expect(card("Signed in to fake")[:body]).to eq("2 tools, ready to use.")
    expect(mcp("echo", { "text" => "far" })).to eq("echo: far")
    expect(remote.requests.last.headers["authorization"]).to eq("Bearer ACCESS-1")
    expect(provider.grants).to eq(["authorization_code"])
  end

  it "signs in through a pasted /callback address" do
    engine
    command("/mcp login fake")
    approved = Net::HTTP.get_response(URI(sign_in_card[:actions].first[:url]))

    expect(commands.run("/callback #{approved["location"]}").status).to eq(:ok)
    wait_for("the signed-in card") { card("Signed in to fake") }
    expect(mcp("echo", { "text" => "pasted" })).to eq("echo: pasted")
  end

  it "keeps the sign-in for the url: a later session's call connects with it, no sign-in of its own" do
    engine
    signed_in!
    @engine.shutdown
    @engine = nil

    expect(mcp("echo", { "text" => "later" })).to eq("echo: later")
    expect(remote.requests.last.headers["authorization"]).to eq("Bearer ACCESS-1")
    expect(provider.grants).to eq(["authorization_code"])
  end

  describe "renewing" do
    def secret_file = File.join(ENV["XDG_STATE_HOME"], "samagotchi", "plugins", "mcp", "secrets",
                                "oauth-#{Digest::SHA256.hexdigest(remote.url)[0, 16]}")

    def kept = JSON.parse(File.read(secret_file))

    before do
      engine
      signed_in!
    end

    it "renews a kept token that runs out within a minute before a request, once, and keeps the new one" do
      File.write(secret_file, JSON.generate(kept.merge("expires_at" => Time.now.to_i + 30, "issued_at" => Time.now.to_i - 3570)))
      @engine.shutdown
      @engine = nil # a later session: it reads the kept token

      expect(mcp("echo", { "text" => "fresh" })).to eq("echo: fresh")
      expect(mcp("echo", { "text" => "fresh" })).to eq("echo: fresh")
      expect(provider.grants).to eq(%w[authorization_code refresh_token])
      expect(remote.requests.last.headers["authorization"]).to eq("Bearer ACCESS-2")
      expect(kept).to include("access_token" => "ACCESS-2", "refresh_token" => "REFRESH-2")
      expect(kept["expires_at"]).to be_within(5).of(Time.now.to_i + 3600)
    end

    context "with a token for a few seconds" do
      let(:provider) { FakeOAuthProvider.start(expires_in: 30) }

      it "renews it ahead by half its life, not at each request" do
        3.times { expect(mcp("echo", { "text" => "x" })).to eq("echo: x") }

        expect(provider.grants).to eq(["authorization_code"])
      end
    end

    it "renews once on a 401 and sends the call again" do
      provider.expire!("ACCESS-1")

      expect(mcp("echo", { "text" => "again" })).to eq("echo: again")
      expect(provider.grants).to eq(%w[authorization_code refresh_token])
      expect(remote.rpc_methods.last(2)).to eq(%w[tools/call tools/call])
      expect(kept).to include("access_token" => "ACCESS-2", "refresh_token" => "REFRESH-2")
    end

    it "takes another worker's newer token with no request of its own: one refresh for two workers" do
      other = Samagotchi::Engine.new(client: client)
      other_echo = lambda do
        turn = Samagotchi::TurnContext.none(surface: Samagotchi::Tools::ToolSurface.for(other.instance_variable_get(:@tools)))
        other.instance_variable_get(:@tools)["call_tool"].handler.call(
          { name: "call_tool", args: { "tool" => "fake/echo", "args" => { "text" => "b" } } },
          Samagotchi::KernelLoop::ToolContext.new(other.instance_variable_get(:@kernel), turn)
        )
      end
      expect(other_echo.call).to eq("echo: b") # it holds ACCESS-1 too
      provider.expire!("ACCESS-1")

      expect(mcp("echo", { "text" => "a" })).to eq("echo: a")
      expect(other_echo.call).to eq("echo: b")
      expect(provider.grants.count("refresh_token")).to eq(1)
    ensure
      other&.shutdown
    end

    it "forgets the sign-in when the provider refuses the refresh token: needs sign-in again, its card again" do
      provider.refresh_answer = { status: 400, json: { error: "invalid_grant" } }
      provider.expire!("ACCESS-1")
      cards.clear

      expect(mcp("echo", { "text" => "x" })).to eq("Error: fake needs sign-in: the user runs /mcp login fake")
      expect(File.exist?(secret_file)).to be(false)
      expect(cards.map { |c| c[:title] }).to eq(["fake needs sign-in"])
      expect(mcp("echo", { "text" => "x" })).to eq("Error: fake needs sign-in: the user runs /mcp login fake")
      expect(provider.grants.count("refresh_token")).to eq(1)
    end

    it "keeps the token when renewing fails otherwise: the call isn't reachable, the next one tries again" do
      provider.refresh_answer = { status: 503, json: { error: "temporarily_unavailable" } }
      provider.expire!("ACCESS-1")

      expect(mcp("echo", { "text" => "x" }))
        .to eq("Error: MCP server fake is not reachable (its sign-in couldn't be renewed (temporarily_unavailable))")
      expect(kept["access_token"]).to eq("ACCESS-1")
      provider.refresh_answer = nil
      expect(mcp("echo", { "text" => "back" })).to eq("echo: back")
    end
  end

  it "renews once when two threads of a worker meet the same 401: the token object is safe to share" do
    engine
    signed_in!
    provider.expire!("ACCESS-1")
    plugin = engine.instance_variable_get(:@services).to_a.first.instance_variable_get(:@start).binding.receiver
    token = plugin.instance_variable_get(:@servers).first.token
    gate = Queue.new
    threads = Array.new(2) { Thread.new { gate.pop && token.refresh_token!("ACCESS-1") } }
    2.times { gate << true }

    expect(threads.map { |thread| join!(thread, "a renew").value }).to eq([true, true])
    expect(provider.grants.count("refresh_token")).to eq(1)
    expect(token.call).to eq("ACCESS-2")
  end
end
