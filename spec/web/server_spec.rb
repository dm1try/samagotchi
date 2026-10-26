# frozen_string_literal: true

require "stringio"
require "fileutils"
require "tmpdir"
require "socket"
require "samagotchi/web/server"

RSpec.describe Samagotchi::Web::Server::Log do
  let(:out) { StringIO.new }
  let(:log) { described_class.new(out, WEBrick::Log::WARN) }

  # Raised, as WEBrick hands them over: its format joins the backtrace.
  def raised(klass, msg = "x")
    raise klass, msg
  rescue klass => e
    e
  end

  it "drops a peer closing the connection" do
    [Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED].each { |klass| log.error(raised(klass)) }

    expect(out.string).to eq("")
  end

  it "drops the fixup line after a body-less POST (no Content-Length), keeps other fixup errors" do
    log.error("HTTPRequest#fixup: WEBrick::HTTPStatus::LengthRequired occurred.")
    expect(out.string).to eq("")

    log.error("HTTPRequest#fixup: WEBrick::HTTPStatus::BadRequest occurred.")
    expect(out.string).to include("ERROR HTTPRequest#fixup: WEBrick::HTTPStatus::BadRequest occurred.")
  end

  it "keeps real errors and messages" do
    log.error(raised(RuntimeError, "boom"))
    log.error("bad request line")

    expect(out.string).to include("ERROR RuntimeError: boom").and include("ERROR bad request line")
  end

  # WEBrick logs the signal that stops its loop as FATAL with a backtrace
  # before it re-raises it: Ctrl-C (Interrupt) and a kill (SIGTERM).
  it "drops the signal that stops the server, keeps other fatals" do
    log.fatal(raised(Interrupt, ""))
    log.fatal(SignalException.new("TERM"))
    expect(out.string).to eq("")

    log.fatal(raised(RuntimeError, "boom"))
    expect(out.string).to include("FATAL RuntimeError: boom")
  end
end

RSpec.describe Samagotchi::Web::Server do
  # The hub logs nothing of its own: the web log's start and stop lines
  # are the server's. Server.start starts it before WEBrick and stops it
  # after.
  # subscribe answers as with snapshot: true (the push Notifier's; the
  # chi line's subscribe ignores it), scan as a pass that found nothing.
  let(:hub) do
    instance_double(Samagotchi::Web::SessionHub, start: nil, stop: nil, scan: nil,
                                                 subscribe: [instance_double(Samagotchi::Web::SessionHub::Subscription, unsubscribe: true), []])
  end

  # Where Web::Running records the port: this example's own folder.
  let(:start_state) { File.join(start_root, "samagotchi", "sessions") }
  let(:start_root) { Dir.mktmpdir("server-start") }

  after { FileUtils.rm_rf(start_root) }

  it "says so on stderr when it can't open the browser" do
    allow(described_class).to receive(:system).and_raise(Errno::ENOENT, "open")

    expect { described_class.open_url("http://127.0.0.1:4567/") }
      .to output(%r{Failed to open browser: .*open — please open http://127.0.0.1:4567/ manually}).to_stderr
  end

  describe "a newer chi installed" do
    def chi_event(installed)
      Samagotchi::Web::SessionHub::Event.new(type: "chi", seq: 1, data: { version: Samagotchi::VERSION, installed: installed })
    end

    it "is said in chi web's terminal when the hub finds one, subscribed before the hub's first scan" do
      allow(Samagotchi::Web::App).to receive(:new).and_return(double("app"))
      allow(Rackup::Handler::WEBrick).to receive(:run)
      sink = nil
      allow(hub).to receive(:subscribe) { |s| sink = s }

      described_class.start(port: 4998, hub: hub)
      expect(hub).to have_received(:subscribe).ordered
      expect(hub).to have_received(:start).ordered

      expect { sink.call(chi_event("99.0.0")) }
        .to output("chi 99.0.0 is installed; this chi web runs #{Samagotchi::VERSION}. Restart it: Ctrl-C here, " \
                   "then chi web (new sessions already run 99.0.0)\n").to_stdout
    end

    it "says nothing for the same or an older version, nothing found, or another event" do
      expect { described_class.on_hub_event(chi_event(Samagotchi::VERSION)) }.not_to output.to_stdout
      expect { described_class.on_hub_event(chi_event("0.0.1")) }.not_to output.to_stdout
      expect { described_class.on_hub_event(chi_event(nil)) }.not_to output.to_stdout
      expect { described_class.on_hub_event(Samagotchi::Web::SessionHub::Event.new(type: "session", seq: 1, data: {})) }
        .not_to output.to_stdout
    end
  end

  it "writes its start and stop to the log" do
    dir = Dir.mktmpdir
    Samagotchi::Log.configure(path: File.join(dir, "chi.log"))
    allow(Samagotchi::Web::App).to receive(:new).and_return(double("app"))
    allow(Rackup::Handler::WEBrick).to receive(:run)

    expect { described_class.start(port: 4998, hub: hub) }.not_to output.to_stdout
    expect(hub).to have_received(:start).ordered
    expect(hub).to have_received(:stop).ordered

    records = File.open(File.join(dir, "chi.log")) { |io| Samagotchi::LogLine.each_record(io).to_a }
    expect(records.map { |r| [r.tag, r.event, r.fields] }).to eq([
      ["web", "start", { "url" => "http://127.0.0.1:4998", "version" => Samagotchi::VERSION }], ["web", "stop", {}]
    ])
  ensure
    FileUtils.remove_entry(dir)
  end

  it "builds a hub over the app's state dir, hands it to the app, and points the app's shutdown check at WEBrick" do
    state_dir = Dir.mktmpdir
    webrick = double("webrick", status: :Running)
    app = nil
    allow(Rackup::Handler::WEBrick).to receive(:run) { |served, _opts, &block| app = served; block.call(webrick) }

    described_class.start(port: 4999, state_dir: state_dir)

    hub = app.instance_variable_get(:@hub)
    expect(hub).to be_a(Samagotchi::Web::SessionHub)
    expect(hub.instance_variable_get(:@state_dir)).to eq(state_dir)
    expect(hub).to be_stopped
    check = app.instance_variable_get(:@server_running)
    expect(check.call).to be true
    allow(webrick).to receive(:status).and_return(:Shutdown)
    expect(check.call).to be false
  ensure
    FileUtils.remove_entry(state_dir)
  end

  it "binds to 127.0.0.1 whatever host it is given, with a warning" do
    allow(Samagotchi::Web::App).to receive(:new).and_return(double("app"))
    allow(Rackup::Handler::WEBrick).to receive(:run)

    expect { described_class.start(port: 4999, host: "0.0.0.0", hub: hub) }.to output(/forcing 127.0.0.1/).to_stderr
    expect(Rackup::Handler::WEBrick).to have_received(:run).with(anything, hash_including(Host: "127.0.0.1", Port: 4999))
  end

  it "says where it runs only once the port is bound (WEBrick's start callback)" do
    allow(Samagotchi::Web::App).to receive(:new).and_return(double("app"))
    callback = nil
    allow(Rackup::Handler::WEBrick).to receive(:run) { |_app, opts| callback = opts[:StartCallback] }

    expect { described_class.start(port: 4999, url: "http://127.0.0.1:4999/?dir=%2Fr", hub: hub, state_dir: start_state) }
      .not_to output.to_stdout
    expect { callback.call }.to output(%r{\AChi Web on http://127.0.0.1:4999/\?dir=%2Fr .*\nPress Ctrl-C}).to_stdout
  end

  it "records its port once bound (Web::Running, chi share's link) and clears it when it stops" do
    allow(Samagotchi::Web::App).to receive(:new).and_return(double("app"))
    path = Samagotchi::Web::Running.path(state_dir: start_state)
    seen = nil
    allow(Rackup::Handler::WEBrick).to receive(:run) do |_app, opts|
      expect(Samagotchi::Web::Running.port(path: path)).to be_nil
      expect { opts[:StartCallback].call }.to output.to_stdout
      seen = Samagotchi::Web::Running.port(path: path)
    end

    described_class.start(port: 4999, hub: hub, state_dir: start_state)
    expect(seen).to eq(4999)
    expect(File.exist?(path)).to be(false)
  end

  it "runs on_bound (the tunnel's up) once bound, before it records or says anything; what it raises ends the run" do
    allow(Samagotchi::Web::App).to receive(:new).and_return(double("app", "server_running=": nil))
    allow(described_class).to receive(:record_running)
    socket = instance_double(TCPServer, closed?: false, close: nil)
    webrick = double("webrick", listeners: [socket], status: :Running)
    allow(Rackup::Handler::WEBrick).to receive(:run) do |_app, opts, &block|
      block.call(webrick)
      opts[:StartCallback].call
    end
    on_bound = -> { raise Samagotchi::Web::Tunnel::CliFailed.new("tailscale serve", "no") }

    expect do
      expect { described_class.start(port: 4999, hub: hub, state_dir: start_state, on_bound: on_bound) }
        .to raise_error(Samagotchi::Web::Tunnel::CliFailed)
    end.not_to output.to_stdout
    expect(described_class).not_to have_received(:record_running)
    expect(socket).to have_received(:close)
  end

  it "says the port is in use instead of a backtrace when the bind fails" do
    allow(Samagotchi::Web::App).to receive(:new).and_return(double("app"))
    allow(Rackup::Handler::WEBrick).to receive(:run).and_raise(Errno::EADDRINUSE)

    result = nil
    expect { result = described_class.start(port: 4999, hub: hub) }
      .to output("Error: port 4999 is in use (an older chi web? restart it, or use --port)\n").to_stderr
    expect(result).to be false
  end

  describe "LAN mode" do
    let(:lan) { Samagotchi::Web::Lan::Choice.new(ip: "192.168.1.55", interface: "en0", others: [], public: false) }

    it "binds loopback, adds the LAN address as a second listener, and gives the app the address and the token file" do
      Dir.mktmpdir do |dir|
        token_path = File.join(dir, "web-token")
        webrick = double("webrick", status: :Running)
        allow(webrick).to receive(:listen)
        app = nil
        allow(Samagotchi::Web::App).to receive(:new) { |**kw| app = kw; double("app", "server_running=": nil) }
        allow(Rackup::Handler::WEBrick).to receive(:run) { |_app, _opts, &block| block.call(webrick) }

        expect(described_class.start(port: 4999, host: "lan", hub: hub, lan: lan, token_path: token_path)).to be true

        expect(Rackup::Handler::WEBrick).to have_received(:run).with(anything, hash_including(Host: "127.0.0.1", Port: 4999))
        expect(webrick).to have_received(:listen).with("192.168.1.55", 4999)
        expect(app[:lan][:ip]).to eq("192.168.1.55")
        expect(app[:working_set]).to be(true)
        expect(app[:lan][:token].current).to eq(Samagotchi::Web::Token.read(token_path)).and match(/\A.{43}\z/)
      end
    end

    it "says so in a line and closes the loopback socket when the LAN address can't be bound" do
      Dir.mktmpdir do |dir|
        socket = double("socket", close: nil)
        webrick = double("webrick", status: :Running, listeners: [socket])
        allow(webrick).to receive(:listen).and_raise(Errno::EADDRNOTAVAIL)
        allow(Samagotchi::Web::App).to receive(:new).and_return(double("app", "server_running=": nil))
        allow(Rackup::Handler::WEBrick).to receive(:run) { |_app, _opts, &block| block.call(webrick) }

        result = nil
        expect { result = described_class.start(port: 4999, hub: hub, lan: lan, token_path: File.join(dir, "t")) }
          .to output(/Error: can't listen on 192.168.1.55:4999 .*Run chi web again/).to_stderr
        expect(result).to be false
        expect(socket).to have_received(:close)
        expect(hub).to have_received(:stop)
      end
    end

    it "probes and starts on 127.0.0.1 for lan" do
      allow(Samagotchi::Web::Lan).to receive(:choose).with("lan").and_return(lan)
      allow(described_class).to receive(:probe).and_return(:free)
      allow(described_class).to receive(:start).and_return(true)

      expect(described_class.launch(host: "lan", port: 4999, start_dir: "/", scope: "all")).to eq(0)
      expect(described_class).to have_received(:probe).with("127.0.0.1", 4999)
      expect(described_class).to have_received(:start).with(hash_including(host: "127.0.0.1", lan: lan, url: "http://127.0.0.1:4999/"))
    end

    it "refuses an address that isn't this machine's, and lan without one, before binding anything" do
      allow(described_class).to receive(:start)
      allow(Samagotchi::Web::Lan).to receive(:choose).and_raise(Samagotchi::Web::Lan::Error, "web.host is 10.1.1.1, which isn't an address of this machine")

      result = nil
      expect { result = described_class.launch(host: "10.1.1.1", port: 4999) }
        .to output("Error: web.host is 10.1.1.1, which isn't an address of this machine\n").to_stderr
      expect(result).to eq(1)
      expect(described_class).not_to have_received(:start)
    end

    it "does not take LAN access from a chi web already running without it" do
      allow(Samagotchi::Web::Lan).to receive(:choose).and_return(lan)
      allow(described_class).to receive(:probe).and_return({ "app" => "chi-web", "pid" => 42, "lan" => nil })
      allow(described_class).to receive(:start)

      result = nil
      expect { result = described_class.launch(host: "lan", port: 4999, start_dir: "/") }
        .to output("chi web already runs on port 4999 without LAN access; stop it (Ctrl-C in its terminal, or kill 42) and run this again\n").to_stderr
      expect(result).to eq(1)
      expect(described_class).not_to have_received(:start)
    end

    it "still forces 0.0.0.0 and names to 127.0.0.1, with no LAN listener" do
      allow(described_class).to receive(:probe).and_return(:free)
      allow(described_class).to receive(:start).and_return(true)

      %w[0.0.0.0 mac.local].each do |host|
        expect { described_class.launch(host: host, port: 4999, start_dir: "/") }.to output(/forcing 127.0.0.1/).to_stderr
      end
      expect(described_class).to have_received(:start).with(hash_including(host: "127.0.0.1", lan: nil)).twice
    end
  end

  describe "behind an auth proxy (web.public_url)" do
    let(:public_url) do
      Samagotchi::Web::PublicUrl.from_config(url: "https://4999.pod.test", identity_header: "X-Forwarded-Email",
                                             owner: "me@pod.test")
    end

    it "makes the token without LAN mode, gives the app both, and prints the proxied link (no local one)" do
      Dir.mktmpdir do |dir|
        token_path = File.join(dir, "web-token")
        app = nil
        allow(Samagotchi::Web::App).to receive(:new) { |**kw| app = kw; double("app", "server_running=": nil) }
        allow(Rackup::Handler::WEBrick).to receive(:run) { |_app, opts, &block| opts[:StartCallback].call; block.call(double(status: :Running)) }

        out = nil
        expect { out = described_class.start(port: 4999, hub: hub, public_url: public_url, token_path: token_path, state_dir: start_state) }
          .to output(Regexp.new('Proxied: https://4999\\.pod\\.test/#code=(chc_.{43})   .*\\n +\\(owner me@pod\\.test by X-Forwarded-Email, ' \
                                'and the token; on this machine the page opens through the proxy too\\)\\nPress')).to_stdout
        expect(out).to be true
        token = Samagotchi::Web::Token.read(token_path)
        expect(app[:lan]).to be_nil
        expect(app[:public_url]).to eq(public_url)
        expect(app[:public_token].current).to eq(token)
        # The printed link's code: the owner's, once.
        printed = nil
        allow(Rackup::Handler::WEBrick).to receive(:run) { |_app, opts, &block| opts[:StartCallback].call; block.call(double(status: :Running)) }
        expect { described_class.start(port: 4999, hub: hub, public_url: public_url, token_path: token_path, state_dir: start_state) }
          .to output(satisfy { |o| printed = o[/#code=(chc_\S+)/, 1] }).to_stdout
        codes = described_class.owner_codes(start_state)
        expect(codes.redeem(printed)).to eq([:owner, nil])
        expect(codes.redeem(printed)).to be_nil
      end
    end

    it "starts Web Push with the public_url: the app gets it, the hub is scanned before the Notifier seeds from it" do
      app = nil
      allow(Samagotchi::Web::App).to receive(:new) { |**kw| app = kw; double("app", "server_running=": nil) }
      allow(Rackup::Handler::WEBrick).to receive(:run)
      order = []
      allow(hub).to receive(:scan) { order << :scan }
      allow(hub).to receive(:subscribe) { |sink, **kw| order << [:subscribe, kw[:snapshot] ? sink.class : :chi]; [instance_double(Samagotchi::Web::SessionHub::Subscription, unsubscribe: true), []] }
      allow(hub).to receive(:start) { order << :start }

      described_class.start(port: 4999, hub: hub, public_url: public_url, token_path: File.join(start_root, "web-token"), state_dir: start_state)
      expect(order).to eq([%i[subscribe chi], :scan, [:subscribe, Samagotchi::Web::Push::Notifier], :start])
      expect(app[:push]).to have_attributes(origin: "https://4999.pod.test")
      expect(app[:push].store.dir).to eq(File.join(start_root, "samagotchi", "web-push"))
      expect(File.stat(app[:push].store.key_path).mode & 0o777).to eq(0o600)
    end

    it "starts no push without a public_url, or with web.push.enabled false" do
      apps = []
      allow(Samagotchi::Web::App).to receive(:new) { |**kw| apps << kw; double("app", "server_running=": nil) }
      allow(Rackup::Handler::WEBrick).to receive(:run)
      described_class.start(port: 4999, hub: hub, state_dir: start_state)
      with_env("SAMAGOTCHI_WEB_PUSH_ENABLED" => "false") do
        described_class.start(port: 4999, hub: hub, public_url: public_url, token_path: File.join(start_root, "web-token"), state_dir: start_state)
      end
      expect(apps.map { |kw| kw[:push] }).to eq([nil, nil])
      expect(hub).not_to have_received(:scan)
    end

    it "says token only or nobody-by-identity in the start line" do
      token_only = Samagotchi::Web::PublicUrl.from_config(url: "https://p.test")
      codes = double("codes", issue: "chc_C")
      expect(described_class.public_lines(token_only, token: "T", codes: codes))
        .to eq(["Proxied: https://p.test/#code=chc_C   ← opens chi web as you once, within 10 minutes (chi web again prints a new one)",
                "         (token only, no identity header; on this machine the page opens through the proxy too)"])
      expect(codes).to have_received(:issue).with(kind: :owner, ttl: 600)
      nobody = Samagotchi::Web::PublicUrl.from_config(url: "https://p.test", identity_header: "X-Forwarded-Email")
      expect(described_class.public_lines(nobody, token: "T", codes: codes)[1]).to include("nobody is the owner by identity")
    end

    it "refuses to start on a public_url that isn't an https origin, before probing" do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("web.public_url").and_return("http://pod.test")
      allow(described_class).to receive(:probe)
      allow(described_class).to receive(:start)

      result = nil
      expect { result = described_class.launch(port: 4999, start_dir: "/") }.to output(/Error: web.public_url must be an https origin/).to_stderr
      expect(result).to eq(1)
      expect(described_class).not_to have_received(:probe)
      expect(described_class).not_to have_received(:start)
    end

    # The link from this machine's config, never from what answered on the
    # port (another user's listener could name its own public_url).
    it "passes a public_url to start, and a second chi web prints this config's proxied link" do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("web.public_url").and_return("https://4999.pod.test")
      allow(described_class).to receive(:probe).and_return(:free)
      allow(described_class).to receive(:start).and_return(true)
      expect(described_class.launch(port: 4999, start_dir: "/")).to eq(0)
      expect(described_class).to have_received(:start).with(hash_including(public_url: Samagotchi::Web::PublicUrl.from_config(url: "https://4999.pod.test")))

      allow(described_class).to receive(:probe).and_return({ "app" => "chi-web", "pid" => 42, "public_url" => "https://evil.example" })
      allow(Samagotchi::Web::Token).to receive(:read).and_return("T")
      allow(described_class).to receive(:owner_codes).and_return(double("codes", issue: "chc_C"))
      expect { described_class.launch(port: 4999, start_dir: "/", scope: "all") }
        .to output(a_string_including("Proxied: https://4999.pod.test/#code=chc_C ").and(satisfy { |o| !o.include?("evil") && !o.include?("token=") })).to_stdout
    end
  end

  describe "the LAN lines" do
    let(:token) { "t" * 43 }
    let(:others) { [Samagotchi::Web::Lan::Address.new(ip: "10.0.0.4", interface: "en5")] }

    it "show the link with the token, the warnings, and the QR code at a terminal" do
      lines = described_class.lan_lines(ip: "192.168.1.55", port: 4567, token: token, others: others, qr: true)

      expect(lines[0]).to eq("LAN: http://192.168.1.55:4567/?token=#{token}   ← anyone with this link can run commands as you")
      expect(lines[1]).to eq("Plain http: the link and your traffic can be read by anyone on this Wi-Fi.")
      expect(lines[2]).to eq("also: 10.0.0.4 (en5); set web.host to pick one")
      expect(lines[3..]).to eq(Samagotchi::Web::QR.lines("http://192.168.1.55:4567/?token=#{token}"))
    end

    it "leave the QR code out of a pipe or a log, and warn of a non-private address" do
      lines = described_class.lan_lines(ip: "100.101.102.103", port: 4567, token: token, public: true, qr: false)

      expect(lines.size).to eq(3)
      expect(lines.last).to eq("100.101.102.103 isn't a private LAN address: anyone who can reach it can try to get in")
    end

    it "are printed once the port is bound, after the loopback line" do
      Dir.mktmpdir do |dir|
        token_path = File.join(dir, "web-token")
        lan = Samagotchi::Web::Lan::Choice.new(ip: "192.168.1.55", interface: "en0", others: [], public: false)
        allow(Samagotchi::Web::App).to receive(:new).and_return(double("app", "server_running=": nil))
        callback = nil
        allow(Rackup::Handler::WEBrick).to receive(:run) { |_app, opts| callback = opts[:StartCallback] }
        described_class.start(port: 4999, hub: hub, lan: lan, token_path: token_path)
        token = Samagotchi::Web::Token.read(token_path)

        expect { callback.call }.to output(%r{\AChi Web on http://127.0.0.1:4999/ .*\nLAN: http://192.168.1.55:4999/\?token=#{token}   ← .*\nPlain http: .*\nPress Ctrl-C}).to_stdout
      end
    end

    it "are printed again by a second chi web, with the token from the file" do
      Dir.mktmpdir do |dir|
        token = Samagotchi::Web::Token.load_or_create(File.join(dir, "web-token"))
        allow(Samagotchi::Web::Token).to receive(:path).and_return(File.join(dir, "web-token"))
        allow(described_class).to receive(:probe).and_return({ "app" => "chi-web", "pid" => 42, "lan" => "192.168.1.55" })

        expect { described_class.launch(port: 4567, start_dir: "/", scope: "all") }
          .to output("chi web already runs on port 4567 (pid 42): http://127.0.0.1:4567/\n" \
                     "LAN: http://192.168.1.55:4567/?token=#{token}   ← anyone with this link can run commands as you\n" \
                     "Plain http: the link and your traffic can be read by anyone on this Wi-Fi.\n").to_stdout
      end
    end
  end

  describe ".launch with new_token" do
    it "starts nothing when LAN access is off, and says the new token waits for it" do
      Dir.mktmpdir do |state|
        allow(Samagotchi::Web::Token).to receive(:path).and_return(File.join(state, "web-token"))
        allow(described_class).to receive(:probe).and_return(:free)
        allow(described_class).to receive(:start)

        expect { expect(described_class.launch(host: "127.0.0.1", port: 4999, start_dir: state, new_token: true)).to eq(0) }
          .to output(/LAN access is off \(web.host is 127.0.0.1\): chi web --web-host lan uses the new token/).to_stdout
        expect(described_class).not_to have_received(:start)
      end
    end

    it "replaces the token file before anything else, and says the old links stop working" do
      Dir.mktmpdir do |state|
        path = File.join(state, "samagotchi", "web-token")
        old = Samagotchi::Web::Token.load_or_create(path)
        allow(Samagotchi::Web::Token).to receive(:path).and_return(path)
        allow(described_class).to receive(:probe).and_return(:free)
        allow(described_class).to receive(:start).and_return(true)

        expect { described_class.launch(port: 4999, start_dir: state, new_token: true) }
          .to output(/New LAN access token: links and QR codes made with the old one stop working/).to_stdout
        expect(Samagotchi::Web::Token.read(path)).not_to eq(old)
      end
    end
  end

  describe ".scope_url" do
    it "is the project view in a repo, the plain page outside one or for scope all" do
      Dir.mktmpdir do |tmp|
        repo = File.join(tmp, "my repo")
        FileUtils.mkdir_p(File.join(repo, ".git"))

        expect(described_class.scope_url("127.0.0.1", 4567, dir: repo))
          .to eq("http://127.0.0.1:4567/?dir=#{repo.tr(" ", "+")}")
        expect(described_class.scope_url("127.0.0.1", 4567, dir: repo, scope: "all")).to eq("http://127.0.0.1:4567/")
        expect(described_class.scope_url("::1", 4567, dir: tmp)).to eq("http://[::1]:4567/")
      end
    end
  end

  describe ".probe's verdict" do
    def verdict(status, body)
      allow(Samagotchi::Web::InfoProbe).to receive(:call) { Samagotchi::Web::InfoProbe.verdict(status, body) }
      described_class.probe("127.0.0.1", 1)
    end

    it "takes a chi web that knows ?dir, and nothing else" do
      info = { "app" => "chi-web", "pid" => 7, "features" => ["dir"] }
      expect(verdict(200, JSON.generate(info))).to eq(info)
      expect(verdict(200, JSON.generate(info.merge("features" => [])))).to eq(:other)
      expect(verdict(404, '{"error":"not_found","detail":"not found: /api/info"}')).to eq(:other)
      expect(verdict(200, "<html>")).to eq(:other)
    end
  end

  describe ".probe (real sockets)" do
    # WebMock (loaded by other specs) blocks real connections.
    around do |example|
      next example.run unless defined?(WebMock)

      WebMock.disable!
      begin
        example.run
      ensure
        WebMock.enable!
      end
    end

    def free_port
      server = TCPServer.new("127.0.0.1", 0)
      server.addr[1].tap { server.close }
    end

    it "is :free when nothing listens" do
      expect(described_class.probe("127.0.0.1", free_port)).to eq(:free)
    end

    it "is :other for something that isn't chi web" do
      server = TCPServer.new("127.0.0.1", 0)
      thread = Thread.new do
        client = server.accept
        client.readpartial(4096)
        client.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi")
        client.close
      end
      expect(described_class.probe("127.0.0.1", server.addr[1])).to eq(:other)
    ensure
      thread&.join(1)
      server&.close
    end

    it "is the /api/info hash for a running chi web" do
      port = free_port
      webrick = WEBrick::HTTPServer.new(Port: port, BindAddress: "127.0.0.1", AccessLog: [],
                                        Logger: WEBrick::Log.new(File::NULL))
      webrick.mount("/", Rackup::Handler::WEBrick, Samagotchi::Web::App.new(state_dir: Dir.mktmpdir))
      thread = Thread.new { webrick.start }

      expect(described_class.probe("127.0.0.1", port)).to include("app" => "chi-web", "pid" => Process.pid)
    ensure
      webrick&.shutdown
      thread&.join(2)
    end
  end

  describe ".launch" do
    before { allow(described_class).to receive(:scope_url).and_return("http://127.0.0.1:4567/?dir=%2Fr") }

    it "hands off to a running chi web: prints its page, opens it only with --open, starts nothing" do
      allow(described_class).to receive(:probe).and_return({ "pid" => 42 })
      allow(described_class).to receive(:open_url)
      allow(described_class).to receive(:start)

      expect { expect(described_class.launch(port: 4567)).to eq(0) }
        .to output("chi web already runs on port 4567 (pid 42): http://127.0.0.1:4567/?dir=%2Fr\n").to_stdout
      expect(described_class).not_to have_received(:open_url)
      expect { described_class.launch(port: 4567, open_browser: true) }.to output.to_stdout
      expect(described_class).to have_received(:open_url).with("http://127.0.0.1:4567/?dir=%2Fr")
      expect(described_class).not_to have_received(:start)
    end

    it "stops on a start folder that isn't one before it probes the port or rotates the token" do
      allow(described_class).to receive(:probe)
      allow(described_class).to receive(:rotate_token)
      result = nil

      expect { result = described_class.launch(port: 4567, start_dir: "/nope/gone", new_token: true) }
        .to output("Error: --start-dir /nope/gone: no such folder\n").to_stderr
      expect(result).to eq(1)
      expect(described_class).not_to have_received(:probe)
      expect(described_class).not_to have_received(:rotate_token)
    end

    it "says when the running chi web starts in another folder than the one given, and only then" do
      Dir.mktmpdir("start") do |wanted|
        allow(described_class).to receive(:probe).and_return({ "pid" => 42, "start_dir" => "/srv" })

        expect { described_class.launch(port: 4567, start_dir: wanted) }
          .to output("chi web already runs on port 4567 (pid 42): http://127.0.0.1:4567/?dir=%2Fr\n" \
                     "It starts in /srv; restart it to use #{Samagotchi::Paths.tilde(wanted)}\n").to_stdout
        expect { described_class.launch(port: 4567) }
          .to output("chi web already runs on port 4567 (pid 42): http://127.0.0.1:4567/?dir=%2Fr\n").to_stdout
        allow(described_class).to receive(:probe).and_return({ "pid" => 42, "start_dir" => wanted })
        expect { described_class.launch(port: 4567, start_dir: wanted) }
          .to output("chi web already runs on port 4567 (pid 42): http://127.0.0.1:4567/?dir=%2Fr\n").to_stdout
      end
    end

    it "starts a server on a free port with the scope URL" do
      allow(described_class).to receive(:probe).and_return(:free)
      allow(described_class).to receive(:start).and_return(true)

      expect(described_class.launch(port: 4567, markdown: true, view: "stage", annotate_presets: "Yes|No", editor: "zed", working_set: true,
                                    start_dir: "/")).to eq(0)
      expect(described_class).to have_received(:start)
        .with(port: 4567, host: "127.0.0.1", url: "http://127.0.0.1:4567/?dir=%2Fr", open_browser: false, markdown: true, view: "stage",
              annotate_presets: "Yes|No", editor: "zed", lan: nil, working_set: true, public_url: nil, start_dir: "/")
    end

    it "stops on Ctrl-C with one line and status 130, no backtrace" do
      allow(described_class).to receive(:probe).and_return(:free)
      allow(described_class).to receive(:start).and_raise(Interrupt)

      expect { expect(described_class.launch(port: 4567)).to eq(130) }.to output("Chi Web stopped.\n").to_stdout
    end

    it "refuses to start when others can read the participants' grants (one line, exit 1)" do
      allow(described_class).to receive(:probe).and_return(:free)
      allow(described_class).to receive(:start)
      Dir.mktmpdir("server-grants") do |state|
        with_env("XDG_STATE_HOME" => state) do
          path = Samagotchi::Web::Grants.path
          Samagotchi::Web::Grants.new(path).issue(session_id: "s1", name: "Alex")
          File.chmod(0o755, File.dirname(path))

          expect { expect(described_class.launch(port: 4567)).to eq(1) }
            .to output("Error: #{File.dirname(path)} can be read by other users: chmod 700 #{File.dirname(path)} and 600 #{path} " \
                       "(it holds the participants' grants)\n").to_stderr
        end
      end
      expect(described_class).not_to have_received(:start)
    end

    it "exits 1 when something else holds the port" do
      allow(described_class).to receive(:probe).and_return(:other)
      allow(described_class).to receive(:start)

      expect { expect(described_class.launch(port: 4567)).to eq(1) }.to output(/port 4567 is in use/).to_stderr
      expect(described_class).not_to have_received(:start)
    end
  end
end
