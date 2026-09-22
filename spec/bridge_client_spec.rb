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

  it "posts an answer and exposes the reply status and JSON body" do
    port, finish = serve_once(json_reply("409 Conflict", '{"error":"question_not_pending","detail":"already answered"}'))

    reply = described_class.new(session_id: "s1", port: port).answer(id: "q1", selected: ["A"], freeform: nil)

    expect(reply.status).to eq(409)
    expect(reply.json).to include("detail" => "already answered")
    expect(finish.call).to start_with("POST /session/s1/answer HTTP/1.1\r\n").and include('{"id":"q1","selected":["A"],"freeform":null}')
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
