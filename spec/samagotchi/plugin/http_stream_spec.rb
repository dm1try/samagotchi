# frozen_string_literal: true

require "spec_helper"
require "socket"
require "samagotchi/plugin/context"
require "samagotchi/cancellation_controller"
require_relative "../../support/fake_provider_server"

# ctx.http.stream (docs/plugins.md, "Calling services"): the real transport
# against a raw TCPServer that holds the stream open, so a spec sees when
# the client closes it.
module HttpStreamSpec
  # One connection: reads the request, answers +head+ and +chunks+
  # (chunked), then holds the stream open until the client closes it
  # (#closed pops :closed then).
  class HeldStream
    attr_reader :request

    def initialize(status: 200, headers: { "Content-Type" => "text/event-stream" }, chunks: [], hold: true)
      @server = TCPServer.new("127.0.0.1", 0)
      @closed = Queue.new
      @got = Queue.new
      @thread = Thread.new { serve(status, headers, chunks, hold) }
    end

    def url = "http://127.0.0.1:#{@server.addr[1]}/mcp?key=SECRET"

    def closed = SpecWaiting.pop!(@closed, "the client to close the stream")

    def got = SpecWaiting.pop!(@got, "the request")

    def stop
      @thread.kill
      @server.close
    end

    private

    def serve(status, headers, chunks, hold)
      client = @server.accept
      head = +""
      head << client.readpartial(4096) until head.include?("\r\n\r\n")
      @got << head
      lines = ["HTTP/1.1 #{status} X", "Transfer-Encoding: chunked", *headers.map { |k, v| "#{k}: #{v}" }]
      client.write("#{lines.join("\r\n")}\r\n\r\n")
      chunks.each { |chunk| client.write("#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n") }
      client.write("0\r\n\r\n") unless hold
      begin
        client.read # blocks until the client closes
      rescue IOError, SystemCallError
        nil
      end
      @closed << :closed
    ensure
      client&.close
    end
  end
end

RSpec.describe Samagotchi::Plugin::Http::Stream do
  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:http) { Samagotchi::Plugin::Http.new(bundle: "echo") }
  let(:lines) { [] }
  let(:streams) { [] }
  let(:server) { held(chunks: ["data: one\n\n"]) }

  before do
    allow(Samagotchi::Log).to receive(:public_send).and_wrap_original do |original, level, tag, event, **fields|
      lines << [level, event, fields] if tag == :http
      original.call(level, tag, event, **fields)
    end
  end

  after { streams.each(&:stop) }

  def held(**options) = HttpStreamSpec::HeldStream.new(**options).tap { |stream| streams << stream }

  # The stream's first event; the rest is left unread.
  def first_event(res)
    res.each_event { |event| return event } # rubocop:disable Lint/UnreachableLoop -- stopping mid-stream is the point
    nil
  end

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  it "hands the status and headers before the body, and a body read once" do
    value = http.stream("POST", server.url, body: "{}", headers: { "Accept" => "text/event-stream" }) do |res|
      expect([res.status, res.ok?, res.headers["content-type"]]).to eq([200, true, "text/event-stream"])
      expect(res.headers).to be_frozen
      expect(first_event(res)).to eq(Samagotchi::Plugin::Http::SseReader::Event.new(type: "message", data: "one", id: nil))
      expect(res.body).to eq("")
      :value
    end

    expect(value).to eq(:value)
    expect(server.got).to include("POST /mcp?key=SECRET", "User-Agent: #{Samagotchi::USER_AGENT}")
  end

  describe "leaving the block closes the connection" do
    it "at its end, at once, on a stream the server holds open" do
      took = elapsed { http.stream("POST", server.url, timeout: 30) { |res| first_event(res) } }

      expect(server.closed).to eq(:closed)
      expect(took).to be < time_bound(5, below: 30)
    end

    it "on a break" do
      http.stream("POST", server.url, timeout: 30) { |res| break first_event(res) }

      expect(server.closed).to eq(:closed)
    end

    it "on a return" do
      leave = lambda do
        http.stream("POST", server.url, timeout: 30) { |_res| return :returned }
        :not_returned
      end

      expect(leave.call).to eq(:returned)
      expect(server.closed).to eq(:closed)
    end

    it "on a raise, which goes on as it is, not logged as chi's bug" do
      allow(Samagotchi::Log).to receive(:exception)
      expect { http.stream("POST", server.url, timeout: 30) { |res| first_event(res) && raise(NoMethodError, "mine") } }
        .to raise_error(NoMethodError, "mine")

      expect(server.closed).to eq(:closed)
      expect(Samagotchi::Log).not_to have_received(:exception)
    end
  end

  describe "the log line" do
    it "is one INFO stream line with the status on each way out, the URL without its query" do
      http.stream("POST", server.url) { |res| first_event(res) }
      expect { http.stream("POST", held(chunks: ["data: x\n\n"]).url) { raise ArgumentError, "mine" } }
        .to raise_error(ArgumentError)
      http.stream("POST", held.url) { break }

      expect(lines.map { |level, event, fields| [level, event, fields[:status], fields[:purpose], fields[:bundle]] })
        .to eq([[:info, "stream", 200, "plugin", "echo"]] * 3)
      expect(lines.first[2][:url]).to eq(server.url.sub(/\?.*/, ""))
      expect(lines.inspect).not_to include("SECRET")
    end

    it "is an ERROR line when the body's read fails on the wire" do
      expect { http.stream("POST", held.url, timeout: 0.3, &:body) }
        .to raise_error(Samagotchi::Plugin::HttpError)

      expect(lines.map { |level, event, _| [level, event] }).to eq([[:error, "failed"]])
    end
  end

  describe "errors" do
    it "raises HttpError 'timed out' from inside the read when the stream stays quiet longer than the timeout" do
      raised = nil
      http.stream("POST", server.url, timeout: 0.3) do |res|
        res.each_event { |_event| nil }
      rescue Samagotchi::Plugin::HttpError => e
        raised = e
      end

      expect(raised.message).to match(/\APOST 127\.0\.0\.1:\d+: timed out\z/)
      expect(raised).not_to be_a(Samagotchi::Plugin::HttpCancelled)
    end

    it "raises HttpCancelled from inside the read when cancelled mid-body" do
      cancel = Samagotchi::CancellationController.new
      raised = nil
      took = elapsed do
        http.stream("POST", server.url, timeout: 30, cancel: cancel) do |res|
          res.each_event { |_event| Thread.new { cancel.cancel!(:manual) } }
        rescue Samagotchi::Plugin::HttpError => e
          raised = e
        end
      end

      expect(raised).to be_a(Samagotchi::Plugin::HttpCancelled)
      expect(took).to be < time_bound(5, below: 30)
      expect(lines.map { |_, event, _| event }).to eq(["cancelled"])
    end

    it "raises HttpCancelled before the block for a controller already cancelled" do
      cancel = Samagotchi::CancellationController.new.tap { |c| c.cancel!(:manual) }

      expect { http.stream("POST", server.url, cancel: cancel) { :never } }.to raise_error(Samagotchi::Plugin::HttpCancelled)
    end

    it "raises HttpError for a refused connection, before the block" do
      port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }

      expect { http.stream("GET", "http://127.0.0.1:#{port}/x") { :never } }
        .to raise_error(Samagotchi::Plugin::HttpError, /connection refused/)
    end

    it "hands a 500 to the block with its body" do
      failing = held(status: 500, headers: { "Content-Type" => "text/plain" }, chunks: ["down"], hold: false)

      expect(http.stream("POST", failing.url) { |res| [res.status, res.ok?, res.body] }).to eq([500, false, "down"])
    end

    it "needs a block, and checks its arguments as #request does" do
      expect { http.stream("POST", server.url) }.to raise_error(ArgumentError, /needs a block/)
      expect { http.stream("TRACE", server.url) { nil } }.to raise_error(ArgumentError, /unknown HTTP method/)
    end
  end

  describe "reads" do
    let(:server) { held(headers: { "Content-Type" => "application/json" }, chunks: ['{"a":', "1}"], hold: false) }

    it "each_chunk yields the pieces as they arrive, then nothing more" do
      pieces, again = http.stream("GET", server.url) do |res|
        got = []
        res.each_chunk { |bytes| got << bytes }
        later = []
        res.each_chunk { |bytes| later << bytes }
        [got, later]
      end

      expect(pieces.join).to eq('{"a":1}')
      expect(again).to be_empty
    end

    it "json parses the body, and raises HttpError 'not JSON' for one that isn't" do
      expect(http.stream("GET", server.url, &:json)).to eq("a" => 1)
      plain = held(chunks: ["nope"], hold: false)
      expect { http.stream("GET", plain.url, &:json) }.to raise_error(Samagotchi::Plugin::HttpError, /not JSON/)
    end
  end
end
