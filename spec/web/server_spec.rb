# frozen_string_literal: true

require "stringio"
require "fileutils"
require "tmpdir"
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
end

RSpec.describe Samagotchi::Web::Server do
  it "says so on stderr when it can't open the browser" do
    allow(described_class).to receive(:system).and_raise(Errno::ENOENT, "open")

    expect { described_class.open_url("http://127.0.0.1:4567/") }
      .to output(/Failed to open browser: .*open — please open http:\/\/127.0.0.1:4567\/ manually/).to_stderr
  end

  it "writes its start and stop to the log" do
    dir = Dir.mktmpdir
    Samagotchi::Log.configure(path: File.join(dir, "chi.log"))
    allow(Samagotchi::Web::App).to receive(:new).and_return(double("app"))
    allow(Rackup::Handler::WEBrick).to receive(:run)

    expect { described_class.start(port: 4998) }.to output.to_stdout

    records = File.open(File.join(dir, "chi.log")) { |io| Samagotchi::LogLine.each_record(io).to_a }
    expect(records.map { |r| [r.tag, r.event, r.fields] }).to eq([
      ["web", "start", { "url" => "http://127.0.0.1:4998", "version" => Samagotchi::VERSION }], ["web", "stop", {}]
    ])
  ensure
    FileUtils.remove_entry(dir)
  end

  it "binds to 127.0.0.1 whatever host it is given, with a warning" do
    allow(Samagotchi::Web::App).to receive(:new).and_return(double("app"))
    allow(Rackup::Handler::WEBrick).to receive(:run)

    expect { described_class.start(port: 4999, host: "0.0.0.0") }
      .to output(/forcing 127.0.0.1/).to_stderr.and output(/starting on http:\/\/127.0.0.1:4999/).to_stdout
    expect(Rackup::Handler::WEBrick).to have_received(:run).with(anything, hash_including(Host: "127.0.0.1", Port: 4999))
  end
end
