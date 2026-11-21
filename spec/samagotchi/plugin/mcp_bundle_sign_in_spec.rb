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
end
