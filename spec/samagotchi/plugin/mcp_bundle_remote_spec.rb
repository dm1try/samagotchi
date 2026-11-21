# frozen_string_literal: true

require "spec_helper"
require_relative "../../support/mcp_bundle"
require_relative "../../support/fake_provider_server"
require_relative "../../support/fake_mcp_http_server"

# The mcp bundle's remote servers (url: instead of command:), end to end
# through an Engine against FakeMcpHttpServer: real sockets, never the
# network.
RSpec.describe "The mcp bundle with a remote server" do
  include_context "the mcp bundle in an Engine"

  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:remote) { FakeMcpHttpServer.start }
  let(:fake) { { "url" => remote.url } }
  let(:notices) { [] }

  after { remote.stop }

  def cache_file = File.join(ENV["XDG_STATE_HOME"], "samagotchi", "plugins", "mcp", "tools-fake.json")

  def next_engine
    @engine&.shutdown
    @engine = nil
    engine.tap { |built| built.subscribe(observer: ->(e) { notices << e[:text] if e[:type] == :hook_notice }) }
  end

  def mcp_card
    cards = []
    handle = engine.subscribe(observer: ->(e) { cards << e if e[:type] == :card })
    commands = Samagotchi::SessionCommands.new(engine: engine, turn_flow: Samagotchi::TurnFlow.new(engine: engine),
                                               default_model: "Gemma-4B-it", registry: engine.command_registry)
    engine.running_anytime { commands.run("/mcp") }
    engine.unsubscribe(handle: handle)
    cards.last[:body]
  end

  def with_env(values)
    saved = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  it "lists its tools in a first-run init task, then a later session searches the cache and connects on the first call" do
    engine
    expect(remote.rpc_methods).to eq(%w[server/discover tools/list])
    expect(JSON.parse(File.read(cache_file))).to include("info" => "A remote fake.")
    expect(mcp_card).to start_with("**fake**: connected (#{remote.url.delete_suffix("/mcp")}), 2 tools, ~")

    next_engine
    expect(remote.rpc_methods.size).to eq(2) # the cache: nothing sent before the first call
    expect(mcp_card).to start_with("**fake**: cached (not started), 2 tools, ~")
    expect(mcp("echo", { "text" => "far" })).to eq("echo: far")
    expect(remote.rpc_methods.drop(2)).to eq(%w[server/discover tools/list tools/call])
    expect(mcp_card).to start_with("**fake**: connected (http://127.0.0.1:")
    call = remote.requests.last
    expect([call.headers["mcp-method"], call.headers["mcp-name"]]).to eq(%w[tools/call echo])
  end

  it "speaks legacy to a server that doesn't discover (SSE answers, initialized sent)" do
    remote.legacy = true
    engine

    expect(remote.rpc_methods).to eq(%w[server/discover initialize notifications/initialized tools/list])
    expect(mcp("echo", { "text" => "old" })).to eq("echo: old")
  end

  it "leaves a cached server cached when it doesn't connect: one notice per message, and the next call works" do
    engine
    remote.down = true
    next_engine

    expect(mcp("echo", { "text" => "x" })).to eq("Error: MCP server fake didn't connect: HTTP 503")
    expect(mcp("echo", { "text" => "x" })).to eq("Error: MCP server fake didn't connect: HTTP 503")
    expect(notices).to eq(["MCP server fake didn't connect: HTTP 503; its next call tries again"])
    expect(mcp_card).to start_with("**fake**: cached (not started)")
    remote.down = false
    expect(mcp("echo", { "text" => "back" })).to eq("echo: back")
  end

  it "says a failed first run didn't connect, in the init card" do
    remote.down = true

    expect(load_events.select { |e| e[:type] == :card }.map { |c| [c[:title], c[:body]] })
      .to eq([["fake didn't connect", "MCP server fake didn't connect: HTTP 503; its calls fail until chi restarts"]])
    # The tool index's own wording for a failed group with no tools (core, not the bundle's).
    expect(mcp("echo", { "text" => "x" })).to eq("Error: MCP server fake didn't start: HTTP 503")
  end

  describe "a Stop during a first-run connect: the init task's own, never the turn's" do
    let(:settings) { { "servers" => servers, "startup_timeout" => 5, "timeout" => 5 } }

    it "leaves the connect alone when the turn is stopped: the server connects" do
      stopped = Samagotchi::CancellationController.new.tap(&:cancel!)
      allow_any_instance_of(Samagotchi::Engine).to receive(:active_cancel_controller).and_return(stopped)

      expect(load_events.select { |e| e[:type] == :card }).to be_empty
      expect(mcp_card).to start_with("**fake**: connected (http://127.0.0.1:")
    end

    it "ends the connect at once when chi shuts down" do
      remote.hold = true
      @engine = Samagotchi::Engine.new(client: client).tap(&:start_init_tasks!)
      wait_for("the discover to be held") { remote.holding.positive? }

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @engine.shutdown
      # Not the 5 s startup_timeout, nor Engine::SHUTDOWN_JOIN_SECONDS (3 s): the task saw its cancel.
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < time_bound(1.5, below: 3)
      expect(remote.rpc_methods).to eq(["server/discover"])
    end
  end

  context "with bearer_token_env" do
    let(:fake) { { "url" => remote.url, "bearer_token_env" => "FAKE_MCP_TOKEN" } }

    before { remote.token = "fake-token-1" }

    it "sends the variable's value, looked up at each request: a fixed token works in the same session" do
      with_env("FAKE_MCP_TOKEN" => "fake-token-1") { engine }
      digest = JSON.parse(File.read(cache_file))["digest"]

      with_env("FAKE_MCP_TOKEN" => nil) do
        next_engine
        expect(mcp("echo", { "text" => "x" })).to eq("Error: MCP server fake didn't connect: FAKE_MCP_TOKEN is not set")
      end
      expect(remote.rpc_methods.size).to eq(2) # nothing sent without the token
      with_env("FAKE_MCP_TOKEN" => "fake-token-2") do
        expect(mcp("echo", { "text" => "x" })).to eq("Error: MCP server fake didn't connect: refused the token (401)")
        remote.token = "fake-token-2"
        expect(mcp("echo", { "text" => "now" })).to eq("echo: now")
        # A rotated token isn't a changed config.
        next_engine
        expect(JSON.parse(File.read(cache_file))["digest"]).to eq(digest)
        expect(mcp_card).to start_with("**fake**: cached (not started)")
      end
    end

    it "takes the token from the server's env: too" do
      fake["env"] = { "FAKE_MCP_TOKEN" => "fake-token-1" }

      with_env("FAKE_MCP_TOKEN" => nil) { engine }
      expect(remote.requests.last.headers["authorization"]).to eq("Bearer fake-token-1")
    end
  end

  it "says a 401 needs a token when none is configured" do
    remote.token = "fake-token-1"

    expect(load_events.find { |e| e[:type] == :card }[:body])
      .to eq("MCP server fake didn't connect: needs a token (401): set bearer_token_env (sign-in comes in a later chi); " \
             "its calls fail until chi restarts")
  end

  it "never attaches a local image a remote server names" do
    engine
    shot = File.join(Dir.tmpdir, "remote-shot.png").tap { |path| FileUtils.cp(tiny_png, path) }

    expect(mcp("path", { "path" => shot })).to eq(shot)
  ensure
    FileUtils.rm_f(shot) if shot
  end

  describe "config errors" do
    {
      { "url" => "ftp://example.com/mcp" } => "url: must be an http(s) URL (bundles: mcp: servers: fake)",
      { "url" => "http://x/mcp", "command" => ["x"] } =>
        "set command: (a local server) or url: (a remote one), not both (bundles: mcp: servers: fake)",
      { "url" => "http://x/mcp", "headers" => { "Accept" => "x" } } => "headers: Accept is chi's to set (bundles: mcp: servers: fake)",
      { "url" => "http://x/mcp", "headers" => { "mcp-session-id" => "x" } } =>
        "headers: mcp-session-id is chi's to set (bundles: mcp: servers: fake)",
      { "url" => "http://x/mcp", "bearer_token_env" => "T", "headers" => { "Authorization" => "x" } } =>
        "headers: Authorization is chi's to set (bundles: mcp: servers: fake)",
      { "url" => "http://x/mcp", "headers" => { "X-A" => "a\nb" } } =>
        "headers: \"X-A\" must be a name and a one-line text value (bundles: mcp: servers: fake)",
      { "url" => "http://x/mcp", "headers" => { "X-A" => 1 } } =>
        "headers: \"X-A\" must be a name and a one-line text value (bundles: mcp: servers: fake)",
      {} => "no command (bundles: mcp: servers: fake: command: [...] or url: ...)"
    }.each do |config, text|
      it "refuses #{config.inspect}" do
        servers["fake"] = config

        expect(load_events.find { |e| e[:type] == :card }[:body])
          .to eq("MCP server fake didn't #{config.key?("url") ? "connect" : "start"}: #{text}; its calls fail until chi restarts")
      end
    end
  end

  it "keeps the URL's path and query and the header values out of Server#inspect" do
    fake.merge!("url" => "#{remote.url}?key=QUERY-SECRET", "headers" => { "X-Key" => "HEADER-SECRET" })
    engine
    plugin = engine.instance_variable_get(:@services).to_a.first.instance_variable_get(:@start).binding.receiver

    text = plugin.instance_variable_get(:@servers).first.inspect
    expect(text).to start_with("#<Server fake state=running url=http://127.0.0.1:")
    expect(text).not_to match(/QUERY-SECRET|HEADER-SECRET|mcp/)
  end
end
