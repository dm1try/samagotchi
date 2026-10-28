# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "socket"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/session"
require "samagotchi/session_manager"
require "samagotchi/session_access/remote"
require "samagotchi/session_access/web_bridge_client"
require_relative "../support/remote_backend"

# SessionAccess::WebBridgeClient: a remote attached TUI's client, through
# chi web in this process (RemoteBackend's RackTransport: the token gate
# and the LAN Host check run on every request), the worker's Bridge a
# double. Each row of the one status mapper, and RemoteFailed as
# Unreachable.
RSpec.describe Samagotchi::SessionAccess::WebBridgeClient do
  let(:state_dir) { Dir.mktmpdir("web-bridge-client") }
  let(:app) { RemoteBackend.app(state_dir: state_dir) }
  let(:remote) { RemoteBackend.access(state_dir: state_dir, app: app) }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: state_dir).tap do |made|
      made.save(state_dir: state_dir)
    end
  end
  let(:client) { remote.attach_client(session.id, worker: { "epoch" => "e1", "started_at" => "t" }) }
  let(:bridge) { instance_double(Samagotchi::BridgeClient, features: [Samagotchi::Delivery::QUEUE_FEATURE]) }

  before do
    allow(Samagotchi::SessionManager).to receive(:resume_session)
    allow(app).to receive_messages(live_bridge_client: bridge, bridge_client: bridge)
  end

  after { FileUtils.rm_rf(state_dir) }

  def reply(status, body) = Samagotchi::BridgeClient::Response.new(status: status, body: JSON.generate(body))

  it "is keyed by the worker's epoch (its start time for one without), and has no port" do
    expect([client.worker_key, client.port, client.session_id]).to eq(["e1", nil, session.id])
    expect(remote.attach_client(session.id, worker: { "epoch" => nil, "started_at" => "t" }).worker_key).to eq("t")
  end

  it "posts a turn with no_interrupt, history off, and passes the 202 ack through" do
    allow(bridge).to receive(:post_turn).and_return(reply(202, { status: "accepted", enqueued_id: "e9" }))

    response = client.post_turn(prompt: "go", client_id: "tui:1@mac", no_interrupt: true, delivery: "queue")

    expect(response.status).to eq(202)
    expect(response.json).to include("enqueued_id" => "e9", "via" => "bridge")
    expect(bridge).to have_received(:post_turn).with(prompt: "go", client_id: "tui:1@mac", delivery: "queue", no_interrupt: true)
  end

  describe "the status mapper" do
    it "raises Unreachable for chi web's 503 not_live (no live worker) and 404 not_found (no session)" do
      allow(app).to receive_messages(live_bridge_client: nil, bridge_client: nil)
      words = "no live worker for session #{session.id} on studio"

      expect { client.post_command(line: "/title x") }.to raise_error(described_class::Unreachable, words)
      expect { client.cancel(reason: "ctrl_c") }.to raise_error(described_class::Unreachable, words)

      gone = remote.attach_client("feedbeef00", worker: { "epoch" => "e1" })
      expect { gone.cancel(reason: "ctrl_c") }
        .to raise_error(described_class::Unreachable, "no live worker for session feedbeef00 on studio")
      expect(described_class::Unreachable.ancestors).to include(IOError)
    end

    it "answers 504 as the Bridge's 408 deadline_passed" do
      allow(bridge).to receive(:answer).and_return(reply(408, { error: "deadline_passed" }))

      response = client.answer(id: "q1", selected: ["A"])

      expect(response.status).to eq(408)
      expect(response.json).to include("error" => "deadline_passed")
    end

    it "answers /command's 501 for a builtin the worker lacks as the Bridge's 400 unknown_command, naming it" do
      allow(bridge).to receive(:post_command).and_return(reply(400, { error: "unknown_command", detail: "not a session command" }))

      response = client.post_command(line: "/title x", client_id: "tui:1")

      expect(response.status).to eq(400)
      expect(response.json).to include("error" => "unknown_command", "command" => "/title")
    end

    it "answers any other 501 (a route the worker lacks) as the Bridge's 404 not_found" do
      allow(bridge).to receive(:dequeue).and_return(reply(404, { error: "not_found" }))

      response = client.dequeue(enqueued_id: "e1", client_id: "tui:1")

      expect(response.status).to eq(404)
      expect(response.json).to include("error" => "not_found")
      expect(response.json["detail"]).to include("can't remove queued messages")
    end

    it "passes everything else through: the route's own 404, a 409, a 403 parent_answer_refused" do
      allow(bridge).to receive(:dequeue).and_return(reply(404, { error: "unknown_enqueued_id" }))
      allow(bridge).to receive(:cancel).and_return(reply(409, { error: "not_running" }))
      allow(bridge).to receive(:answer).and_return(reply(403, { error: "parent_answer_refused", reason: "permit" }))

      expect(client.dequeue(enqueued_id: "e1")).to have_attributes(status: 404)
      expect(client.dequeue(enqueued_id: "e1").json).to include("error" => "unknown_enqueued_id")
      expect(client.cancel(reason: "ctrl_c")).to have_attributes(status: 409)
      expect(client.answer(id: "q1", selected: ["A"], client_id: "cli:answer").json)
        .to include("error" => "parent_answer_refused", "reason" => "permit")
    end

    it "maps each row the same for every route (the table, without chi web)" do
      of = ->(status, body) { Samagotchi::SessionAccess::HTTPTransport::Reply.of(status, JSON.generate(body)) }
      map = ->(route, status, body) { described_class::Mapping.response(route, of.call(status, body), session_id: "s1", remote: "studio") }

      expect(map.call(:turn, 504, { error: "worker_timeout" })).to have_attributes(status: 408)
      expect(map.call(:command, 501, { error: "not_supported" })).to have_attributes(status: 404)
      expect(map.call(:turn, 501, { error: "not_supported", command: "/x" })).to have_attributes(status: 404)
      expect(map.call(:turn, 502, { error: "bridge_error" })).to have_attributes(status: 502)
      expect(map.call(:turn, 503, { error: "server_stopping" })).to have_attributes(status: 503)
      expect { map.call(:dismiss, 404, { error: "not_found" }) }.to raise_error(described_class::Unreachable)
    end
  end

  describe "the terminal's commands and the join's reads (P4b)" do
    it "asks the worker to exit (delete when asked) and passes its 200 and 409 held through" do
      allow(bridge).to receive(:request_exit).and_return(reply(200, { status: "exiting", discard: true }),
                                                         reply(409, { status: "held", reason: "other_ui" }))

      expect(client.request_exit(client_id: "tui:1@mac", delete: true).json).to include("status" => "exiting", "discard" => true)
      held = client.request_exit(client_id: "tui:1@mac")
      expect([held.status, held.json["reason"]]).to eq([409, "other_ui"])
      expect(bridge).to have_received(:request_exit).with(client_id: "tui:1@mac", delete: true)
      expect(bridge).to have_received(:request_exit).with(client_id: "tui:1@mac", delete: false)
    end

    it "maps exit's and recap's failures as every route: an older worker, late, no worker" do
      allow(bridge).to receive_messages(request_exit: reply(404, { error: "not_found" }), request_recap: reply(408, { error: "deadline_passed" }))
      expect(client.request_exit(client_id: "tui:1").json).to include("error" => "not_found")
      expect(client.request_recap.status).to eq(408)

      allow(app).to receive_messages(bridge_client: nil)
      expect { client.request_recap }.to raise_error(described_class::Unreachable, "no live worker for session #{session.id} on studio")
      expect { client.stats }.to raise_error(described_class::Unreachable)
    end

    it "reads the recap, the stats, the children counts and a turn's records" do
      allow(bridge).to receive(:request_recap).and_return(reply(200, { enabled: false, session_off: true }))
      allow(bridge).to receive(:get_response).with("stats")
        .and_return(Samagotchi::BridgeClient::Response.new(status: 200, body: '{"metrics":{"turns":4}}'))

      expect(client.request_recap.json).to eq("enabled" => false, "session_off" => true)
      expect(client.stats).to eq("turns" => 4)
      expect(client.children_counts).to eq("running" => 0, "waiting" => 0, "unreported" => 0)
      expect(client.turn_records("t1")).to eq("tool_records" => [], "turn_record" => nil)
    end

    it "raises Unreachable for a join read chi web can't answer (the link swallows it)" do
      gone = remote.attach_client("feedbeef00", worker: { "epoch" => "e1" })
      expect { gone.children_counts }.to raise_error(described_class::Unreachable)
      expect { gone.turn_records("t1") }.to raise_error(described_class::Unreachable)
    end

    it "reads a chi web without the P4b routes (a missing route) in Remote.too_old_message's words" do
      transport = instance_double(RemoteBackend::RackTransport)
      old = Samagotchi::SessionAccess::Remote.new(RemoteBackend.entry, transport: transport)
      info = Samagotchi::SessionAccess::HTTPTransport::Reply.of(200, JSON.generate(app: "chi-web", version: "0.1.0",
                                                                                   features: %w[session_commands remote_attach]))
      missing = Samagotchi::SessionAccess::HTTPTransport::Reply.of(404, JSON.generate(error: "not_found", detail: "not found: /api/x"))
      allow(transport).to receive(:call) { |_method, path, **| path == "/api/info" ? info : missing }
      words = Samagotchi::SessionAccess::Remote.too_old_message(RemoteBackend.entry, "0.1.0")

      attached = old.attach_client(session.id, worker: { "epoch" => "e1" })
      expect { attached.request_exit(client_id: "tui:1") }.to raise_error(described_class::Unreachable, words)
      expect { attached.stats }.to raise_error(described_class::Unreachable, words)
    end
  end

  describe "a request that can't be made (H2: never a crash in the loop)" do
    it "is Unreachable with the message, for a refused token" do
      refused = RemoteBackend.access(state_dir: state_dir, app: app, token: "wrong")
                             .attach_client(session.id, worker: { "epoch" => "e1" })

      expect { refused.cancel(reason: "ctrl_c") }
        .to raise_error(described_class::Unreachable, /remote studio \(.*\): the token was refused/)
    end

    it "is Unreachable with the message, for a transport failure and a chi web too old" do
      transport = instance_double(RemoteBackend::RackTransport)
      remote = Samagotchi::SessionAccess::Remote.new(RemoteBackend.entry, transport: transport)
      failing = remote.attach_client(session.id, worker: { "epoch" => "e1" })

      allow(transport).to receive(:call).and_raise(Samagotchi::SessionAccess::RemoteFailed, "remote studio (x): connection refused")
      expect { failing.post_turn(prompt: "hi") }
        .to raise_error(described_class::Unreachable, "remote studio (x): connection refused")

      allow(transport).to receive(:call)
        .and_return(Samagotchi::SessionAccess::HTTPTransport::Reply.of(200, JSON.generate(app: "chi-web", version: "0.1.0")))
      expect { failing.post_turn(prompt: "hi") }
        .to raise_error(described_class::Unreachable, /runs chi 0\.1\.0, too old/)
    end
  end

  describe "#open_stream" do
    # A chi web stand-in: reads one request head, answers +reply+, stays open.
    def serve(reply, bind: "127.0.0.1")
      server = TCPServer.new(bind, 0)
      heads = Queue.new
      thread = Thread.new do
        conn = server.accept
        head = +""
        head << conn.gets.to_s until head.end_with?("\r\n\r\n")
        heads << head
        conn.write(reply)
        sleep # sleep-ok: stays open, as a stream does
      end
      thread.report_on_exception = false
      @cleanup = lambda do
        thread.kill
        server.close
      end
      [server.local_address.ip_port, heads]
    end

    def serve_sequence(*replies)
      server = TCPServer.new("127.0.0.1", 0)
      heads = Queue.new
      thread = Thread.new do
        replies.each do |response|
          conn = server.accept
          head = +""
          head << conn.gets.to_s until head.end_with?("\r\n\r\n")
          heads << head
          conn.write(response)
          conn.read if response.start_with?("HTTP/1.1 200")
          conn.close
        end
      rescue IOError, SystemCallError
        nil
      ensure
        server.close unless server.closed?
      end
      thread.report_on_exception = false
      [server, server.local_address.ip_port, heads, thread]
    end

    after { @cleanup&.call }

    def client_at(port, url: "http://127.0.0.1:#{port}")
      entry = Samagotchi::Remotes::Entry.new(name: "studio", url: url, token: "tok")
      Samagotchi::SessionAccess::Remote.new(entry).attach_client("s1", worker: { "epoch" => "e1" })
    end

    it "asks chi web's stream route with the token as Bearer and the cursor as Last-Event-ID" do
      port, heads = serve("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n")
      opened = client_at(port).open_stream(query: "?snapshot=1", last_event_id: "4-e1", header_timeout: 2)

      expect(opened).to be_a(Samagotchi::BridgeClient::StreamOpen::Opened)
      expect(opened.status).to eq(200)
      expect(pop!(heads, "the request head")).to eq(
        "GET /api/sessions/s1/stream?snapshot=1 HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nAccept: text/event-stream\r\n" \
        "Last-Event-ID: 4-e1\r\nAuthorization: Bearer tok\r\nConnection: keep-alive\r\n\r\n"
      )
    ensure
      opened&.sock&.close
    end

    it "reaches an IPv6 chi web: the socket on the bare address, Host bracketed as the URL has it" do
      begin
        port, heads = serve("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n", bind: "::1")
      rescue SystemCallError, SocketError
        skip("no IPv6 loopback here")
      end
      opened = client_at(port, url: "http://[::1]:#{port}").open_stream(header_timeout: 2)

      expect(opened).to be_a(Samagotchi::BridgeClient::StreamOpen::Opened)
      expect(pop!(heads, "the request head")).to include("\r\nHost: [::1]:#{port}\r\n")
    ensure
      opened&.sock&.close
    end

    it "refuses a chunked response (a proxy in between) as unreachable, with its reason logged" do
      port, = serve("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
      allow(Samagotchi::Log).to receive(:warn)

      expect(client_at(port).open_stream(header_timeout: 2)).to be_a(Samagotchi::BridgeClient::StreamOpen::Unreachable)
      expect(Samagotchi::Log).to have_received(:warn).with(:attached, "stream_refused", reason: "chunked_unsupported",
                                                                                       remote: "studio")
    end

    it "refuses an https chi web (no TLS on the stream in v1)" do
      allow(Samagotchi::Log).to receive(:warn)

      expect(client_at(1, url: "https://studio.example:4567").open_stream(header_timeout: 0.2))
        .to be_a(Samagotchi::BridgeClient::StreamOpen::Unreachable)
      expect(Samagotchi::Log).to have_received(:warn).with(:attached, "stream_refused", reason: "tls_unsupported", remote: "studio")
    end

    it "maps stream status responses through StreamOpen" do
      refusal = Samagotchi::BridgeSecret.refused(session.id)
      body = JSON.generate(error: "bridge_secret", detail: refusal)
      port, = serve("HTTP/1.1 502 Bad Gateway\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
      expect(client_at(port).open_stream).to have_attributes(reason: :bridge_secret, detail: refusal)

      body = JSON.generate(error: "not_live")
      port, = serve("HTTP/1.1 503 Service Unavailable\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
      expect(client_at(port).open_stream)
        .to have_attributes(attempts: 1, detail: "no live worker for session s1 on studio")

      port, = serve("HTTP/1.1 404 Not Found\r\nContent-Length: 2\r\n\r\n{}")
      expect(client_at(port).open_stream).to have_attributes(reason: :unknown_session)
    end

    it "uses chi web's known 503 details, but no other detail, for the remote stream refusal" do
      worker_texts = [Samagotchi::WorkerLink.unanswered("s1"), Samagotchi::WorkerLink.not_live("s1")]
      expected = worker_texts.map { |text| "#{text} on studio" } +
                 ["#{Samagotchi::WorkerLink.not_live("s1")} on studio"]
      (worker_texts + ["an unrelated server detail"]).zip(expected).each do |detail, message|
        body = JSON.generate(error: "not_live", detail: detail)
        sock = double(wait_readable: true, readpartial: body, close: nil)
        outcome = described_class::Mapping.stream(sock, 503, { "content-length" => body.bytesize.to_s },
                                                  session_id: "s1", remote: "studio")

        expect(outcome).to have_attributes(attempts: 1, detail: message)
      end
    end

    it "shows the unanswered-worker detail when the remote stream ends" do
      detail = "#{Samagotchi::WorkerLink.unanswered("s1")} on studio"
      body = JSON.generate(error: "not_live", detail: Samagotchi::WorkerLink.unanswered("s1"))
      response = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
      server, port, heads, thread = serve_sequence(response)
      events = Queue.new
      stream = client_at(port).follow(rediscover: -> { [:gone, nil] }, reconnect_delays: []) { |event| events << event }

      expect(pop!(heads, "the remote stream request")).to include("GET /api/sessions/s1/stream?snapshot=1")
      expect(pop!(events, "the stream refusal")).to eq("type" => "stream_closed", "reason" => detail)
    ensure
      stream&.close
      server&.close unless server&.closed?
      join!(thread, "the remote stream server") if thread
    end

    it "closes a remote stream refused with 502 bridge_secret" do
      body = JSON.generate(error: "bridge_secret", detail: Samagotchi::BridgeSecret.refused(session.id))
      response = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
      server, port, heads, thread = serve_sequence(response)
      client = client_at(port)
      events = Queue.new
      stream = client.follow(rediscover: -> { client }, reconnect_delays: [0.01]) { |event| events << event }

      expect(pop!(heads, "the remote stream request")).to include("GET /api/sessions/s1/stream?snapshot=1")
      expect(pop!(events, "the secret refusal")).to eq("type" => "stream_closed", "reason" => "bridge_secret")
    ensure
      stream&.close
      server&.close unless server&.closed?
      join!(thread, "the remote stream server") if thread
    end

    it "announces a remote 503 retry, but resumes only after a 200 stream opens" do
      body = JSON.generate(error: "not_live")
      unavailable = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
      opened = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\nid: 1-e1\ndata: {\"type\":\"snapshot\"}\n\n"
      server = TCPServer.new("127.0.0.1", 0)
      heads = Queue.new
      release = Queue.new
      thread = Thread.new do
        first = server.accept
        first_head = +""
        first_head << first.gets.to_s until first_head.end_with?("\r\n\r\n")
        heads << first_head
        first.write(unavailable)
        first.close

        second = server.accept
        second_head = +""
        second_head << second.gets.to_s until second_head.end_with?("\r\n\r\n")
        heads << second_head
        release.pop
        second.write(opened)
        second.read
        second.close
      rescue IOError, SystemCallError
        nil
      ensure
        server.close unless server.closed?
      end
      thread.report_on_exception = false
      events = Queue.new
      stream = client_at(server.local_address.ip_port).follow(reconnect_delays: [0.01]) { |event| events << event }

      expect(pop!(heads, "the first remote stream request")).to include("GET /api/sessions/s1/stream?snapshot=1")
      expect(pop!(events, "the retry notice")).to eq("type" => "stream_retrying")
      expect(pop!(heads, "the retried remote stream request")).to include("GET /api/sessions/s1/stream?snapshot=1")
      expect(wait_until(timeout: 0.1) { !events.empty? }).to be(false)
      release << true
      expect(pop!(events, "the resumed notice")).to eq("type" => "stream_resumed")
      expect(pop!(events, "the first frame after resuming")).to eq("type" => "snapshot")
    ensure
      release << true if release && release.empty?
      stream&.close
      server&.close unless server&.closed?
      join!(thread, "the remote stream server") unless thread.nil?
    end

    it "follows with epoch_watch, announce_retries and the 40 s idle timeout" do
      allow(Samagotchi::BridgeClient::EventStream).to receive(:new).and_call_original
      port, = serve("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n")
      stream = client_at(port).follow(client_id: "tui:1") { |_event| nil }

      expect(Samagotchi::BridgeClient::EventStream).to have_received(:new)
        .with(anything, hash_including(epoch_watch: true, announce_retries: true, idle_timeout: 40.0))
    ensure
      stream&.close
    end
  end
end
