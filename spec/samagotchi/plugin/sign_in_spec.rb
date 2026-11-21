# frozen_string_literal: true

require "spec_helper"
require "socket"
require "samagotchi/engine"
require "samagotchi/kernel_loop"
require "samagotchi/session_commands"
require "samagotchi/plugin/context"
require "samagotchi/plugin/sign_in"
require "support/thinking_off"
require "support/test_kernel"

# ctx.sign_in's round trip (Plugin::SignIn, Engine::SignInPart): a loopback
# listener on 127.0.0.1, the card with its button, /callback for a browser
# elsewhere, and every way a flow ends. Real sockets: no HTTP library, so
# WebMock never sees them.
RSpec.describe Samagotchi::Plugin::SignIn do
  # One HTTP request on a fresh connection; the answer's status line and body.
  def request(port, raw)
    socket = TCPSocket.new("127.0.0.1", port)
    socket.write(raw)
    answer = socket.read
    socket.close
    status, = answer.lines
    [status.to_s.strip, answer.split("\r\n\r\n", 2).last.to_s]
  end

  def get(port, target) = request(port, "GET #{target} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n")

  def refused?(port)
    TCPSocket.new("127.0.0.1", port).close
    false
  rescue Errno::ECONNREFUSED
    true
  end

  describe "a flow and its listener" do
    let(:settled) { [] }
    let(:now) { [100.0] }
    let(:listener) { described_class::Listener.new(read_timeout: 0.2, tick: 0.02) }
    let(:flow) do
      described_class.new(bundle: "b", title: "Sign in to Fake", button: "Open", timeout: 60, listener: listener,
                          clock: -> { now.first }, on_settle: ->(f, outcome) { settled << [f, outcome] })
    end

    before do
      flow.started("https://provider.example/authorize?client_id=c&state=S1&login_hint=me", "card1")
      flow.listen
    end

    after { listener.close }

    it "binds 127.0.0.1 only, and redirects to its own port and path" do
      expect(listener.instance_variable_get(:@server).local_address.ip_address).to eq("127.0.0.1")
      expect(flow.redirect_uri).to eq("http://127.0.0.1:#{listener.port}/callback")
    end

    it "takes the browser's callback: a static page, the query from wait, :done, and the port closed after" do
      status, body = get(listener.port, "/callback?code=C1&state=S1&iss=https%3A%2F%2Fprovider.example")
      expect(status).to eq("HTTP/1.1 200 OK")
      expect(body).to include("Signed in. You can close this tab.")
      expect(body).not_to include("C1")
      expect(body).not_to include("<script")
      expect(flow.wait).to eq("code" => "C1", "state" => "S1", "iss" => "https://provider.example")
      expect(flow.outcome).to eq(:done)
      expect(settled.map(&:last)).to eq([:done])
      expect(refused?(listener.port)).to be(true)
    end

    it "answers anything else 404 and goes on waiting: another path, a POST, a wrong state" do
      expect(get(listener.port, "/other?code=C1&state=S1").first).to eq("HTTP/1.1 404 Not Found")
      expect(request(listener.port, "POST /callback?code=C1&state=S1 HTTP/1.1\r\n\r\n").first).to eq("HTTP/1.1 404 Not Found")
      expect(get(listener.port, "/callback?code=C1&state=WRONG").first).to eq("HTTP/1.1 404 Not Found")
      expect(get(listener.port, "/callback?code=C1").first).to eq("HTTP/1.1 404 Not Found")
      expect(flow.outcome).to be_nil
      expect(get(listener.port, "/callback?code=C2&state=S1").first).to eq("HTTP/1.1 200 OK")
      expect(flow.wait).to include("code" => "C2")
    end

    it "drops an oversized request and a slow one, and goes on waiting" do
      big = "GET /callback?code=C1&state=S1 HTTP/1.1\r\nX-Pad: #{"x" * 9000}\r\n\r\n"
      expect(request(listener.port, big).first).to eq("")
      slow = TCPSocket.new("127.0.0.1", listener.port)
      slow.write("GET /callback?code=C1")
      expect(slow.read).to eq("") # dropped at the read deadline, no answer
      slow.close
      expect(flow.outcome).to be_nil
      expect(get(listener.port, "/callback?code=C3&state=S1").first).to eq("HTTP/1.1 200 OK")
    end

    it "times out at its deadline: :timed_out, wait gives nil, the port closes" do
      now[0] = 160.0
      expect(flow.wait).to be_nil
      expect(flow.outcome).to eq(:timed_out)
      expect(settled.map(&:last)).to eq([:timed_out])
      expect(refused?(listener.port)).to be(true)
    end

    it "ends once: a cancel after a callback changes nothing" do
      expect(flow.offer("code=C1&state=S1")).to be(true)
      flow.cancel
      expect(flow.outcome).to eq(:done)
      expect(settled.size).to eq(1)
    end

    it "takes a pasted address for its redirect_uri only, and never shows the query in inspect" do
      expect(flow.redirect_of?("#{flow.redirect_uri}?code=x")).to be(true)
      expect(flow.redirect_of?("#{flow.redirect_uri}x?code=x")).to be(false)
      expect(flow.redirect_of?("http://127.0.0.1:1/callback?code=x")).to be(false)
      expect(flow.inspect).not_to include("login_hint")
    end
  end

  it "refuses a timeout outside 60..900, a bad path, a taken port" do
    expect { described_class.check_options!(timeout: 30, path: "/callback") }.to raise_error(ArgumentError, /60\.\.900/)
    expect { described_class.check_options!(timeout: 300, path: "callback") }.to raise_error(ArgumentError, /path/)
    taken = described_class::Listener.new
    expect { described_class::Listener.new(port: taken.port) }.to raise_error(ArgumentError, /port #{taken.port} is taken/)
  ensure
    taken&.close
  end

  describe "in a session (Engine#start_sign_in, ctx.sign_in, /callback)" do
    include_context "thinking off"

    around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

    let(:client) { test_client }
    let(:kernel) { test_kernel(client: client) }
    let(:engine) { Samagotchi::Engine.new(client: client, kernel: kernel) }
    let(:seen) { [] }
    let(:host) { engine.send(:plugin_host) }
    let(:ctx) { Samagotchi::Plugin::Context.new(bundle: "fake", label: "fake", settings: {}, host: host) }

    before do
      engine.subscribe(observer: ->(e) { seen << e })
      # A worker's (a test Engine is a one-shot's, which asks no one).
      allow(ctx).to receive(:frontend).and_return(:worker)
    end

    after { engine.shutdown(join_timeout: 0) }

    def cards = seen.select { |e| e[:type] == :card }

    def commands_for(engine)
      Samagotchi::SessionCommands.new(engine: engine, turn_flow: Samagotchi::TurnFlow.new(engine: engine), default_model: "m",
                                      registry: engine.command_registry)
    end

    def start(**options)
      ctx.sign_in(title: "Sign in to Fake", button: "Open sign-in page", **options) do |redirect_uri|
        "https://provider.example/authorize?redirect_uri=#{URI.encode_www_form_component(redirect_uri)}&state=S1"
      end
    end

    it "shows the card between turns, never a turn's: the button opens the address, the paste line under it" do
      flow = start
      expect(cards.size).to eq(1)
      card = cards.first
      expect(card).to include(id: flow.card_id, source: "fake", title: "Sign in to Fake", level: :info)
      expect(card).to include(in_turn: false)
      expect(card[:body]).to eq(described_class::PASTE_LINE)
      expect(card[:actions]).to eq([{ label: "Open sign-in page", url: flow.address }])
      expect(flow.address).to include(URI.encode_www_form_component(flow.redirect_uri))
      expect(engine.sign_in_waiting?).to be(true)
    end

    it "shows it as an anytime command's card while a turn runs (a timeout's too), never in that turn" do
      allow(engine).to receive(:turn_running?).and_return(true)
      flow = start
      flow.end_as(:timed_out)
      expect(cards.map { |c| c.values_at(:in_turn, :anytime) }).to eq([[false, true], [false, true]])
    end

    it "logs the address's host and path only" do
      logged = []
      allow(Samagotchi::Log).to receive(:info) { |_tag, event, **fields| logged << [event, fields] }
      start
      started = logged.find { |event, _| event == "sign_in_started" }.last
      expect(started[:to]).to eq("provider.example/authorize")
      expect(logged.inspect).not_to include("S1")
    end

    it "finishes from a pasted /callback: Got it, the flow :done, its card left for the bundle" do
      flow = start
      commands = commands_for(engine)
      result = commands.run("/callback #{flow.redirect_uri}?code=C1&state=S1")
      expect([result.status, result.output]).to eq([:ok, "Got it."])
      expect(flow.wait).to eq("code" => "C1", "state" => "S1")
      expect(cards.size).to eq(1)
      expect(refused?(URI(flow.redirect_uri).port)).to be(true)
      expect(engine.sign_in_waiting?).to be(false)
    end

    it "answers /callback with one refusal line: nothing waiting, another address, a wrong state, a parent agent" do
      commands = commands_for(engine)
      expect(commands.run("/callback http://127.0.0.1:1/callback?code=x").output).to eq("no sign-in is waiting")
      flow = start
      expect(commands.run("/callback http://127.0.0.1:1/callback?code=x").output).to start_with("that isn't this sign-in's address")
      expect(commands.run("/callback #{flow.redirect_uri}?code=x&state=WRONG").output).to eq("that isn't this sign-in's address")
      parent = commands.run("/callback #{flow.redirect_uri}?code=x&state=S1", as_parent: true)
      expect([parent.status, parent.output]).to eq([:error, "a parent agent doesn't finish this session's sign-in"])
      expect(commands.run("/callback").status).to eq(:error)
      expect(flow.outcome).to be_nil
    end

    it "replaces the card when it times out or is cancelled (same id, no button)" do
      flow = start
      flow.end_as(:timed_out)
      expect(cards.last).to include(id: flow.card_id, title: "Sign-in timed out", actions: [])
      expect(cards.last[:body]).to eq("Sign in to Fake: run its command again to try again.")
      again = start
      again.cancel
      expect(cards.last).to include(id: again.card_id, title: "Sign-in cancelled", actions: [])
    end

    it "is stopped by the worker's shutdown: the card says cancelled and the port closes" do
      flow = start
      port = URI(flow.redirect_uri).port
      engine.shutdown(join_timeout: 0)
      expect(flow.outcome).to eq(:stopped)
      expect(cards.last).to include(id: flow.card_id, title: "Sign-in cancelled", actions: [])
      expect(refused?(port)).to be(true)
    end

    it "opens nothing and shows nothing for a one-shot run, nor in a stream hook's handler" do
      allow(ctx).to receive(:frontend).and_return(:one_shot)
      flow = start
      expect([flow.outcome, flow.wait, flow.card_id, flow.redirect_uri]).to eq([:stopped, nil, nil, nil])
      allow(ctx).to receive(:frontend).and_return(:worker)
      Thread.current[Samagotchi::Plugin::Context::CURRENT_EVENTS] = { ctx => { type: :generation_progress } }
      expect(start.outcome).to eq(:stopped)
      expect(cards).to eq([])
    ensure
      Thread.current[Samagotchi::Plugin::Context::CURRENT_EVENTS] = nil
    end

    it "closes the port when the address can't be a card's (no flow is left)" do
      expect { ctx.sign_in(title: "T") { "javascript:alert(1)" } }.to raise_error(ArgumentError, /url must be http/)
      expect(engine.sign_in_waiting?).to be(false)
      expect { ctx.sign_in(title: "T") }.to raise_error(ArgumentError, /needs a block/)
    end
  end
end
