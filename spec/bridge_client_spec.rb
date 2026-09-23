# frozen_string_literal: true

require "tmpdir"
require "samagotchi/bridge_client"

RSpec.describe Samagotchi::BridgeClient do
  # A one-connection fake Bridge: records the raw request, sends +reply+.
  def serve_once(reply)
    server = TCPServer.new("127.0.0.1", 0)
    received = +""
    thread = Thread.new do
      conn = server.accept
      received << conn.readpartial(16_384)
      conn.write(reply)
      conn.close
    end
    thread.report_on_exception = false
    [server.local_address.ip_port, -> { thread.join(1); server.close; received }]
  end

  def json_reply(status, body)
    "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
  end

  describe ".sidecar_port / .discover" do
    let(:dir) { Dir.mktmpdir("bridge-client") }
    after { FileUtils.remove_entry(dir) }

    it "returns the advertised port of a live bridge" do
      server = TCPServer.new("127.0.0.1", 0)
      File.write(File.join(dir, "bridge.json"), JSON.generate(port: server.local_address.ip_port))

      client = described_class.discover("s1", session_dir: dir)

      expect(client.port).to eq(server.local_address.ip_port)
      expect(client.session_id).to eq("s1")
    ensure
      server&.close
    end

    it "removes a stale sidecar whose port refuses connections" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.ip_port
      server.close
      File.write(File.join(dir, "bridge.json"), JSON.generate(port: port))

      expect(described_class.sidecar_port(dir)).to be_nil
      expect(File.exist?(File.join(dir, "bridge.json"))).to be(false)
    end

    it "returns nil without a sidecar" do
      expect(described_class.discover("s1", session_dir: dir)).to be_nil
    end
  end

  describe ".wait_for" do
    let(:dir) { Dir.mktmpdir("bridge-client") }
    after { FileUtils.remove_entry(dir) }

    it "returns a client once the worker publishes a live sidecar" do
      server = TCPServer.new("127.0.0.1", 0)
      writer = Thread.new do
        sleep 0.25
        File.write(File.join(dir, "bridge.json"), JSON.generate(port: server.local_address.ip_port))
      end

      client = described_class.wait_for("s1", session_dir: dir, timeout: 3)

      expect(client.port).to eq(server.local_address.ip_port)
      expect(client.session_id).to eq("s1")
    ensure
      writer&.join
      server&.close
    end

    it "gives up with nil at the deadline" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect(described_class.wait_for("s1", session_dir: dir, timeout: 0.3)).to be_nil
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be_between(0.3, 1.0)
    end
  end

  it "posts an answer and exposes the reply status and JSON body" do
    port, finish = serve_once(json_reply("409 Conflict", '{"error":"question_not_pending","detail":"already answered"}'))

    reply = described_class.new(session_id: "s1", port: port).answer(id: "q1", selected: ["A"], freeform: nil)

    expect(reply.status).to eq(409)
    expect(reply.json).to include("detail" => "already answered")
    expect(finish.call).to start_with("POST /session/s1/answer HTTP/1.1\r\n").and include('{"id":"q1","selected":["A"],"freeform":null}')
  end

  it "dismisses a question by its id" do
    port, finish = serve_once(json_reply("200 OK", '{"status":"dismissed","id":"q1"}'))

    reply = described_class.new(session_id: "s1", port: port).dismiss_question(id: "q1")

    expect(reply.status).to eq(200)
    expect(reply.json).to include("status" => "dismissed")
    expect(finish.call).to start_with("POST /session/s1/question/dismiss HTTP/1.1\r\n").and include('{"id":"q1"}')
  end

  it "posts a turn with the client's id and returns the ACK" do
    port, finish = serve_once(json_reply("202 Accepted", '{"status":"accepted","enqueued_id":"e1","session_id":"s1"}'))

    reply = described_class.new(session_id: "s1", port: port).post_turn(prompt: "hi", client_id: "web:1")

    expect(reply.status).to eq(202)
    expect(reply.json).to include("enqueued_id" => "e1")
    expect(finish.call).to start_with("POST /session/s1/turn HTTP/1.1\r\n")
      .and include('{"session_id":"s1","prompt":"hi","client_id":"web:1"}')
  end

  it "reads the live event cursor from /state" do
    port, finish = serve_once(json_reply("200 OK", '{"session_state_snapshot":{"event_seq":42}}'))

    expect(described_class.new(session_id: "s1", port: port).event_seq).to eq(42)
    expect(finish.call).to start_with("GET /session/s1/state HTTP/1.1\r\n")
  end

  it "streams raw SSE bytes, forwarding the reconnect cursor" do
    port, finish = serve_once("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\nid: 8\r\ndata: {}\r\n\r\n")
    chunks = []

    described_class.new(session_id: "s1", port: port).stream(query: "?from_seq=3", last_event_id: "7") { |c| chunks << c }

    expect(chunks.join).to eq("id: 8\r\ndata: {}\r\n\r\n")
    expect(finish.call).to include("GET /session/s1/stream?from_seq=3 HTTP/1.1\r\n", "Last-Event-ID: 7\r\n")
  end
end
