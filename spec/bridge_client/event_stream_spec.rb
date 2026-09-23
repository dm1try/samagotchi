# frozen_string_literal: true

require "samagotchi/bridge_client"

RSpec.describe Samagotchi::BridgeClient::EventStream do
  let(:sse_head) { "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n" }

  # A fake Bridge serving one scripted connection per entry of +scripts+.
  # Each script gets the connection after its request was read; the request
  # heads are collected in +requests+.
  def scripted_bridge(scripts)
    server = TCPServer.new("127.0.0.1", 0)
    requests = Queue.new
    thread = Thread.new do
      scripts.each do |script|
        conn = server.accept
        head = +""
        head << conn.gets.to_s until head.end_with?("\r\n\r\n")
        requests << head
        script.call(conn)
        conn.close unless conn.closed?
      end
    end
    thread.report_on_exception = false
    Struct.new(:port, :requests, :close).new(server.local_address.ip_port, requests, -> { thread.kill; server.close unless server.closed? })
  end

  def frame(seq, payload)
    "id: #{seq}\r\nevent: #{payload[:type]}\r\ndata: #{JSON.generate(payload)}\r\n\r\n"
  end

  def collect(events, count, timeout: 2)
    deadline = Time.now + timeout
    sleep 0.01 until events.size >= count || Time.now > deadline
    events.dup
  end

  let(:events) { [] }
  let(:bridge) { scripted_bridge(scripts) }
  let(:client) { Samagotchi::BridgeClient.new(session_id: "s1", port: bridge.port) }

  after do
    @stream&.close
    bridge.close.call
  end

  def follow(**opts)
    @stream = client.follow(reconnect_delays: [0.01, 0.01], **opts) { |event| events << event }
  end

  context "joining with a snapshot" do
    let(:scripts) do
      [lambda do |conn|
        conn.write(sse_head)
        conn.write(frame(5, { type: :snapshot, snapshot: { event_seq: 5, messages: [] } }))
        conn.write(": ping\r\n\r\n")
        conn.write(frame(6, { type: :turn_started, event_seq: 6 }))
        sleep 1
      end]
    end

    it "asks for a snapshot, then yields each frame as a string-keyed event" do
      follow

      got = collect(events, 2)
      expect(got.map { |e| e["type"] }).to eq(%w[snapshot turn_started])
      expect(got.first.dig("snapshot", "event_seq")).to eq(5)
      expect(@stream.last_event_id).to eq("6")
      head = bridge.requests.pop
      expect(head).to start_with("GET /session/s1/stream?snapshot=1 HTTP/1.1\r\n")
      expect(head).not_to include("Last-Event-ID")
    end

    it "names the stream with the client_id it was given" do
      follow(client_id: "tui:42")

      collect(events, 1)
      expect(bridge.requests.pop).to start_with("GET /session/s1/stream?snapshot=1&client_id=tui%3A42 HTTP/1.1\r\n")
    end

    it "stops promptly on close while the stream is quiet" do
      follow
      collect(events, 2)

      started = Time.now
      @stream.close
      expect(Time.now - started).to be < 0.5
      expect(@stream).not_to be_alive
      expect(events.map { |e| e["type"] }).not_to include("stream_closed")
    end
  end

  context "when the Bridge drops the connection" do
    let(:scripts) do
      [
        ->(conn) { conn.write(sse_head + frame(7, { type: :turn_started, event_seq: 7 })) },
        ->(conn) { conn.write(sse_head + frame(8, { type: :turn_completed, event_seq: 8 })); sleep 1 }
      ]
    end

    it "reconnects with the last seen id as Last-Event-ID" do
      follow

      expect(collect(events, 2).map { |e| e["event_seq"] }).to eq([7, 8])
      bridge.requests.pop
      expect(bridge.requests.pop).to include("Last-Event-ID: 7\r\n")
    end
  end

  context "when the Bridge goes away" do
    let(:scripts) { [->(conn) { conn.write(sse_head + frame(1, { type: :turn_started, event_seq: 1 })) }] }

    it "gives up after the reconnect delays and yields stream_closed" do
      follow
      collect(events, 1)
      bridge.close.call

      got = collect(events, 2)
      expect(got.last).to eq("type" => "stream_closed", "reason" => "unreachable")
      @stream.join(1)
      expect(@stream).not_to be_alive
    end
  end

  context "when the Bridge does not serve the session" do
    let(:scripts) do
      [->(conn) { conn.write("HTTP/1.1 404 Not Found\r\nContent-Length: 2\r\n\r\n{}") }]
    end

    it "yields stream_closed without retrying" do
      follow

      expect(collect(events, 1)).to eq([{ "type" => "stream_closed", "reason" => "unknown_session" }])
      @stream.join(1)
      expect(bridge.requests.size).to eq(1)
    end
  end
end
