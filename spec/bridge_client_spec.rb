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

    it "reads a port written as a string, and is nil for a broken sidecar, one that is not an object or has no port" do
      server = TCPServer.new("127.0.0.1", 0)
      File.write(File.join(dir, "bridge.json"), JSON.generate(port: server.local_address.ip_port.to_s))
      expect(described_class.sidecar_port(dir)).to eq(server.local_address.ip_port)

      ["{", "[1]", JSON.generate(port: 0), JSON.generate(session_id: "s1")].each do |body|
        File.write(File.join(dir, "bridge.json"), body)
        expect(described_class.sidecar_port(dir)).to be_nil, body
      end
    ensure
      server&.close
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
    expect(finish.call).to start_with("POST /session/s1/answer HTTP/1.1\r\n").and include('{"id":"q1","selected":["A"],"freeform":null,"deadline":')
  end

  it "dismisses a question by its id" do
    port, finish = serve_once(json_reply("200 OK", '{"status":"dismissed","id":"q1"}'))

    reply = described_class.new(session_id: "s1", port: port).dismiss_question(id: "q1")

    expect(reply.status).to eq(200)
    expect(reply.json).to include("status" => "dismissed")
    expect(finish.call).to start_with("POST /session/s1/question/dismiss HTTP/1.1\r\n").and include('{"id":"q1","deadline":')
  end

  it "asks the worker to stop a task by its id" do
    port, finish = serve_once(json_reply("200 OK", '{"status":"stopped","stop_reason":"stopped_by_user","task_id":"t1"}'))

    reply = described_class.new(session_id: "s1", port: port).stop_task("t1")

    expect(reply.status).to eq(200)
    expect(reply.json).to include("status" => "stopped")
    expect(finish.call).to start_with("POST /session/s1/tasks/stop HTTP/1.1\r\n").and end_with('{"task_id":"t1"}')
  end

  it "posts a session command with the client's id and returns the ACK" do
    port, finish = serve_once(json_reply("202 Accepted", '{"status":"accepted","command_id":"c1","session_id":"s1"}'))

    reply = described_class.new(session_id: "s1", port: port).post_command(line: "/model x", client_id: "tui:1")

    expect(reply.status).to eq(202)
    expect(reply.json).to include("command_id" => "c1")
    expect(finish.call).to start_with("POST /session/s1/command HTTP/1.1\r\n")
      .and include('{"line":"/model x","client_id":"tui:1","deadline":')
  end

  it "asks the worker to exit, naming the client" do
    port, finish = serve_once(json_reply("409 Conflict", '{"status":"held","reason":"turn_running","session_id":"s1"}'))

    reply = described_class.new(session_id: "s1", port: port).request_exit(client_id: "tui:1")

    expect(reply.status).to eq(409)
    expect(reply.json).to include("reason" => "turn_running")
    expect(finish.call).to start_with("POST /session/s1/exit HTTP/1.1\r\n").and include('{"client_id":"tui:1","deadline":')
  end

  it "asks the worker for a recap" do
    port, finish = serve_once(json_reply("200 OK", '{"enabled":true,"request":"started"}'))

    reply = described_class.new(session_id: "s1", port: port).request_recap

    expect(reply.json).to include("request" => "started")
    expect(finish.call).to start_with("POST /session/s1/recap HTTP/1.1\r\n")
  end

  it "says when the exit is to delete the session" do
    port, finish = serve_once(json_reply("200 OK", '{"status":"exiting","session_id":"s1"}'))

    described_class.new(session_id: "s1", port: port).request_exit(client_id: "tui:1", delete: true)

    expect(finish.call).to include('{"client_id":"tui:1","delete":true,"deadline":')
  end

  it "posts a turn with the client's id and returns the ACK" do
    port, finish = serve_once(json_reply("202 Accepted", '{"status":"accepted","enqueued_id":"e1","session_id":"s1"}'))

    reply = described_class.new(session_id: "s1", port: port).post_turn(prompt: "hi", client_id: "web:1")

    expect(reply.status).to eq(202)
    expect(reply.json).to include("enqueued_id" => "e1")
    expect(finish.call).to start_with("POST /session/s1/turn HTTP/1.1\r\n")
      .and include('{"session_id":"s1","prompt":"hi","client_id":"web:1","deadline":')
  end

  it "gives a turn a deadline before its own read timeout, so a worker never runs one it gave up on" do
    port, finish = serve_once(json_reply("202 Accepted", '{"status":"accepted","enqueued_id":"e1"}'))
    sent_at = Time.now.to_f

    described_class.new(session_id: "s1", port: port, read_timeout: 30).post_turn(prompt: "hi")

    deadline = JSON.parse(finish.call.split("\r\n\r\n", 2)[1])["deadline"]
    expect(deadline).to be_within(1).of(sent_at + 25)
  end

  # A command (a shell line), an answer or a dismissal the client gave up
  # on must not run when a frozen worker wakes, as a turn doesn't.
  {
    "a command" => ->(c) { c.post_command(line: "!ls") },
    "an answer" => ->(c) { c.answer(id: "q1", selected: ["A"]) },
    "a dismissal" => ->(c) { c.dismiss_question(id: "q1") }
  }.each do |what, send_it|
    it "gives #{what} the turn's deadline" do
      port, finish = serve_once(json_reply("202 Accepted", "{}"))
      sent_at = Time.now.to_f

      send_it.call(described_class.new(session_id: "s1", port: port, read_timeout: 30))

      deadline = JSON.parse(finish.call.split("\r\n\r\n", 2)[1])["deadline"]
      expect(deadline).to be_within(1).of(sent_at + 25)
    end
  end

  describe "#get (status-aware) and #get_json on it" do
    it "a 200: the status and the body; get_json the body" do
      port, done = serve_once(json_reply("200 OK", JSON.generate(answer: nil)))
      expect(described_class.new(session_id: "s1", port: port).get("tail")).to eq([200, { "answer" => nil }])
      expect(done.call).to start_with("GET /session/s1/tail HTTP/1.1\r\n")
      port, = serve_once(json_reply("200 OK", JSON.generate(answer: nil)))
      expect(described_class.new(session_id: "s1", port: port).get_json("tail")).to eq("answer" => nil)
    end

    it "an older worker's 404 for a route it lacks: the status and its error; get_json nil" do
      port, = serve_once(json_reply("404 Not Found", JSON.generate(error: "not_found", path: "/session/s1/tail")))
      expect(described_class.new(session_id: "s1", port: port).get("tail"))
        .to eq([404, { "error" => "not_found", "path" => "/session/s1/tail" }])
      port, = serve_once(json_reply("404 Not Found", JSON.generate(error: "not_found")))
      expect(described_class.new(session_id: "s1", port: port).get_json("tail")).to be_nil
    end

    it "a 500, a body that isn't JSON, a refused connect" do
      port, = serve_once(json_reply("500 Internal Server Error", JSON.generate(error: "bridge_error")))
      expect(described_class.new(session_id: "s1", port: port).get("tail")).to eq([500, { "error" => "bridge_error" }])
      port, = serve_once(json_reply("200 OK", "{"))
      expect(described_class.new(session_id: "s1", port: port).get("tail")).to eq([200, nil])
      closed = TCPServer.new("127.0.0.1", 0).then { |srv| srv.local_address.ip_port.tap { srv.close } }
      expect(described_class.new(session_id: "s1", port: closed).get("tail")).to eq([nil, nil])
    end
  end

  describe "a worker that takes the request and never answers" do
    let(:server) { TCPServer.new("127.0.0.1", 0) }
    let(:held) { [] }
    let(:acceptor) do
      Thread.new { loop { held << server.accept } }.tap { |t| t.report_on_exception = false }
    end
    let(:client) { described_class.new(session_id: "s1", port: server.local_address.ip_port, read_timeout: 0.3) }

    before { acceptor }

    after do
      acceptor.kill
      held.each { |c| c.close rescue nil }
      server.close
    end

    it "gives up on a post after the read timeout, with an error callers already handle" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { client.post_turn(prompt: "hi") }.to raise_error(Errno::ETIMEDOUT)
      expect { client.cancel(reason: "x") }.to raise_error(SystemCallError)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
    end

    it "gives up on a reply whose body never ends" do
      Thread.new do
        sleep 0.05 until held.any?
        held.first.write("HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\n\r\n{")
      end
      expect { client.post_command(line: "/model x") }.to raise_error(Errno::ETIMEDOUT)
    end

    it "gives up on a GET the same way (nil)" do
      expect(client.event_seq).to be_nil
      expect(client.get("tail")).to eq([nil, nil])
    end
  end

  it "waits 30 seconds for a reply by default" do
    expect(described_class::READ_TIMEOUT).to eq(30)
  end

  it "reads a reply body as UTF-8" do
    port, _done = serve_once(json_reply("202 Accepted", JSON.generate(detail: "caf\u00e9")))
    reply = described_class.new(session_id: "s1", port: port).post_command(line: "/x")
    expect(reply.body.encoding).to eq(Encoding::UTF_8)
    expect(reply.json).to eq("detail" => "caf\u00e9")
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

  it "ends a quiet stream once `running` turns false" do
    server = TCPServer.new("127.0.0.1", 0)
    peer = Thread.new do
      conn = server.accept
      conn.readpartial(16_384)
      conn.write("HTTP/1.1 200 OK\r\n\r\n")
      sleep
    end
    peer.report_on_exception = false
    running = true
    client = described_class.new(session_id: "s1", port: server.local_address.ip_port)
    reader = Thread.new { client.stream(running: -> { running }) { nil } }

    sleep 0.3
    expect(reader).to be_alive
    running = false
    expect(reader.join(1.5)).to eq(reader)
  ensure
    reader&.kill
    peer&.kill
    server&.close
  end

  it "ends a stream that never goes quiet once `running` turns false" do
    server = TCPServer.new("127.0.0.1", 0)
    peer = Thread.new do
      conn = server.accept
      conn.readpartial(16_384)
      conn.write("HTTP/1.1 200 OK\r\n\r\n")
      loop do
        conn.write("data: x\r\n\r\n")
        sleep 0.1
      end
    end
    peer.report_on_exception = false
    running = true
    chunks = 0
    client = described_class.new(session_id: "s1", port: server.local_address.ip_port)
    reader = Thread.new { client.stream(running: -> { running }) { chunks += 1 } }

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.01 until chunks.positive? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    expect(chunks).to be > 0
    running = false
    expect(reader.join(1.5)).to eq(reader)
  ensure
    reader&.kill
    peer&.kill
    server&.close
  end

  it "gives up on a Bridge that accepts the stream but never sends its headers (4.20)" do
    server = TCPServer.new("127.0.0.1", 0)
    conns = []
    peer = Thread.new do
      loop do
        conn = server.accept
        conn.readpartial(16_384)
        conns << conn # held open, never answered
      end
    end
    peer.report_on_exception = false
    client = described_class.new(session_id: "s1", port: server.local_address.ip_port)
    reader = Thread.new { client.stream(header_timeout: 0.1) { raise "no body expected" } }

    expect(reader.join(3)).to eq(reader)
    expect(conns.size).to eq(described_class::STREAM_CONNECT_ATTEMPTS)
  ensure
    reader&.kill
    peer&.kill
    conns&.each { |conn| conn.close rescue nil }
    server&.close
  end

  it "gives up on headers that start but never end" do
    server = TCPServer.new("127.0.0.1", 0)
    peer = Thread.new do
      conn = server.accept
      conn.readpartial(16_384)
      conn.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n")
      sleep
    end
    peer.report_on_exception = false
    client = described_class.new(session_id: "s1", port: server.local_address.ip_port)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(client.connect_stream(timeout: 0.2)).to be_nil
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.5
  ensure
    peer&.kill
    server&.close
  end

  describe "#relay / #relay_status (the approval relay)" do
    it "posts a relay action and keeps the reply's status and body" do
      port, received = serve_once(json_reply("409 Conflict", '{"error":"question_not_pending"}'))
      client = described_class.new(session_id: "c1", port: port)

      response = client.relay(action: "answered", relay_id: "r-1", question_id: "q-1")

      expect(response.status).to eq(409)
      expect(response.json).to eq("error" => "question_not_pending")
      request = received.call
      expect(request).to start_with("POST /session/c1/relay HTTP/1.1")
      expect(JSON.parse(request.split("\r\n\r\n", 2)[1])).to eq("action" => "answered", "relay_id" => "r-1", "question_id" => "q-1")
    end

    it "asks a relay's state with a JSON body (routes match exact paths), a 404 kept as a 404" do
      port, received = serve_once(json_reply("404 Not Found", '{"error":"unknown_relay"}'))
      response = described_class.new(session_id: "p1", port: port).relay_status("r-9")

      expect(response.status).to eq(404)
      request = received.call
      expect(request).to start_with("POST /session/p1/relay/status HTTP/1.1")
      expect(JSON.parse(request.split("\r\n\r\n", 2)[1])).to eq("relay_id" => "r-9")
    end

    it "gives up after its own short read timeout, not the 30 s default" do
      server = TCPServer.new("127.0.0.1", 0)
      hold = Thread.new { server.accept.tap { sleep 2 } }
      client = described_class.new(session_id: "c1", port: server.local_address.ip_port)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { client.relay(action: "closed", relay_id: "r", question_id: "q", read_timeout: 0.2) }
        .to raise_error(Errno::ETIMEDOUT)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
    ensure
      hold&.kill
      server&.close
    end

    it "raises when the worker is gone (the caller says not delivered)" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.ip_port
      server.close
      expect { described_class.new(session_id: "c1", port: port).relay(action: "opened", relay_id: "r", question_id: "q") }
        .to raise_error(SystemCallError)
    end
  end
end
