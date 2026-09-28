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

      expect(described_class.launch(port: 4567, markdown: true, turn_view: true, annotate_presets: "Yes|No")).to eq(0)
      expect(described_class).to have_received(:start)
        .with(port: 4567, host: "127.0.0.1", url: "http://127.0.0.1:4567/?dir=%2Fr", open_browser: false, markdown: true, turn_view: true,
              annotate_presets: "Yes|No")
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
