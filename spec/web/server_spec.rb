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
  it "says so on stderr when it can't open the browser" do
    allow(described_class).to receive(:system).and_raise(Errno::ENOENT, "open")

    expect { described_class.open_url("http://127.0.0.1:4567/") }
      .to output(/Failed to open browser: .*open — please open http:\/\/127.0.0.1:4567\/ manually/).to_stderr
  end

  # The hub logs nothing of its own: the web log's start and stop lines
  # are the server's. Server.start starts it before WEBrick and stops it
  # after.
  let(:hub) { instance_double(Samagotchi::Web::SessionHub, start: nil, stop: nil) }

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

    expect { described_class.start(port: 4999, url: "http://127.0.0.1:4999/?dir=%2Fr", hub: hub) }.not_to output.to_stdout
    expect { callback.call }.to output(%r{\AChi Web on http://127.0.0.1:4999/\?dir=%2Fr .*\nPress Ctrl-C}).to_stdout
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

      expect(described_class.launch(host: "lan", port: 4999, dir: "/", scope: "all")).to eq(0)
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

    it "won't take LAN access from a chi web already running without it" do
      allow(Samagotchi::Web::Lan).to receive(:choose).and_return(lan)
      allow(described_class).to receive(:probe).and_return({ "app" => "chi-web", "pid" => 42, "lan" => nil })
      allow(described_class).to receive(:start)

      result = nil
      expect { result = described_class.launch(host: "lan", port: 4999, dir: "/") }
        .to output("chi web already runs on port 4999 without LAN access; stop it (Ctrl-C in its terminal, or kill 42) and run this again\n").to_stderr
      expect(result).to eq(1)
      expect(described_class).not_to have_received(:start)
    end

    it "still forces 0.0.0.0 and names to 127.0.0.1, with no LAN listener" do
      allow(described_class).to receive(:probe).and_return(:free)
      allow(described_class).to receive(:start).and_return(true)

      %w[0.0.0.0 mac.local].each do |host|
        expect { described_class.launch(host: host, port: 4999, dir: "/") }.to output(/forcing 127.0.0.1/).to_stderr
      end
      expect(described_class).to have_received(:start).with(hash_including(host: "127.0.0.1", lan: nil)).twice
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

        expect { described_class.launch(port: 4567, dir: "/", scope: "all") }
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

        expect { expect(described_class.launch(host: "127.0.0.1", port: 4999, dir: state, new_token: true)).to eq(0) }
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

        expect { described_class.launch(port: 4999, dir: state, new_token: true) }
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
          .to eq("http://127.0.0.1:4567/?dir=#{repo.gsub(" ", "+")}")
        expect(described_class.scope_url("127.0.0.1", 4567, dir: repo, scope: "all")).to eq("http://127.0.0.1:4567/")
        expect(described_class.scope_url("::1", 4567, dir: tmp)).to eq("http://[::1]:4567/")
      end
    end
  end

  describe ".probe_verdict" do
    it "takes a chi web that knows ?dir, and nothing else" do
      info = { "app" => "chi-web", "pid" => 7, "features" => ["dir"] }
      expect(described_class.probe_verdict(200, JSON.generate(info))).to eq(info)
      expect(described_class.probe_verdict(200, JSON.generate(info.merge("features" => [])))).to eq(:other)
      expect(described_class.probe_verdict(404, '{"error":"not_found","detail":"not found: /api/info"}')).to eq(:other)
      expect(described_class.probe_verdict(200, "<html>")).to eq(:other)
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

    it "starts a server on a free port with the scope URL" do
      allow(described_class).to receive(:probe).and_return(:free)
      allow(described_class).to receive(:start).and_return(true)

      expect(described_class.launch(port: 4567, markdown: true, view: "stage", annotate_presets: "Yes|No")).to eq(0)
      expect(described_class).to have_received(:start)
        .with(port: 4567, host: "127.0.0.1", url: "http://127.0.0.1:4567/?dir=%2Fr", open_browser: false, markdown: true, view: "stage",
              annotate_presets: "Yes|No", lan: nil)
    end

    it "stops on Ctrl-C with one line and status 130, no backtrace" do
      allow(described_class).to receive(:probe).and_return(:free)
      allow(described_class).to receive(:start).and_raise(Interrupt)

      expect { expect(described_class.launch(port: 4567)).to eq(130) }.to output("Chi Web stopped.\n").to_stdout
    end

    it "exits 1 when something else holds the port" do
      allow(described_class).to receive(:probe).and_return(:other)
      allow(described_class).to receive(:start)

      expect { expect(described_class.launch(port: 4567)).to eq(1) }.to output(/port 4567 is in use/).to_stderr
      expect(described_class).not_to have_received(:start)
    end
  end
end
