# frozen_string_literal: true

require "tmpdir"
require "samagotchi/bridge_client"
require "samagotchi/worker_link"
require_relative "support/worker_fixtures"

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
    [server.local_address.ip_port, -> { join!(thread, "the fake Bridge"); server.close; received }]
  end

  def json_reply(status, body)
    "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
  end

  it "carries the features of the sidecar it was made from, none without one" do
    sidecar = Samagotchi::WorkerSidecar.new(port: 4100, features: %w[delivery review_turns])
    expect(described_class.for_sidecar("s1", sidecar).features).to eq(%w[delivery review_turns])
    expect(described_class.new(session_id: "s1", port: 4100, secret: nil).features).to eq([])
  end

  describe "the Bridge's secret" do
    include WorkerFixtures

    let(:dir) { Dir.mktmpdir("bridge-client") }
    let(:secret) { "ab" * 32 }
    let(:ok) { json_reply("200 OK", "{}") }

    after { FileUtils.remove_entry(dir) }

    # A sidecar naming the fake Bridge's port and +secret+, as Bridge#write_sidecar writes it.
    def publish(port, secret)
      @worker ||= hold_worker(dir)
      Samagotchi::WorkerSidecar.new(port: port, secret: secret, pid: Process.pid).write(dir)
    end

    it "is sent with every request, by a client made from the sidecar: a post, a get and the stream" do
      requests = [
        ->(client) { client.post_turn(prompt: "hi") },
        ->(client) { client.get("state") },
        ->(client) { client.read_stream(client.open_stream) { nil } }
      ]
      heads = requests.map do |send_it|
        port, finish = serve_once(ok)
        publish(port, secret)
        send_it.call(Samagotchi::WorkerLink.client("s1", session_dir: dir))
        finish.call
      end

      expect(heads).to all(include("\r\nX-Chi-Bridge: #{secret}\r\n"))
    end

    it "is the one a respawned worker wrote: a client made after it reads the new sidecar" do
      port, finish = serve_once(ok)
      publish(port, secret)
      Samagotchi::WorkerLink.client("s1", session_dir: dir).post_turn(prompt: "old")
      finish.call
      port, finish = serve_once(ok)
      publish(port, "cd" * 32)

      Samagotchi::WorkerLink.client("s1", session_dir: dir).post_turn(prompt: "new")

      head = finish.call
      expect(head).to include("X-Chi-Bridge: #{"cd" * 32}\r\n")
      expect(head).not_to include(secret)
    end

    it "is not sent for a worker from before secrets (its sidecar names none)" do
      port, finish = serve_once(ok)
      publish(port, nil)

      Samagotchi::WorkerLink.client("s1", session_dir: dir).get("state")

      expect(finish.call).not_to match(/x-chi-bridge/i)
    end

    it "makes another worker key: a new worker on the old one's port is still a new worker" do
      old = described_class.new(session_id: "s1", port: 4100, secret: secret)
      same = described_class.new(session_id: "s1", port: 4100, secret: secret)
      respawned = described_class.new(session_id: "s1", port: 4100, secret: "cd" * 32)

      expect(old.worker_key).to eq(same.worker_key)
      expect(old.worker_key).not_to eq(respawned.worker_key)
      expect(old.worker_key.to_s).not_to include(secret)
    end

    it "never shows in an inspect, the client's or the sidecar's" do
      publish(4100, secret)

      expect(described_class.new(session_id: "s1", port: 4100, secret: secret).inspect).not_to include(secret)
      expect(Samagotchi::WorkerSidecar.read(dir).inspect).not_to include(secret)
      expect(Samagotchi::WorkerSidecar.read(dir).to_s).not_to include(secret)
    end
  end

  it "posts an answer and exposes the reply status and JSON body" do
    port, finish = serve_once(json_reply("409 Conflict", '{"error":"question_not_pending","detail":"already answered"}'))

    reply = described_class.new(session_id: "s1", port: port, secret: nil).answer(id: "q1", selected: ["A"], freeform: nil)

    expect(reply.status).to eq(409)
    expect(reply.json).to include("detail" => "already answered")
    expect(finish.call).to start_with("POST /session/s1/answer HTTP/1.1\r\n").and include('{"id":"q1","selected":["A"],"freeform":null,"deadline":')
  end

  it "dismisses a question by its id" do
    port, finish = serve_once(json_reply("200 OK", '{"status":"dismissed","id":"q1"}'))

    reply = described_class.new(session_id: "s1", port: port, secret: nil).dismiss_question(id: "q1")

    expect(reply.status).to eq(200)
    expect(reply.json).to include("status" => "dismissed")
    expect(finish.call).to start_with("POST /session/s1/question/dismiss HTTP/1.1\r\n").and include('{"id":"q1","deadline":')
  end

  it "asks the worker to stop a task by its id" do
    port, finish = serve_once(json_reply("200 OK", '{"status":"stopped","stop_reason":"stopped_by_user","task_id":"t1"}'))

    reply = described_class.new(session_id: "s1", port: port, secret: nil).stop_task("t1")

    expect(reply.status).to eq(200)
    expect(reply.json).to include("status" => "stopped")
    expect(finish.call).to start_with("POST /session/s1/tasks/stop HTTP/1.1\r\n").and end_with('{"task_id":"t1"}')
  end

  it "asks the worker to remove a queued message by its enqueued_id, naming the client" do
    port, finish = serve_once(json_reply("200 OK", '{"status":"removed","enqueued_id":"e1","prompt":"later"}'))

    reply = described_class.new(session_id: "s1", port: port, secret: nil).dequeue(enqueued_id: "e1", client_id: "tui:1")

    expect(reply.status).to eq(200)
    expect(reply.json).to include("prompt" => "later")
    expect(finish.call).to start_with("POST /session/s1/turn/dequeue HTTP/1.1\r\n")
      .and include('{"enqueued_id":"e1","client_id":"tui:1","deadline":')
  end

  it "posts a session command with the client's id and returns the ACK" do
    port, finish = serve_once(json_reply("202 Accepted", '{"status":"accepted","command_id":"c1","session_id":"s1"}'))

    reply = described_class.new(session_id: "s1", port: port, secret: nil).post_command(line: "/model x", client_id: "tui:1")

    expect(reply.status).to eq(202)
    expect(reply.json).to include("command_id" => "c1")
    expect(finish.call).to start_with("POST /session/s1/command HTTP/1.1\r\n")
      .and include('{"line":"/model x","client_id":"tui:1","deadline":')
  end

  it "asks the worker to exit, naming the client" do
    port, finish = serve_once(json_reply("409 Conflict", '{"status":"held","reason":"turn_running","session_id":"s1"}'))

    reply = described_class.new(session_id: "s1", port: port, secret: nil).request_exit(client_id: "tui:1")

    expect(reply.status).to eq(409)
    expect(reply.json).to include("reason" => "turn_running")
    expect(finish.call).to start_with("POST /session/s1/exit HTTP/1.1\r\n").and include('{"client_id":"tui:1","deadline":')
  end

  it "asks the worker for a recap" do
    port, finish = serve_once(json_reply("200 OK", '{"enabled":true,"request":"started"}'))

    reply = described_class.new(session_id: "s1", port: port, secret: nil).request_recap

    expect(reply.json).to include("request" => "started")
    expect(finish.call).to start_with("POST /session/s1/recap HTTP/1.1\r\n")
  end

  it "says when the exit is to delete the session" do
    port, finish = serve_once(json_reply("200 OK", '{"status":"exiting","session_id":"s1"}'))

    described_class.new(session_id: "s1", port: port, secret: nil).request_exit(client_id: "tui:1", delete: true)

    expect(finish.call).to include('{"client_id":"tui:1","delete":true,"deadline":')
  end

  it "posts a turn with the client's id and returns the ACK" do
    port, finish = serve_once(json_reply("202 Accepted", '{"status":"accepted","enqueued_id":"e1","session_id":"s1"}'))

    reply = described_class.new(session_id: "s1", port: port, secret: nil).post_turn(prompt: "hi", client_id: "web:1")

    expect(reply.status).to eq(202)
    expect(reply.json).to include("enqueued_id" => "e1")
    expect(finish.call).to start_with("POST /session/s1/turn HTTP/1.1\r\n")
      .and include('{"session_id":"s1","prompt":"hi","client_id":"web:1","deadline":')
  end

  it "gives a turn a deadline before its own read timeout, so a worker never runs one it gave up on" do
    port, finish = serve_once(json_reply("202 Accepted", '{"status":"accepted","enqueued_id":"e1"}'))
    sent_at = Time.now.to_f

    described_class.new(session_id: "s1", port: port, secret: nil, read_timeout: 30).post_turn(prompt: "hi")

    deadline = JSON.parse(finish.call.split("\r\n\r\n", 2)[1])["deadline"]
    expect(deadline).to be_within(1).of(sent_at + 25)
  end

  # A command (a shell line), an answer or a dismissal the client gave up
  # on must not run when a frozen worker wakes, as a turn doesn't.
  {
    "a command" => ->(c) { c.post_command(line: "!ls") },
    "an answer" => ->(c) { c.answer(id: "q1", selected: ["A"]) },
    "a dismissal" => ->(c) { c.dismiss_question(id: "q1") },
    "a removal" => ->(c) { c.dequeue(enqueued_id: "e1") }
  }.each do |what, send_it|
    it "gives #{what} the turn's deadline" do
      port, finish = serve_once(json_reply("202 Accepted", "{}"))
      sent_at = Time.now.to_f

      send_it.call(described_class.new(session_id: "s1", port: port, secret: nil, read_timeout: 30))

      deadline = JSON.parse(finish.call.split("\r\n\r\n", 2)[1])["deadline"]
      expect(deadline).to be_within(1).of(sent_at + 25)
    end
  end

  describe "#get (status-aware) and #get_json on it" do
    it "a 200: the status and the body; get_json the body" do
      port, done = serve_once(json_reply("200 OK", JSON.generate(answer: nil)))
      expect(described_class.new(session_id: "s1", port: port, secret: nil).get("tail")).to eq([200, { "answer" => nil }])
      expect(done.call).to start_with("GET /session/s1/tail HTTP/1.1\r\n")
      port, = serve_once(json_reply("200 OK", JSON.generate(answer: nil)))
      expect(described_class.new(session_id: "s1", port: port, secret: nil).get_json("tail")).to eq("answer" => nil)
    end

    it "an older worker's 404 for a route it lacks: the status and its error; get_json nil" do
      port, = serve_once(json_reply("404 Not Found", JSON.generate(error: "not_found", path: "/session/s1/tail")))
      expect(described_class.new(session_id: "s1", port: port, secret: nil).get("tail"))
        .to eq([404, { "error" => "not_found", "path" => "/session/s1/tail" }])
      port, = serve_once(json_reply("404 Not Found", JSON.generate(error: "not_found")))
      expect(described_class.new(session_id: "s1", port: port, secret: nil).get_json("tail")).to be_nil
    end

    it "a 500, a body that isn't JSON, a refused connect" do
      port, = serve_once(json_reply("500 Internal Server Error", JSON.generate(error: "bridge_error")))
      expect(described_class.new(session_id: "s1", port: port, secret: nil).get("tail")).to eq([500, { "error" => "bridge_error" }])
      port, = serve_once(json_reply("200 OK", "{"))
      expect(described_class.new(session_id: "s1", port: port, secret: nil).get("tail")).to eq([200, nil])
      closed = TCPServer.new("127.0.0.1", 0).then { |srv| srv.local_address.ip_port.tap { srv.close } }
      expect(described_class.new(session_id: "s1", port: closed, secret: nil).get("tail")).to eq([nil, nil])
    end
  end

  describe "a worker that takes the request and never answers" do
    let(:server) { TCPServer.new("127.0.0.1", 0) }
    let(:held) { [] }
    let(:acceptor) do
      Thread.new { loop { held << server.accept } }.tap { |t| t.report_on_exception = false }
    end
    let(:client) { described_class.new(session_id: "s1", port: server.local_address.ip_port, secret: nil, read_timeout: 0.3) }

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
        wait_for("the post's connection", timeout: 10) { held.any? }
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

  it "raises on I/O from #get_response" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.ip_port
    server.close

    expect { described_class.new(session_id: "s1", port: port, secret: nil).get_response("stats") }
      .to raise_error(Errno::ECONNREFUSED)
  end

  it "reads a reply body as UTF-8" do
    port, _done = serve_once(json_reply("202 Accepted", JSON.generate(detail: "caf\u00e9")))
    reply = described_class.new(session_id: "s1", port: port, secret: nil).post_command(line: "/x")
    expect(reply.body.encoding).to eq(Encoding::UTF_8)
    expect(reply.json).to eq("detail" => "caf\u00e9")
  end

  it "reads the live event cursor from /state" do
    port, finish = serve_once(json_reply("200 OK", '{"session_state_snapshot":{"event_seq":42}}'))

    expect(described_class.new(session_id: "s1", port: port, secret: nil).event_seq).to eq(42)
    expect(finish.call).to start_with("GET /session/s1/state HTTP/1.1\r\n")
  end

  it "streams raw SSE bytes, forwarding the reconnect cursor" do
    port, finish = serve_once("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\nid: 8\r\ndata: {}\r\n\r\n")
    chunks = []

    client = described_class.new(session_id: "s1", port: port, secret: nil)
    client.read_stream(client.open_stream(query: "?from_seq=3", last_event_id: "7")) { |c| chunks << c }

    expect(chunks.join).to eq("id: 8\r\ndata: {}\r\n\r\n")
    expect(finish.call).to include("GET /session/s1/stream?from_seq=3 HTTP/1.1\r\n", "Last-Event-ID: 7\r\n")
  end

  it "passes no refusal on as a stream: a 403's JSON (bridge_secret) yields nothing" do
    port, finish = serve_once(json_reply("403 Forbidden", JSON.generate(error: "bridge_secret", detail: "restart")))
    chunks = []

    client = described_class.new(session_id: "s1", port: port, secret: nil)
    outcome = client.open_stream
    expect(outcome).to have_attributes(reason: :bridge_secret)

    finish.call
    expect(chunks).to be_empty
  end

  it "ends a quiet stream once `running` turns false" do
    server = TCPServer.new("127.0.0.1", 0)
    peer = Thread.new do
      conn = server.accept
      conn.readpartial(16_384)
      conn.write("HTTP/1.1 200 OK\r\n\r\n")
      sleep # sleep-ok: holds the quiet stream open
    end
    peer.report_on_exception = false
    running = true
    asked = 0
    client = described_class.new(session_id: "s1", port: server.local_address.ip_port, secret: nil)
    opened = client.open_stream
    reader = Thread.new { client.read_stream(opened, running: -> { asked += 1; running }) { nil } }

    # Asked again after a silent STREAM_POLL: the quiet stream went on.
    wait_for("the stream to ask `running` twice") { asked >= 2 }
    expect(reader).to be_alive
    running = false
    join!(reader, "the stream")
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
        sleep 0.1 # sleep-ok: a stream that never goes quiet
      end
    end
    peer.report_on_exception = false
    running = true
    chunks = 0
    client = described_class.new(session_id: "s1", port: server.local_address.ip_port, secret: nil)
    opened = client.open_stream
    reader = Thread.new { client.read_stream(opened, running: -> { running }) { chunks += 1 } }

    wait_for("the first chunk") { chunks.positive? }
    running = false
    expect(join!(reader, "the stream")).not_to be_alive
  ensure
    reader&.kill
    peer&.kill
    server&.close
  end

  it "does not retry a Bridge that accepts the stream but never sends its headers" do
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
    client = described_class.new(session_id: "s1", port: server.local_address.ip_port, secret: nil)
    outcome = client.open_stream(header_timeout: 0.1)

    expect(outcome).to have_attributes(attempts: 1)
    expect(conns.size).to eq(1)
  ensure
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
      sleep # sleep-ok: holds the headers unfinished
    end
    peer.report_on_exception = false
    client = described_class.new(session_id: "s1", port: server.local_address.ip_port, secret: nil)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { client.connect_stream(timeout: 0.2) }.to raise_error(Errno::ETIMEDOUT)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.5
  ensure
    peer&.kill
    server&.close
  end

  describe "#relay / #relay_status (the approval relay)" do
    it "posts a relay action and keeps the reply's status and body" do
      port, received = serve_once(json_reply("409 Conflict", '{"error":"question_not_pending"}'))
      client = described_class.new(session_id: "c1", port: port, secret: nil)

      response = client.relay(action: "answered", relay_id: "r-1", question_id: "q-1")

      expect(response.status).to eq(409)
      expect(response.json).to eq("error" => "question_not_pending")
      request = received.call
      expect(request).to start_with("POST /session/c1/relay HTTP/1.1")
      expect(JSON.parse(request.split("\r\n\r\n", 2)[1])).to eq("action" => "answered", "relay_id" => "r-1", "question_id" => "q-1")
    end

    it "asks a relay's state with a JSON body (routes match exact paths), a 404 kept as a 404" do
      port, received = serve_once(json_reply("404 Not Found", '{"error":"unknown_relay"}'))
      response = described_class.new(session_id: "p1", port: port, secret: nil).relay_status("r-9")

      expect(response.status).to eq(404)
      request = received.call
      expect(request).to start_with("POST /session/p1/relay/status HTTP/1.1")
      expect(JSON.parse(request.split("\r\n\r\n", 2)[1])).to eq("relay_id" => "r-9")
    end

    it "gives up after its own short read timeout, not the 30 s default" do
      server = TCPServer.new("127.0.0.1", 0)
      hold = Thread.new { server.accept.tap { sleep } } # sleep-ok: holds the request unanswered
      client = described_class.new(session_id: "c1", port: server.local_address.ip_port, secret: nil)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { client.relay(action: "closed", relay_id: "r", question_id: "q", read_timeout: 0.2) }
        .to raise_error(Errno::ETIMEDOUT)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5 # not the full 30 s
    ensure
      hold&.kill
      server&.close
    end

    it "raises when the worker is gone (the caller says not delivered)" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.ip_port
      server.close
      expect { described_class.new(session_id: "c1", port: port, secret: nil).relay(action: "opened", relay_id: "r", question_id: "q") }
        .to raise_error(SystemCallError)
    end
  end
end
