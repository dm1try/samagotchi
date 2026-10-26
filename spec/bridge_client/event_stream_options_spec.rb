# frozen_string_literal: true

require "samagotchi/bridge_client"

# EventStream's options for a stream through chi web (SessionAccess::
# WebBridgeClient): the idle timeout, epoch_watch, announce_retries, and
# rediscovery's reasons. All off by default: a Bridge on this machine is
# followed as before.
RSpec.describe Samagotchi::BridgeClient::EventStream, "options for a stream through chi web" do
  let(:sse_head) { "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n" }
  let(:events) { Queue.new }
  # A client that keeps its object across workers, as a web one does.
  let(:web_client_class) do
    Class.new(Samagotchi::BridgeClient) do
      attr_accessor :worker_key
    end
  end

  # One scripted connection per entry; the request heads land in +heads+.
  def scripted(scripts)
    server = TCPServer.new("127.0.0.1", 0)
    heads = Queue.new
    thread = Thread.new do
      scripts.each do |script|
        conn = server.accept
        head = +""
        head << conn.gets.to_s until head.end_with?("\r\n\r\n")
        heads << head
        script.call(conn)
        conn.close unless conn.closed?
      end
      server.close
    end
    thread.report_on_exception = false
    @cleanup = lambda do
      thread.kill
      server.close unless server.closed?
    end
    [server.local_address.ip_port, heads]
  end

  after do
    @stream&.close
    @cleanup&.call
  end

  def frame(id, type) = "id: #{id}\ndata: #{JSON.generate(type: type)}\n\n"

  def collect(count) = Array.new(count) { |i| pop!(events, "event #{i + 1} of #{count}") }

  # Holds a scripted connection open until the stream hangs up.
  def hold(conn)
    conn.read
  rescue IOError, SystemCallError
    nil
  end

  def types(list) = list.map { |event| event["type"] }

  def stream_for(client, **)
    @stream = described_class.new(client, reconnect_delays: [0.01, 0.01], **) { |event| events << event }.start
  end

  describe "idle_timeout" do
    it "reconnects with the cursor when no byte comes for that long (a half-open connection)" do
      port, heads = scripted([->(conn) { conn.write(sse_head + frame("4-e1", "snapshot")) && hold(conn) },
                              ->(conn) { conn.write(sse_head + frame("5-e1", "turn_started")) && hold(conn) }])
      stream_for(Samagotchi::BridgeClient.new(session_id: "s1", port: port, secret: nil), idle_timeout: 0.2)

      expect(types(collect(2))).to eq(%w[snapshot turn_started])
      heads.pop
      expect(heads.pop).to include("Last-Event-ID: 4-e1\r\n")
    end

    it "never fires while the Bridge's pings come (its 15 s against 40 s, here scaled down)" do
      # Pings for twice the idle timeout, then says whether the stream is still there.
      still_open = Queue.new
      pinging = lambda do |conn|
        conn.write(sse_head + frame("1-e1", "snapshot"))
        12.times do
          sleep 0.05 # sleep-ok: the Bridge's pings, well inside the idle timeout
          conn.write(": ping\n\n")
        end
        still_open << !conn.wait_readable(0) # a hang-up would read as EOF
        hold(conn)
      end
      port, heads = scripted([pinging, pinging])
      stream_for(Samagotchi::BridgeClient.new(session_id: "s1", port: port, secret: nil), idle_timeout: 0.3)

      expect(types(collect(1))).to eq(%w[snapshot])
      expect(pop!(still_open, "the pings")).to be(true)
      expect(heads.size).to eq(1)
      expect(events).to be_empty
    end

    it "is off for a Bridge on this machine: BridgeClient#follow passes none" do
      allow(described_class).to receive(:new).and_call_original
      port, = scripted([->(conn) { conn.write(sse_head) && hold(conn) }])
      @stream = Samagotchi::BridgeClient.new(session_id: "s1", port: port, secret: nil).follow { |event| events << event }

      expect(described_class).to have_received(:new).with(anything, hash_excluding(:idle_timeout, :epoch_watch,
                                                                                   :announce_retries))
      expect(@stream.instance_variable_get(:@idle_timeout)).to be_nil
    end
  end

  describe "epoch_watch" do
    it "announces a frame from another epoch than the cursor's as a new worker, and updates the client's key" do
      port, heads = scripted([->(conn) { conn.write(sse_head + frame("7-aaaa", "snapshot")) },
                              ->(conn) { conn.write(sse_head + frame("1-bbbb", "reset")) && hold(conn) }])
      client = web_client_class.new(session_id: "s1", port: port, secret: nil).tap { |made| made.worker_key = "aaaa" }
      stream_for(client, epoch_watch: true)

      expect(collect(3)).to eq([{ "type" => "snapshot" }, { "type" => "worker_changed", "port" => nil, "epoch" => "bbbb" },
                                { "type" => "reset" }])
      expect(client.worker_key).to eq("bbbb")
      heads.pop
      expect(heads.pop).to include("Last-Event-ID: 7-aaaa\r\n")
    end

    it "moves on a rediscovered key the client changed in place (the same object), with the epoch" do
      port, = scripted([->(conn) { conn.write(sse_head + frame("7-aaaa", "snapshot")) }])
      client = web_client_class.new(session_id: "s1", port: port, secret: nil).tap { |made| made.worker_key = "aaaa" }
      rediscover = lambda do
        client.worker_key = "cccc"
        client
      end
      stream_for(client, epoch_watch: true, rediscover: rediscover)

      # This stand-in has a port; a WebBridgeClient's is nil.
      expect(collect(2).last).to eq({ "type" => "worker_changed", "port" => port, "epoch" => "cccc" })
      expect(@stream.last_event_id).to be_nil
    end
  end

  describe "announce_retries" do
    it "says once that it is reconnecting, and that it is back" do
      port, = scripted([->(conn) { conn.write(sse_head + frame("1-e", "snapshot")) },
                        ->(conn) { conn.close },
                        ->(conn) { conn.close },
                        ->(conn) { conn.write(sse_head + frame("2-e", "turn_started")) && hold(conn) }])
      stream_for(Samagotchi::BridgeClient.new(session_id: "s1", port: port, secret: nil), announce_retries: true)

      expect(types(collect(4))).to eq(%w[snapshot stream_retrying stream_resumed turn_started])
    end

    it "says it is back once the stream answers, before any frame (a quiet session's replay is empty)" do
      port, = scripted([->(conn) { conn.write(sse_head + frame("1-e", "snapshot")) },
                        ->(conn) { conn.close },
                        ->(conn) { conn.write(sse_head + ": ping\n\n") && hold(conn) }])
      stream_for(Samagotchi::BridgeClient.new(session_id: "s1", port: port, secret: nil), announce_retries: true)

      expect(types(collect(3))).to eq(%w[snapshot stream_retrying stream_resumed])
    end
  end

  describe "rediscovery's reasons" do
    let(:dead_port) do
      TCPServer.new("127.0.0.1", 0).then do |server|
        server.local_address.ip_port.tap { server.close }
      end
    end

    it "closes with the reason it was gone for" do
      client = Samagotchi::BridgeClient.new(session_id: "s1", port: dead_port, secret: nil)
      stream_for(client, rediscover: -> { [:gone, "stopped"] })

      expect(collect(1)).to eq([{ "type" => "stream_closed", "reason" => "stopped" }])
    end

    it "says only that it closed when rediscovery finds the session stopped: no reconnecting line first" do
      port, = scripted([->(conn) { conn.write(sse_head + frame("1-e", "snapshot")) }])
      stream_for(Samagotchi::BridgeClient.new(session_id: "s1", port: port, secret: nil), announce_retries: true,
                                                                              rediscover: -> { [:gone, "stopped"] })

      expect(collect(2)).to eq([{ "type" => "snapshot" }, { "type" => "stream_closed", "reason" => "stopped" }])
    end

    it "closes with the last reason it gave while retrying, once the delays run out" do
      client = Samagotchi::BridgeClient.new(session_id: "s1", port: dead_port, secret: nil)
      stream_for(client, rediscover: -> { [nil, "auth"] })

      expect(collect(1)).to eq([{ "type" => "stream_closed", "reason" => "auth" }])
    end

    it "closes as unreachable without one, as before" do
      client = Samagotchi::BridgeClient.new(session_id: "s1", port: dead_port, secret: nil)
      stream_for(client, rediscover: -> { :gone })

      expect(collect(1)).to eq([{ "type" => "stream_closed", "reason" => "unreachable" }])
    end
  end
end
