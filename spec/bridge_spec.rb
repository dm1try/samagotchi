# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "stringio"
require "socket"
require "net/http"
require "json"
require "support/test_kernel"

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/bridge"
require "samagotchi/bridge_client"

# Minimal SSE/HTTP client for the bridge integration specs. Talks a raw
# TCP request/response against the in-process bridge so we can read the
# live event-stream incrementally (Net::HTTP blocks on an open stream).
class SSEClient
  attr_reader :events

  def initialize(port, session_id, last_event_id: nil, snapshot: false, client_id: nil)
    @client_id = client_id
    @port = port
    @session_id = session_id
    @last_event_id = last_event_id
    @snapshot = snapshot
    @events = []
    @mutex = Mutex.new
    @cv = ConditionVariable.new
    @done = false
  end

  def start
    @socket = TCPSocket.new("127.0.0.1", @port)
    @socket.binmode
    query = @last_event_id ? "?from_seq=#{@last_event_id}" : ""
    query = "?snapshot=1" if @snapshot
    query = "#{query.empty? ? "?" : "#{query}&"}client_id=#{URI.encode_www_form_component(@client_id)}" if @client_id
    @socket.write(
      "GET /session/#{@session_id}/stream#{query} HTTP/1.1\r\n" \
      "Host: 127.0.0.1\r\n" \
      "Connection: close\r\n" \
      "User-Agent: bridge-spec\r\n\r\n"
    )
    @status_line, = read_headers(@socket)
    @reader = Thread.new { read_loop }
    self
  end

  def stop
    @done = true
    @socket&.close
    @reader&.join(0.5)
    @reader&.kill if @reader&.alive?
  rescue StandardError
    nil
  end

  def status_code
    @status_line.to_s.split(" ")[1].to_i
  end

  # Block until +count+ events are visible (or timeout elapses).
  # @return [Array<Hash>] a snapshot of the events seen so far.
  def wait_for(count, timeout: 3)
    wait_until(timeout: timeout) { |events| events.size >= count }
  end

  # Block until the events seen so far satisfy the block (or timeout
  # elapses): a turn's events reach a client on the bridge's own threads,
  # after run_turn has returned.
  # @return [Array<Hash>] a snapshot of the events seen so far.
  def wait_until(timeout: 3)
    deadline = SpecWaiting.mono + timeout
    @mutex.synchronize do
      until yield(@events) || SpecWaiting.mono > deadline
        @cv.wait(@mutex, [deadline - SpecWaiting.mono, 0].max)
      end
    end
    @events.dup
  end

  def last
    @mutex.synchronize { @events.last }
  end

  private

  def read_loop
    until @done
      event = read_event(@socket)
      break if event.nil?

      raw = event[:data]
      data = raw && !raw.strip.empty? ? JSON.parse(raw) : {}
      @mutex.synchronize do
        @events << { id: event[:id], data: data }
        @cv.broadcast
      end
    end
  rescue StandardError
    nil
  ensure
    @mutex.synchronize { @done = true; @cv.broadcast }
  end

  def read_event(io)
    event = { id: nil, data: nil }
    loop do
      line = io.gets("\n")
      break if line.nil?

      line = line.chomp
      if line.empty?
        # Blank line ends a frame. Only return it if it carried content;
        # otherwise it's a heartbeat / comment block — keep reading.
        return event if event[:id] || event[:data]

        event = { id: nil, data: nil }
        next
      elsif line.start_with?(":")
        next # heartbeat / comment
      elsif line.start_with?("id:")
        event[:id] = line[3..].strip
      elsif line.start_with?("data:")
        event[:data] = (event[:data] || "") + line[5..].strip
      end
    end
    nil
  end

  def read_headers(io)
    status_line = nil
    headers = {}
    loop do
      line = io.gets("\n")
      break if line.nil?

      line = line.chomp
      if status_line.nil?
        status_line = line
      elsif line.empty?
        break
      else
        key, value = line.split(":", 2)
        headers[key.strip.downcase] = value.to_s.strip
      end
    end
    [status_line, headers]
  end
end

# A stand-in socket for SSEWriter unit tests where we can force the writer
# thread's #write to block without touching a real socket.
class ControllableIO
  attr_reader :buffer
  attr_accessor :write_sleep

    def initialize
      @buffer = +""
      @write_sleep = 0.0
      @mutex = Monitor.new
    end

  def write(data)
    @mutex.synchronize { @buffer << data }
    sleep(@write_sleep) if @write_sleep.positive?
    data.bytesize
  end

  def flush; end
  def binmode; self; end

  private

  def mutex
    @mutex ||= Monitor.new
  end
end

RSpec.describe Samagotchi::Bridge do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }

  def make_engine
    Samagotchi::Engine.new(client: client, kernel: kernel)
  end

  def make_session
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd)
  end

  # Stub the kernel to emit a canned set of raw kernel events, then complete.
  def stub_kernel_emit(*raw_events)
    allow(kernel).to receive(:run) do |_messages, **kwargs|
      cb = kwargs[:on_stream_event]
      raw_events.each { |e| cb.call(e) }
      Samagotchi::LLM::ModelResult.new(
        text: "ok", conversation: [], exhausted: false, pending_tool_calls: false, tool_activity: []
      )
    end
  end

  def run_turn_sync(engine, session, prompt)
    engine.run_turn(session, prompt, on_event: ->(_e) {})
  end

  describe "BoundedQueue" do
    it "returns nil on pop timeout and blocks until an item is pushed" do
      queue = Samagotchi::Bridge::BoundedQueue.new(capacity: 4)
      expect(queue.pop(0.05)).to be_nil
      queue.push(:a)
      expect(queue.pop(0.2)).to eq(:a)
    end

    it "drops the oldest entry when full and records the overflow" do
      queue = Samagotchi::Bridge::BoundedQueue.new(capacity: 2)
      queue.push(:a)
      queue.push(:b)
      queue.push(:c) # overflows, drops :a
      expect(queue.pop(0)).to eq(:b)
      expect(queue.pop(0)).to eq(:c)
      expect(queue.pop(0)).to be_nil
      expect(queue.overflow_dropped?).to be(true)
    end

    it "never blocks the producer even under a slow consumer" do
      queue = Samagotchi::Bridge::BoundedQueue.new(capacity: 2)
      start = mono
      1_000.times { |i| queue.push(i) }
      expect(mono - start).to be < 1.0
    end
  end

  describe "RingBuffer" do
    it "keeps only the most recent events up to capacity" do
      ring = Samagotchi::Bridge::RingBuffer.new(capacity: 3)
      10.times { |i| ring.push(seq: i, data: { n: i }) }
      expect(ring.last_seq).to eq(9)
      expect(ring.events_in_range(after_seq: 0, to_seq: 9).map { |e| e[:seq] }).to eq([7, 8, 9])
    end

    it "returns an empty window when replaying from beyond the served window" do
      ring = Samagotchi::Bridge::RingBuffer.new(capacity: 3)
      3.times { |i| ring.push(seq: i, data: { n: i }) }
      expect(ring.has_any_after?(from_seq: 100)).to be(false)
      expect(ring.events_in_range(after_seq: 100, to_seq: 10)).to eq([])
    end
  end

  describe "SSEWriter" do
    it "drops events already served (seq <= reconnect cursor)" do
      engine = make_engine
      ring = Samagotchi::Bridge::RingBuffer.new(capacity: 64)
      writer = Samagotchi::Bridge::SSEWriter.new(
        engine:, ring:, session_id: "s1", last_event_id: "5"
      )
      # seq 3 is before the cursor → dropped; seq 7 after → enqueued.
      writer.call(type: :x, event_seq: 3)
      writer.call(type: :x, event_seq: 7)
      writer.instance_variable_get(:@queue).push(:sentinel)
      # The dropped event never enqueued: only the seq-7 event + sentinel remain.
      expect(writer.instance_variable_get(:@queue).size).to eq(2)
    end

    it "replays buffered events in (from_seq, snapshot] in order" do
      engine = make_engine
      allow(engine).to receive(:event_count).and_return(10)
      ring = Samagotchi::Bridge::RingBuffer.new(capacity: 64)
      10.times { |i| ring.push(seq: i + 1, data: { type: :k, event_seq: i + 1 }) }

      io = ControllableIO.new
      writer = Samagotchi::Bridge::SSEWriter.new(
        engine:, ring:, session_id: "s1", last_event_id: "4",
        heartbeat_interval: 0.05
      )
      writer_thread = Thread.new { writer.serve!(io) }
      wait_until { io.buffer.include?("id: 10\r\n") } # subscribe + replay complete

      seqs_in_order = %w[5 6 7 8 9 10]
      positions = seqs_in_order.map { |s| io.buffer.index("id: #{s}") }
      expect(positions).not_to include(nil)
      expect(positions).to eq(positions.sort)
      expect(io.buffer).not_to include("id: 4")
      expect(io.buffer).to include("text/event-stream")

      writer_thread.kill
    end

    # The ring holds seqs 5..10. Cursor 4 has seen everything before 5, so it
    # replays; cursor 3 missed seq 4, which is gone, so it resets.
    { "4" => false, "3" => true }.each do |cursor, resets|
      it "#{resets ? 'resets' : 'replays'} a cursor at #{cursor} when the ring's oldest seq is 5" do
        engine = make_engine
        allow(engine).to receive(:event_count).and_return(10)
        ring = Samagotchi::Bridge::RingBuffer.new(capacity: 6)
        10.times { |i| ring.push(seq: i + 1, data: { type: :k, event_seq: i + 1 }) }

        io = ControllableIO.new
        writer = Samagotchi::Bridge::SSEWriter.new(
          engine:, ring:, session_id: "s1", last_event_id: cursor,
          heartbeat_interval: 0.05
        )
        writer_thread = Thread.new { writer.serve!(io) }
        # The last replayed frame, or the reset (which carries the newest id).
        wait_until { io.buffer.include?("id: 10\r\n") }

        if resets
          expect(io.buffer).to include("event: reset")
          expect(io.buffer).not_to include("id: 5\r\n")
        else
          expect(io.buffer).not_to include("event: reset")
          expect(%w[5 6 7 8 9 10].map { |s| io.buffer.include?("id: #{s}\r\n") }).to all(be true)
        end

        writer_thread.kill
      end
    end

    describe "with a worker epoch" do
      # The ring holds seqs 1..10 of the worker whose epoch is "e2".
      def serve_from(cursor)
        engine = make_engine
        allow(engine).to receive(:event_count).and_return(10)
        ring = Samagotchi::Bridge::RingBuffer.new(capacity: 64)
        10.times { |i| ring.push(seq: i + 1, data: { type: :k, event_seq: i + 1 }) }
        io = ControllableIO.new
        writer = Samagotchi::Bridge::SSEWriter.new(
          engine:, ring:, session_id: "s1", last_event_id: cursor, epoch: "e2",
          heartbeat_interval: 0.05
        )
        writer_thread = Thread.new { writer.serve!(io) }
        wait_until { io.buffer.include?("id: 10-e2\r\n") } # the last replayed frame, or the reset's
        writer_thread.kill
        io.buffer
      end

      it "numbers its frames <seq>-<epoch>" do
        expect(serve_from("0").scan(/^id: (.*)\r$/).flatten).to eq((1..10).map { |s| "#{s}-e2" })
      end

      it "replays a cursor from its own epoch" do
        buffer = serve_from("4-e2")
        expect(buffer.scan(/^id: (.*)\r$/).flatten).to eq((5..10).map { |s| "#{s}-e2" })
        expect(buffer).not_to include("event: reset")
      end

      it "resets a cursor from another worker's epoch, although its seq is in the ring" do
        buffer = serve_from("4-e1")
        expect(buffer.scan(/^event: (.*)\r$/).flatten).to eq(["reset"])
        expect(buffer.scan(/^id: (.*)\r$/).flatten).to eq(["10-e2"])
        expect(buffer).to include('"event_id":"10-e2"')
      end

      it "replays a plain numeric cursor as before" do
        expect(serve_from("4").scan(/^id: (.*)\r$/).flatten).to eq((5..10).map { |s| "#{s}-e2" })
      end
    end

    it "does not block the enqueuer while the writer thread is stuck writing" do
      engine = make_engine
      allow(engine).to receive(:run_turn)
      ring = Samagotchi::Bridge::RingBuffer.new(capacity: 64)
      io = ControllableIO.new
      io.write_sleep = 0.02 # simulate a slow / hung client socket
      writer = Samagotchi::Bridge::SSEWriter.new(
        engine:, ring:, session_id: "s1",
        heartbeat_interval: 0.05
      )
      writer_thread = Thread.new { writer.serve!(io) }
      wait_until { io.buffer.include?("text/event-stream") } # subscribe + headers written

      start = mono
      500.times { |i| writer.call(type: :x, event_seq: 10_000 + i) }
      elapsed = mono - start

      # The enqueue path must stay non-blocking even though the writer thread
      # is blocked on the slow socket.
      expect(io.buffer).to include("text/event-stream")
      expect(elapsed).to be < 1.0

      io.write_sleep = 0
      writer_thread.kill
      writer_thread.join(0.5) rescue nil
    end
  end

  describe "cancel reasons" do
    let(:engine) { make_engine }
    let(:bridge) { described_class.new(engine: engine, state_dir: Dir.mktmpdir, session_id: "s1") }

    before do
      allow(engine).to receive(:turn_running?).and_return(true)
      allow(engine).to receive(:active_cancel_controller).and_return(double)
      allow(engine).to receive(:cancel_current_turn!).and_return(true)
    end

    def cancel_with(reason)
      bridge.send(:handle_cancel, "s1", JSON.generate(reason: reason))
    end

    it "passes a reason the clients send" do
      cancel_with("ctrl_c")
      cancel_with("user")
      expect(engine).to have_received(:cancel_current_turn!).with(:ctrl_c)
      expect(engine).to have_received(:cancel_current_turn!).with(:user)
    end

    it "turns any other reason into :manual instead of a new symbol" do
      _, status, body = cancel_with("made_up_#{SecureRandom.hex(4)}")
      expect(status).to eq(202)
      expect(body[:reason]).to eq("manual")
      expect(engine).to have_received(:cancel_current_turn!).with(:manual)
    end
  end

  describe "integration" do
    let(:state_dir) { Dir.mktmpdir }

    before do
      @bridge = nil
      @clients = []
      # The bridge serves real HTTP; other suites may enable WebMock, which
      # would block the POST/state/OPTIONS requests. Allow real connections
      # for these integration examples only.
      WebMock.allow_net_connect! if defined?(WebMock)
    end

    after do
      @bridge&.stop
      @clients.each(&:stop)
      WebMock.disable_net_connect! if defined?(WebMock)
    end

    def start_bridge(input_format: nil, on_input: nil, on_command: nil, on_exit_request: nil, exit_discards: nil)
      @engine = make_engine
      @session = make_session
      @bridge = described_class.new(
        engine: @engine, state_dir: state_dir, session_id: @session.id,
        heartbeat_interval: 0.2, input_format: input_format, on_input: on_input, on_command: on_command,
        on_exit_request: on_exit_request, exit_discards: exit_discards
      )
      @bridge.start
      sidecar = File.join(Samagotchi::Session.session_dir(@session.id, state_dir: state_dir), "bridge.json")
      @bridge_port = JSON.parse(File.read(sidecar))["port"]
    end

    it "advertises the input format its worker reads in the sidecar" do
      start_bridge
      sidecar = File.join(Samagotchi::Session.session_dir(@session.id, state_dir: state_dir), "bridge.json")
      expect(JSON.parse(File.read(sidecar))).not_to have_key("input_format")
      @bridge.stop

      @bridge = described_class.new(engine: @engine, state_dir: state_dir, session_id: @session.id, input_format: 2).start
      expect(JSON.parse(File.read(sidecar))).to include("input_format" => 2)
    end

    it "writes the client's ids into the queued input" do
      start_bridge(input_format: 2)
      _, resp = post_turn(JSON.generate(session_id: @session.id, prompt: "hi", client_id: "web:tab-1"))

      input_dir = File.join(Samagotchi::Session.session_dir(@session.id, state_dir: state_dir), "input")
      queued = Dir.glob(File.join(input_dir, "*.json"))
      expect(queued.map { |f| JSON.parse(File.read(f)) }).to eq([
        { "prompt" => "hi", "client_id" => "web:tab-1", "enqueued_id" => resp["enqueued_id"] }
      ])
    end

    it "keeps a turn's no_interrupt (--no-interrupt) in the queued input" do
      start_bridge(input_format: 2)
      post_turn(JSON.generate(session_id: @session.id, prompt: "long", client_id: "tui:1", no_interrupt: true))
      post_turn(JSON.generate(session_id: @session.id, prompt: "short", client_id: "tui:1", no_interrupt: "yes"))

      input_dir = File.join(Samagotchi::Session.session_dir(@session.id, state_dir: state_dir), "input")
      queued = Dir.glob(File.join(input_dir, "*.json")).sort.map { |f| JSON.parse(File.read(f)) }
      expect(queued.map { |q| [q["prompt"], q["no_interrupt"]] }).to eq([["long", true], ["short", nil]])
    end

    it "writes a discoverable port sidecar on start, with the chi version it runs" do
      start_bridge
      expect(@bridge_port).to be > 0
      sidecar = File.join(Samagotchi::Session.session_dir(@session.id, state_dir: state_dir), "bridge.json")
      expect(JSON.parse(File.read(sidecar))).to include("version" => Samagotchi::VERSION)
    end

    describe "#stop" do
      def sidecar
        File.join(Samagotchi::Session.session_dir(@session.id, state_dir: state_dir), "bridge.json")
      end

      it "removes its sidecar" do
        start_bridge
        @bridge.stop
        expect(File.exist?(sidecar)).to be(false)
      end

      it "keeps a sidecar that another worker's bridge rewrote" do
        start_bridge
        File.write(sidecar, JSON.generate("port" => @bridge_port + 1, "session_id" => @session.id))
        @bridge.stop
        expect(JSON.parse(File.read(sidecar))["port"]).to eq(@bridge_port + 1)
      end

      it "can be called twice" do
        start_bridge
        @bridge.stop
        expect { @bridge.stop }.not_to raise_error
      end

      # A post that enqueued but got no reply looks failed to the web, which
      # would queue the prompt again from the input file.
      it "lets a turn post it is answering finish before it closes" do
        start_bridge(input_format: 2)
        enqueued = Queue.new
        # The prompt is queued; the reply hasn't gone out yet.
        allow(@bridge).to receive(:write_json).and_wrap_original do |original, *args|
          enqueued << true
          sleep(0.3) # the reply still going out while stop runs (stop must wait for it)
          original.call(*args)
        end
        client = Samagotchi::BridgeClient.new(session_id: @session.id, port: @bridge_port)
        post = Thread.new { client.post_turn(prompt: "hi") }

        enqueued.pop
        @bridge.stop

        expect(post.value.status).to eq(202)
      end

      it "doesn't wait on an open stream" do
        start_bridge
        @clients << SSEClient.new(@bridge_port, @session.id).start
        wait_until { @bridge.open_streams == 1 }

        started = mono
        @bridge.stop
        # Not the 1 s request grace nor the stream: only the acceptor's
        # 0.5 s IO.select poll, which closing the socket doesn't cut short
        # on Linux (macOS wakes it at once).
        expect(mono - started).to be < 0.9
      end
    end

    describe "client tracking" do
      it "counts the open streams" do
        start_bridge
        expect(@bridge.open_streams).to eq(0)

        client = SSEClient.new(@bridge_port, @session.id).start
        @clients << client
        expect(wait_until { @bridge.open_streams == 1 }).to be(true)

        client.stop
        # The writer notices the hang-up on its next heartbeat (0.2s here).
        expect(wait_until { @bridge.open_streams.zero? }).to be(true)
      end

      it "counts the streams of everyone but a given client" do
        start_bridge
        own = SSEClient.new(@bridge_port, @session.id, client_id: "tui:1").start
        @clients << own
        expect(wait_until { @bridge.open_streams == 1 }).to be(true)
        expect(@bridge.open_streams_except("tui:1")).to eq(0)
        expect(@bridge.open_streams_except("tui:2")).to eq(1)
        expect(@bridge.open_streams_except(nil)).to eq(1)

        # A reconnect overlapping the old stream, and a web tab (no client_id).
        @clients << SSEClient.new(@bridge_port, @session.id, client_id: "tui:1").start
        web = SSEClient.new(@bridge_port, @session.id).start
        @clients << web
        expect(wait_until { @bridge.open_streams == 3 }).to be(true)
        expect(@bridge.open_streams_except("tui:1")).to eq(1)

        web.stop
        expect(wait_until { @bridge.open_streams == 2 }).to be(true)
        expect(@bridge.open_streams_except("tui:1")).to eq(0)

        own.stop
        expect(wait_until { @bridge.open_streams == 1 }).to be(true)
        expect(@bridge.open_streams_except("tui:1")).to eq(0)
        expect(@bridge.open_streams_except("tui:2")).to eq(1)
      end

      it "notes client activity on a request and when a stream closes" do
        start_bridge
        before = @bridge.last_client_activity_at
        get_state
        after_request = @bridge.last_client_activity_at
        expect(after_request).to be > before

        client = SSEClient.new(@bridge_port, @session.id).start
        wait_until { @bridge.open_streams == 1 }
        client.stop
        wait_until { @bridge.open_streams.zero? }
        expect(@bridge.last_client_activity_at).to be > after_request
      end

      it "ignores a bare connect that sends no request (a liveness probe)" do
        start_bridge
        before = @bridge.last_client_activity_at
        expect(Samagotchi::BridgeClient.sidecar_port(
          Samagotchi::Session.session_dir(@session.id, state_dir: state_dir)
        )).to eq(@bridge_port)
        sleep(0.1) # nothing to wait on: a request would have noted activity by now
        expect(@bridge.last_client_activity_at).to eq(before)
      end
    end

    it "streams every event type with a monotonic event_seq + id (via replay from a cold connect)" do
      start_bridge
      # Drive a turn first so the shared capture observer fills the ring.
      stub_kernel_emit({ type: :generation_started, iteration: 1 },
                       { type: :generation_completed, iteration: 1, content: "hi" })
      run_turn_sync(@engine, @session, "hi")

      # Connect with no cursor → replays the whole served window.
      client = SSEClient.new(@bridge_port, @session.id).start
      @clients = [client]
      events = client.wait_for(4, timeout: 3)

      types = events.map { |e| e[:data]&.fetch("type", nil) }
      expect(types.first).to eq("turn_started")
      expect(types).to include("generation_started", "generation_completed")
      expect(types.last).to eq("turn_completed")
      seqs = events.map { |e| e[:data]&.fetch("event_seq", nil) }.compact
      expect(seqs.first).not_to be_nil
      expect(seqs).to eq(seqs.sort)
    end

    it "delivers live events across a turn without a hanging client stalling it" do
      start_bridge
      client = SSEClient.new(@bridge_port, @session.id).start
      @clients = [client]
      wait_until { @bridge.open_streams == 1 } # the acceptor + per-connection subscribe happened

      stub_kernel_emit({ type: :generation_started, iteration: 1 })
      run_turn_sync(@engine, @session, "hi")

      events = client.wait_for(2, timeout: 3)
      expect(events.map { |e| e[:data]&.fetch("type", nil) }).to include("turn_started")
    end

    it "delivers identical events to multiple subscribers (many-to-one fan-out)" do
      start_bridge
      stub_kernel_emit({ type: :generation_started, iteration: 1 })
      run_turn_sync(@engine, @session, "hi")

      a = SSEClient.new(@bridge_port, @session.id).start.wait_for(3, timeout: 3)
      b = (@clients << SSEClient.new(@bridge_port, @session.id)).last.start.wait_for(3, timeout: 3)
      expect(a.map { |e| e[:data] }).to eq(b.map { |e| e[:data] })
    end

    it "resumes via ?from_seq= by replaying buffered events then continuing live" do
      start_bridge
      c1 = SSEClient.new(@bridge_port, @session.id).start
      stub_kernel_emit({ type: :generation_started, iteration: 1 })
      run_turn_sync(@engine, @session, "hi 1")
      # The turn's events reach c1 on the bridge's threads, maybe after
      # run_turn returned (live, or replayed if c1 subscribed late).
      completed = ->(events, after: 0) { events.any? { |e| e[:data]["type"] == "turn_completed" && e[:id].to_i > after } }
      expect(completed.call(c1.wait_until { |events| completed.call(events) })).to be(true)
      last_seen = c1.last[:id]
      c1.stop

      # Turn runs while c1 is gone → buffered in the ring.
      stub_kernel_emit({ type: :generation_started, iteration: 1 })
      run_turn_sync(@engine, @session, "hi 2")

      # Reconnect from last_seen: replay the buffered window then go live.
      c2 = SSEClient.new(@bridge_port, @session.id, last_event_id: last_seen).start
      @clients << c2
      events = c2.wait_until { |seen| completed.call(seen, after: last_seen.to_i) }
      expect(completed.call(events, after: last_seen.to_i)).to be(true)
      ordered = events.map { |e| e[:id].to_i }
      expect(ordered).not_to be_empty
      expect(ordered).to eq(ordered.uniq.sort)
      # The replayed/live ids are all reachable from the reconnect cursor.
      expect(ordered.first).to be >= last_seen.to_i
    end

    describe "joining with ?snapshot=1" do
      # A kernel that emits +events+, then holds the turn open until released.
      def hold_turn_after(*events, conversation: [])
        release = Queue.new
        allow(kernel).to receive(:run) do |messages, **kwargs|
          events.each { |e| kwargs[:on_stream_event].call(e) }
          yield if block_given?
          release.pop
          Samagotchi::LLM::ModelResult.new(
            text: "done", conversation: messages + conversation, exhausted: false,
            pending_tool_calls: false, tool_activity: []
          )
        end
        release
      end

      it "gets the whole in-progress turn after more events than the ring holds, then the rest live" do
        start_bridge
        chunks = Array.new(300) { |i| { type: :generation_chunk, iteration: 1, content: "c#{i} " } }
        release = hold_turn_after({ type: :generation_started, iteration: 1 }, *chunks,
                                  conversation: [{ role: "model", content: "done" }])
        turn = Thread.new { run_turn_sync(@engine, @session, "long one") }
        wait_until { @engine.event_count >= 302 }

        c = SSEClient.new(@bridge_port, @session.id, snapshot: true).start
        @clients << c
        first = c.wait_for(1).first
        release << true
        turn.join

        expect(first[:data]["type"]).to eq("snapshot")
        snap = first[:data]["snapshot"]
        expect(first[:id].to_i).to eq(snap["event_seq"])
        expect(snap["current_turn"]["prompt"]).to eq("long one")
        expect(snap["current_turn"]["parts"].map { |p| p["text"] }.join).to eq(chunks.map { |e| e[:content] }.join)
        expect(snap["messages"]).to eq([])

        rest = c.wait_for(2 + 3, timeout: 3).drop(1) # completion events arrive live
        ids = rest.map { |e| e[:id].to_i }
        expect(ids.first).to eq(first[:id].to_i + 1)
        expect(ids).to eq((ids.first..ids.last).to_a)
        expect(rest.map { |e| e[:data]["type"] }).to include("turn_completed")
      end

      it "takes the frame's session state with the event log held, as the snapshot" do
        start_bridge
        held = []
        allow(@engine).to receive(:session_state_snapshot).and_wrap_original do |original, *args|
          # Another thread can't take the event log while this one holds it.
          held << Thread.new { @engine.synchronize_events { true } }.join(0.2).nil?
          original.call(*args)
        end

        c = SSEClient.new(@bridge_port, @session.id, snapshot: true).start
        @clients << c
        first = c.wait_for(1).first

        expect(first[:data]["type"]).to eq("snapshot")
        expect(first[:data]["session_state_snapshot"]["event_seq"]).to eq(first[:data]["snapshot"]["event_seq"])
        expect(held).to eq([true])
      end

      it "serves the same snapshot over GET /session/:id/snapshot, with the session state at its seq" do
        start_bridge
        release = hold_turn_after({ type: :generation_chunk, iteration: 1, content: "half " },
                                  conversation: [{ role: "model", content: "done" }])
        turn = Thread.new { run_turn_sync(@engine, @session, "mid turn") }
        wait_until { @bridge.snapshot.dig(:current_turn, :parts)&.any? }

        client = Samagotchi::BridgeClient.new(session_id: @session.id, port: @bridge_port)
        body = client.get_json("snapshot")
        missing = Samagotchi::BridgeClient.new(session_id: "nope", port: @bridge_port).get_json("snapshot")
        release << true
        turn.join

        snap = body["snapshot"]
        expect(snap["current_turn"]["prompt"]).to eq("mid turn")
        expect(snap["current_turn"]["parts"].map { |p| p["text"] }).to eq(["half "])
        expect(snap["messages"]).to eq([])
        expect(snap["queued"]).to eq([])
        expect(snap).to have_key("recap")
        expect(snap).to have_key("saved_recap")
        expect(snap).to have_key("continue_offer")
        expect(snap).to have_key("pending_question")
        expect(body["session_state_snapshot"]).to include("status" => "running", "event_seq" => snap["event_seq"])
        expect(snap["event_id"]).to eq("#{snap["event_seq"]}-#{@bridge.epoch}")
        expect(body["session_state_snapshot"]["event_id"]).to eq(snap["event_id"])
        expect(missing).to be_nil
      end

      describe "GET /session/:id/tail" do
        def tail(session_id = @session.id)
          Samagotchi::BridgeClient.new(session_id: session_id, port: @bridge_port).get_json("tail")
        end

        it "carries the session state, the last answer and the cards at one event_seq, no message list" do
          start_bridge
          @engine.session = @session
          @session.messages = [
            { role: "user", content: "check", turn_id: "t1" },
            { role: "assistant", content: "", tool_calls: [{ id: "c1" }] },
            { role: "tool_response", content: "out" },
            { role: "assistant", content: "All **good**." }
          ]
          @engine.show_card(source: "spec", title: "Card", body: "body", id: "card-1")

          body = tail
          state = Samagotchi::BridgeClient.new(session_id: @session.id, port: @bridge_port).get_json("state")

          expect(body.keys).to contain_exactly("session_id", "session_state_snapshot", "answer", "cards", "event_seq", "event_id")
          expect(body["answer"]).to eq("role" => "assistant", "content" => "All **good**.")
          expect(body["cards"].map { |c| c["id"] }).to eq(["card-1"])
          expect(body["event_seq"]).to eq(state["session_state_snapshot"]["event_seq"])
          expect(body["session_state_snapshot"]).to include("event_seq" => body["event_seq"], "event_id" => body["event_id"])
          expect(body["event_id"]).to eq("#{body["event_seq"]}-#{@bridge.epoch}")
        end

        it "has a null answer on a fresh session, and 404s another session's id" do
          start_bridge
          @engine.session = @session

          expect(tail["answer"]).to be_nil
          expect(tail("nope")).to be_nil
        end

        it "?turn_id= answers that turn's answer; an unknown or empty id the newest" do
          start_bridge
          @engine.session = @session
          @session.messages = [
            { role: "user", content: "first", turn_id: "tA" },
            { role: "assistant", content: "answer A" },
            { role: "user", content: "late line", kind: Samagotchi::Steer::INPUT_KIND },
            { role: "user", content: "second", turn_id: "tB" },
            { role: "assistant", content: "answer B" }
          ]

          expect(tail.dig("answer", "content")).to eq("answer B")
          expect(Samagotchi::BridgeClient.new(session_id: @session.id, port: @bridge_port)
            .get_json("tail?turn_id=tA").dig("answer", "content")).to eq("answer A")
          expect(Samagotchi::BridgeClient.new(session_id: @session.id, port: @bridge_port)
            .get_json("tail?turn_id=tB").dig("answer", "content")).to eq("answer B")
          %w[nope =].each do |id|
            expect(Samagotchi::BridgeClient.new(session_id: @session.id, port: @bridge_port)
              .get_json("tail?turn_id=#{id}").dig("answer", "content")).to eq("answer B")
          end
          # The query reaches no other route: /state answers as ever.
          expect(Samagotchi::BridgeClient.new(session_id: @session.id, port: @bridge_port)
            .get_json("state?turn_id=tA")).to include("session_state_snapshot")
        end

        it "takes the event log once and never copies the conversation" do
          start_bridge
          @engine.session = @session
          @session.messages = [{ role: "user", content: "q" }, { role: "assistant", content: "a" }]
          held = []
          allow(@engine).to receive(:session_state_snapshot).and_wrap_original do |original, *args|
            held << Thread.new { @engine.synchronize_events { true } }.join(0.2).nil?
            original.call(*args)
          end
          expect(@engine).not_to receive(:messages_checkpoint)

          expect(tail["answer"]).to eq("role" => "assistant", "content" => "a")
          expect(held).to eq([true])
        end
      end

      it "carries the guardrail load warning once the first turn announced it" do
        start_bridge
        @engine.guardrail_failures.add("hook g.rb (config)", "LoadError: x", required: false)
        expect(@bridge.snapshot[:guardrail_warning]).to be_nil

        stub_kernel_emit
        run_turn_sync(@engine, @session, "hi")

        expect(@bridge.snapshot[:guardrail_warning]).to eq("hook g.rb (config) failed to load (LoadError: x)")
      end

      it "carries the guardrail load warning announced before any turn (a worker's, once its Bridge is up)" do
        start_bridge
        @engine.guardrail_failures.add("hook g.rb (config)", "LoadError: x", required: false)
        @engine.announce_load_events!

        expect(@bridge.snapshot[:guardrail_warning]).to eq("hook g.rb (config) failed to load (LoadError: x)")
      end

      it "carries the plugins' init tasks while they run" do
        start_bridge
        gate = Queue.new
        @engine.add_init_task(bundle: "b", label: "Warming up", plugin_label: "x", provides_tools: false, quiet: false,
                              timeout: 5) { gate.pop }
        expect(@bridge.snapshot[:init_tasks]).to eq([])
        @engine.start_init_tasks!
        wait_until { @bridge.snapshot[:init_tasks].any? }
        expect(@bridge.snapshot[:init_tasks]).to eq([{ bundle: "b", id: "b-1", label: "Warming up" }])
        gate << :go
        wait_until { @bridge.snapshot[:init_tasks].empty? }
      end

      it "is followed by BridgeClient#follow: snapshot first, then gap-free live events" do
        start_bridge
        release = hold_turn_after({ type: :generation_chunk, iteration: 1, content: "half " },
                                  conversation: [{ role: "model", content: "done" }])
        turn = Thread.new { run_turn_sync(@engine, @session, "mid turn") }
        wait_until { @bridge.snapshot.dig(:current_turn, :parts)&.any? }

        events = Queue.new
        stream = Samagotchi::BridgeClient.new(session_id: @session.id, port: @bridge_port).follow { |e| events << e }
        snap = events.pop(timeout: 3)
        release << true
        turn.join
        live = []
        live << events.pop(timeout: 3) until live.last&.dig("type") == "turn_completed" || live.include?(nil)
        stream.close

        expect(snap["type"]).to eq("snapshot")
        expect(snap.dig("snapshot", "current_turn", "prompt")).to eq("mid turn")
        seqs = live.map { |e| e["event_seq"] }
        expect(seqs.first).to eq(snap.dig("snapshot", "event_seq") + 1)
        expect(seqs).to eq((seqs.first..seqs.last).to_a)
        expect(stream.last_event_id).to eq("#{seqs.last}-#{@bridge.epoch}")
        expect(stream).not_to be_alive
      end

      it "shows a question that is waiting for an answer" do
        start_bridge
        release = hold_turn_after do
          @engine.request_question(question: "Which?", options: %w[A B])
        end
        turn = Thread.new { run_turn_sync(@engine, @session, "ask me") }
        # Not @engine.pending_question: it is set before :question_requested
        # is emitted, and the snapshot follows the event log.
        wait_until { @bridge.snapshot.dig(:current_turn, :pending_question) }

        c = SSEClient.new(@bridge_port, @session.id, snapshot: true).start
        @clients << c
        snap = c.wait_for(1).first[:data]["snapshot"]
        @engine.answer_question(id: @engine.pending_question[:id], selected: ["A"])
        release << true
        turn.join

        expect(snap["current_turn"]["pending_question"]).to include("question" => "Which?", "options" => %w[A B])
      end

      it "never shows a turn both in messages and as the current turn" do
        start_bridge
        turns = 30
        allow(kernel).to receive(:run) do |messages, **kwargs|
          prompt = messages.last[:content]
          kwargs[:on_stream_event].call(type: :generation_chunk, iteration: 1, content: "x")
          Samagotchi::LLM::ModelResult.new(
            text: "r-#{prompt}", conversation: messages + [{ role: "model", content: "r-#{prompt}" }],
            exhausted: false, pending_tool_calls: false, tool_activity: []
          )
        end
        snapshots = []
        done = false
        # Thread.pass: Ruby mutexes are not fair, and a tight loop would starve the turn.
        reader = Thread.new { (snapshots << @bridge.snapshot; Thread.pass) until done }
        turns.times { |i| run_turn_sync(@engine, @session, "p#{i}") }
        done = true
        reader.join

        expect(snapshots.size).to be > turns
        snapshots.each do |snap|
          replies = snap[:messages].select { |m| m[:role] == "model" }.map { |m| m[:content] }
          if (turn = snap[:current_turn])
            expect(replies).not_to include("r-#{turn[:prompt]}")
          end
          expect(replies.size).to eq(snap[:messages].count { |m| m[:role] == "user" }) unless snap[:current_turn]
        end
        expect(snapshots.map { |s| s[:event_seq] }).to eq(snapshots.map { |s| s[:event_seq] }.sort)
      end
    end

    it "numbers a reset frame with its snapshot's own event_seq" do
      start_bridge
      stub_kernel_emit({ type: :generation_started, iteration: 1 })
      run_turn_sync(@engine, @session, "hi")

      c = SSEClient.new(@bridge_port, @session.id, last_event_id: "100000").start
      @clients << c
      reset = c.wait_for(1).first
      expect(reset[:data]["type"]).to eq("reset")
      expect(reset[:id].to_i).to eq(reset[:data]["snapshot"]["event_seq"])
      expect(reset[:data]["session_state_snapshot"]["event_seq"]).to eq(reset[:id].to_i)
      expect(reset[:data]["snapshot"]).to include("messages" => [], "current_turn" => nil)
      expect(reset[:id]).to eq("#{reset[:id].to_i}-#{@bridge.epoch}")
      expect(reset[:data]["snapshot"]["event_id"]).to eq(reset[:id])
      expect(reset[:data]["session_state_snapshot"]["event_id"]).to eq(reset[:id])

      # The cursor was ahead of this worker (it restarted): later events must
      # still arrive, not be dropped as already seen.
      run_turn_sync(@engine, @session, "after the reset")
      after = c.wait_for(3).drop(1)
      expect(after.first[:data]).to include("type" => "turn_started", "prompt" => "after the reset")
      expect(after.first[:id].to_i).to eq(reset[:id].to_i + 1)
    end

    # The next worker's event_seq starts over. A cursor from the worker before
    # it must not be taken as a position in the new one (it skipped events).
    it "resets a cursor from an earlier worker instead of replaying from its seq" do
      start_bridge
      stub_kernel_emit({ type: :generation_started, iteration: 1 })
      run_turn_sync(@engine, @session, "on the first worker")
      first = SSEClient.new(@bridge_port, @session.id).start
      @clients << first
      old_cursor = first.wait_for(3).last[:id]
      old_epoch = @bridge.epoch
      @bridge.stop

      # The next worker: a new Engine and Bridge, with more events than the
      # old cursor's seq.
      start_bridge
      stub_kernel_emit(*Array.new(5) { { type: :generation_chunk, iteration: 1, content: "x" } })
      run_turn_sync(@engine, @session, "on the next worker")
      expect(@engine.event_count).to be > old_cursor.to_i
      expect(@bridge.epoch).not_to eq(old_epoch)

      c = SSEClient.new(@bridge_port, @session.id, last_event_id: old_cursor).start
      @clients << c
      reset = c.wait_for(1).first
      expect(reset[:data]["type"]).to eq("reset")
      expect(reset[:id]).to eq("#{@engine.event_count}-#{@bridge.epoch}")
    end

    it "emits a reset marker (not a stall) when reconnecting past the served window" do
      start_bridge
      stub_kernel_emit({ type: :generation_started, iteration: 1 })
      run_turn_sync(@engine, @session, "hi")

      c = SSEClient.new(@bridge_port, @session.id, last_event_id: "100000").start
      @clients << c
      events = c.wait_for(1, timeout: 3)
      reset = events.find { |e| e[:data]&.fetch("type") == "reset" }
      expect(reset).not_to be_nil
      expect(reset[:data]["session_state_snapshot"]).to have_key("event_seq")
    end

    it "holds the stream open without a reset marker when the client is fully caught up" do
      start_bridge
      stub_kernel_emit({ type: :generation_started, iteration: 1 },
                       { type: :generation_completed, iteration: 1, content: "hi" })
      run_turn_sync(@engine, @session, "hi")

      _, state = get_state
      current_seq = state.dig("session_state_snapshot", "event_seq").to_i
      expect(current_seq).to be > 0

      c = SSEClient.new(@bridge_port, @session.id, last_event_id: current_seq.to_s).start
      @clients << c
      wait_until { @bridge.open_streams == 1 }
      sleep(0.1) # nothing to wait on: a reset would follow the subscribe at once
      events = c.events
      reset = events.find { |e| e[:data]&.fetch("type") == "reset" }
      expect(reset).to be_nil
      # The all-events-wait_for consumer would time out, but the connection
      # stays serviceable: status is 200 and no reset was sent.
      expect(c.status_code).to eq(200)
    end

    it "returns a 2xx ACK (enqueued_id + accepted) for a valid POST" do
      start_bridge
      body = JSON.generate(session_id: @session.id, prompt: "hello there")
      status, resp = post_turn(body)
      expect(status).to be_between(200, 299)
      expect(resp["status"]).to eq("accepted")
      expect(resp).to have_key("enqueued_id")
    end

    describe "a turn's deadline" do
      def input_dir
        File.join(Samagotchi::Session.session_dir(@session.id, state_dir: state_dir), "input")
      end

      # A request that waited in the socket while the worker was frozen: its
      # client has timed out and said it was not sent.
      it "drops a turn whose deadline has passed: nothing queued, announced or woken, and a warning logged" do
        wakes = []
        start_bridge(on_input: -> { wakes << true })
        seen = []
        @engine.subscribe(observer: ->(e) { seen << e })
        allow(Samagotchi::Log).to receive(:warn).and_call_original

        status, resp = post_turn(JSON.generate(session_id: @session.id, prompt: "stale", client_id: "cli:send",
                                               deadline: Time.now.to_f - 5))

        expect(status).to eq(408)
        expect(resp).to include("error" => "deadline_passed")
        expect(Dir.exist?(input_dir) ? Dir.children(input_dir) : []).to be_empty
        expect(seen).to be_empty
        expect(wakes).to be_empty
        expect(Samagotchi::Log).to have_received(:warn)
          .with(:bridge, "turn_expired", hash_including(sid: @session.id, client_id: "cli:send", late: be > 4))
      end

      it "accepts a turn before its deadline" do
        start_bridge

        status, = post_turn(JSON.generate(session_id: @session.id, prompt: "fresh", deadline: Time.now.to_f + 25))

        expect(status).to eq(202)
        expect(Dir.children(input_dir).size).to eq(1)
      end

      it "accepts a turn with no deadline, as an older client sends it" do
        start_bridge

        status, = post_turn(JSON.generate(session_id: @session.id, prompt: "old client"))

        expect(status).to eq(202)
        expect(Dir.children(input_dir).size).to eq(1)
      end

      # The real client against a worker that reads the request only after
      # the client gave up (its event log held past the read timeout, as a
      # frozen worker would): the client reports a timeout, the turn never runs.
      it "never runs a turn its BridgeClient timed out on" do
        start_bridge(input_format: 2)
        seen = []
        @engine.subscribe(observer: ->(e) { seen << e })
        dropped = Queue.new
        allow(Samagotchi::Log).to receive(:warn).and_wrap_original do |original, *args, **kw|
          dropped << args[1] if args[1] == "turn_expired"
          original.call(*args, **kw)
        end
        held = Queue.new
        release = Queue.new
        # The event log held until the client gave up (past its read timeout).
        holder = Thread.new { @engine.synchronize_events { held << true; release.pop } }
        held.pop
        client = Samagotchi::BridgeClient.new(session_id: @session.id, port: @bridge_port, read_timeout: 0.5)

        expect { client.post_turn(prompt: "late", client_id: "cli:send") }.to raise_error(Errno::ETIMEDOUT)
        release << true
        holder.join

        expect(dropped.pop(timeout: 2)).to eq("turn_expired")
        expect(Dir.exist?(input_dir) ? Dir.children(input_dir) : []).to be_empty
        expect(seen).to be_empty
      ensure
        release&.push(true)
        holder&.join
      end

      it "answers 400 for a deadline that is not a number" do
        start_bridge

        status, resp = post_turn(JSON.generate(session_id: @session.id, prompt: "hi", deadline: "soon"))

        expect(status).to eq(400)
        expect(resp["error"]).to eq("bad_deadline")
      end
    end

    it "announces :turn_enqueued with the client's id and the ACK's enqueued_id" do
      start_bridge
      seen = []
      @engine.subscribe(observer: ->(e) { seen << e })

      status, resp = post_turn(JSON.generate(session_id: @session.id, prompt: "hello there", client_id: "web:tab-1"))

      expect(status).to eq(202)
      expect(seen.map { |e| e.except(:event_seq) }).to eq([
        { type: :turn_enqueued, enqueued_id: resp["enqueued_id"], client_id: "web:tab-1", prompt: "hello there" }
      ])
      input_dir = File.join(Samagotchi::Session.session_dir(@session.id, state_dir: state_dir), "input")
      expect(Dir.children(input_dir).size).to eq(1)
    end

    it "refuses a turn for another session, by path or body, and writes nothing" do
      start_bridge
      other = make_session

      status, resp = post_turn(JSON.generate(session_id: other.id, prompt: "for someone else"))
      expect([status, resp["error"]]).to eq([404, "unknown_session"])

      uri = URI("http://127.0.0.1:#{@bridge_port}/session/#{other.id}/turn")
      res = Net::HTTP.post(uri, JSON.generate(session_id: other.id, prompt: "for someone else"),
                           "Content-Type" => "application/json")
      expect([res.code.to_i, JSON.parse(res.body)["error"]]).to eq([404, "unknown_session"])

      expect(Dir.glob(File.join(state_dir, "*", "input", "*"))).to be_empty
    end

    it "announces nothing for a turn it fails to write" do
      start_bridge
      seen = []
      @engine.subscribe(observer: ->(e) { seen << e })

      allow(Samagotchi::SessionInbox).to receive(:write_input).and_return(false)
      status, = post_turn(JSON.generate(session_id: @session.id, prompt: "lost"))
      expect(status).to eq(500)

      expect(seen).to be_empty
    end

    it "wakes its worker after it queues a turn for its own session, and only then" do
      wakes = []
      start_bridge(on_input: -> { wakes << Dir.glob(File.join(state_dir, "*", "input", "*")).size })

      post_turn(JSON.generate(session_id: @session.id, prompt: "mine"))
      # Woken after the write: the worker then finds the file.
      expect(wakes).to eq([1])

      allow(Samagotchi::SessionInbox).to receive(:write_input).and_return(false)
      status, = post_turn(JSON.generate(session_id: @session.id, prompt: "lost"))

      expect(status).to eq(500)
      expect(wakes).to eq([1])
    end

    it "returns 400 for a malformed POST and creates no turn" do
      start_bridge
      status, = post_turn("")
      expect(status).to eq(400)

      status2, = post_turn(JSON.generate(prompt: "missing session id"))
      expect(status2).to eq(400)
    end

    it "returns the snapshot via GET /session/:id/state" do
      start_bridge
      stub_kernel_emit({ type: :generation_started, iteration: 1 })
      run_turn_sync(@engine, @session, "hi")
      status, resp = get_state

      expect(status).to eq(200)
      expect(resp["session_state_snapshot"]).to include("status", "message_count", "event_seq")
      state = resp["session_state_snapshot"]
      expect(state["event_id"]).to eq("#{state["event_seq"]}-#{@bridge.epoch}")
    end

    it "answers /stats with the Engine's stats snapshot" do
      start_bridge
      allow(@engine).to receive(:stats_snapshot).and_return({ turns: 0, context_window_tokens: 4096 })

      res = Net::HTTP.get_response(URI("http://127.0.0.1:#{@bridge_port}/session/#{@session.id}/stats"))

      expect([res.code, JSON.parse(res.body)["metrics"]]).to eq(["200", { "turns" => 0, "context_window_tokens" => 4096 }])
    end

    it "logs each answered request at debug level (method, path, status, time), never its body" do
      log = File.join(Dir.mktmpdir, "chi.log")
      Samagotchi::Log.configure(path: log, level: :debug)
      start_bridge
      allow(@engine).to receive(:stats_snapshot).and_return({ turns: 0 })

      Net::HTTP.get_response(URI("http://127.0.0.1:#{@bridge_port}/session/#{@session.id}/stats"))

      record = wait_until(timeout: 2) do
        File.exist?(log) && File.open(log) { |io| Samagotchi::LogLine.each_record(io).find { |r| r.tag == "bridge" && r.event == "request" } }
      end
      expect(record.fields.except("ms")).to eq("method" => "GET", "path" => "/session/#{@session.id}/stats", "status" => "200")
    end

    it "logs nothing when stopped (the closed server ends the accept loop)" do
      log = File.join(Dir.mktmpdir, "chi.log")
      Samagotchi::Log.configure(path: log)
      start_bridge
      @bridge.stop
      sleep 0.1 # nothing to wait on: the accept loop would have logged by now

      expect(File.exist?(log) ? File.read(log) : "").not_to include("accept_loop_failed")
    end

    it "answers a request that fails in its handler with 500 and logs it, with the backtrace" do
      log = File.join(Dir.mktmpdir, "chi.log")
      Samagotchi::Log.configure(path: log)
      start_bridge
      allow(@bridge).to receive(:handle_stats).and_raise(RuntimeError, "boom")

      response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@bridge_port}/session/#{@session.id}/stats"))
      expect([response.code, JSON.parse(response.body)]).to eq(["500", { "error" => "bridge_error", "detail" => "boom" }])

      wait_until(timeout: 2) { File.exist?(log) }
      record = File.open(log) { |io| Samagotchi::LogLine.each_record(io).find { |r| r.event == "handler_failed" } }
      expect(record.to_h).to include(level: "ERROR", tag: "bridge")
      expect(record.fields).to include("error" => "RuntimeError", "msg" => "boom")
      expect(record.payload).to match(/in [`'](Samagotchi::Bridge#)?dispatch'/) # 3.3: `dispatch', 3.4+ adds the class
    end

    it "rejects an unknown session on the read surface with 404" do
      start_bridge
      _status, resp = get_state_for("does-not-exist")
      expect(resp["error"]).to eq("unknown_session")
    end

    describe "requests from a browser" do
      # Only chi's Ruby clients talk to the Bridge: they send no Origin and
      # no Sec-Fetch-Site. A page in the browser (another website, or a
      # DNS-rebound one) always sends one of them.
      def raw(method, path, headers = {}, body = nil)
        uri = URI("http://127.0.0.1:#{@bridge_port}#{path}")
        req = Net::HTTP.const_get(method.capitalize).new(uri)
        headers.each { |k, v| req[k] = v }
        req.body = body if body
        res = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 2) { |h| h.request(req) }
        [res.code.to_i, res.to_hash, res.body]
      end

      it "refuses a text/plain turn POST carrying an Origin, before the engine sees it" do
        wakes = []
        start_bridge(on_input: -> { wakes << true })
        status, _, body = raw("post", "/session/#{@session.id}/turn",
                              { "Content-Type" => "text/plain", "Origin" => "https://evil.example" }, JSON.generate(session_id: @session.id, prompt: "hi"))
        expect(status).to eq(403)
        expect(JSON.parse(body)["error"]).to eq("cross_origin")
        expect(wakes).to be_empty
        expect(Dir.glob(File.join(state_dir, "*", "input", "*"))).to be_empty
      end

      it "refuses any Origin, its own loopback one included" do
        start_bridge
        expect(raw("post", "/session/#{@session.id}/cancel", { "Origin" => "http://127.0.0.1:#{@bridge_port}" }, "{}").first).to eq(403)
        expect(raw("get", "/session/#{@session.id}/state", { "Origin" => "null" }).first).to eq(403)
      end

      it "refuses a read or a stream with a browser's Sec-Fetch-Site, and a foreign Host (DNS rebinding)" do
        start_bridge
        expect(raw("get", "/session/#{@session.id}/state", { "Sec-Fetch-Site" => "cross-site" }).first).to eq(403)
        expect(raw("get", "/session/#{@session.id}/stream", { "Sec-Fetch-Site" => "same-origin" }).first).to eq(403)
        expect(raw("get", "/session/#{@session.id}/state", { "Host" => "evil.example:#{@bridge_port}" }).first).to eq(403)
      end

      it "answers chi's own clients (no Origin, no Sec-Fetch-Site), without any CORS header" do
        start_bridge
        status, headers, = raw("get", "/session/#{@session.id}/state")
        expect(status).to eq(200)
        expect(headers.keys.grep(/access-control/i)).to be_empty
        expect(raw("get", "/session/#{@session.id}/state", { "Host" => "localhost:#{@bridge_port}" }).first).to eq(200)
      end

      it "no longer answers a CORS preflight" do
        start_bridge
        status, headers, = options_request
        expect(status).to eq(404)
        expect(headers.keys.grep(/access-control/i)).to be_empty
      end

      it "opens its event stream without any CORS header" do
        start_bridge
        sock = TCPSocket.new("127.0.0.1", @bridge_port)
        sock.write("GET /session/#{@session.id}/stream HTTP/1.1\r\nHost: 127.0.0.1:#{@bridge_port}\r\n\r\n")
        head = +""
        head << sock.readpartial(4096) until head.include?("\r\n\r\n")
        sock.close
        expect(head).to start_with("HTTP/1.1 200")
        expect(head).not_to match(/access-control/i)
      end
    end

    it "answers 409 Conflict when the question is no longer pending (another client won)" do
      start_bridge
      status, resp, reason = post_answer(JSON.generate(id: "q-gone", selected: ["Cats"]))
      expect(status).to eq(409)
      expect(reason).to eq("Conflict")
      expect(resp["error"]).to eq("question_not_pending")
    end

    # The worker's own check of guardrails.parent_approvals for an answer
    # marked as chi answer's: a direct POST with the marker is held to it too.
    it "refuses (403) a parent's allow beyond the worker's guardrails.parent_approvals; the web's goes" do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("guardrails.parent_approvals").and_return("once")
      start_bridge
      result = {}
      fields = { question: "execute: echo hi", options: ["Allow once", "Allow this call for the session", "Deny"],
                 multi_select: false, allow_freeform: true, kind: "approval",
                 approval: { tool: "execute", scopes: %w[once session] } }
      thread = Thread.new { result[:answer] = @engine.open_question(fields) }
      wait_until { @engine.pending_question }
      qid = @engine.pending_question[:id]

      status, resp, reason = post_answer(JSON.generate(id: qid, selected: ["Allow this call for the session"],
                                                       client_id: "cli:answer"))
      expect([status, reason, resp["error"]]).to eq([403, "Forbidden", "parent_approval_refused"])
      expect(resp["detail"]).to start_with("only Allow once (guardrails.parent_approvals: once) can be given here")
      expect(resp["detail"]).to end_with("deny it (--option Deny --text WHY), and tell your user")
      expect(@engine.pending_question).to include(id: qid, status: "pending")

      status, = post_answer(JSON.generate(id: qid, selected: ["Allow this call for the session"]))
      expect(status).to eq(200)
      thread.join(2)
      expect(result[:answer]).to include(selected_indices: [1])
    end

    it "reads only id, selected and freeform (no question_id, selection or nested answer alias)" do
      start_bridge
      allow(@engine).to receive(:answer_question)
      ['{"question_id":"q1","selection":["A"]}', '{"answer":{"id":"q1","selected":["A"]}}'].each do |payload|
        status, resp, = post_answer(payload)
        expect([status, resp["error"]]).to eq([400, "missing_fields"]), payload
      end
      expect(@engine).not_to have_received(:answer_question)
    end

    describe "an answer's deadline" do
      # An answer that waited in the socket while the worker was frozen: its
      # client has said it was not sent, and the question stays open.
      it "drops an answer whose deadline has passed and logs a warning" do
        start_bridge
        allow(@engine).to receive(:answer_question)
        allow(Samagotchi::Log).to receive(:warn).and_call_original

        status, resp, = post_answer(JSON.generate(id: "q1", selected: ["A"], deadline: Time.now.to_f - 5))

        expect(status).to eq(408)
        expect(resp).to include("error" => "deadline_passed")
        expect(@engine).not_to have_received(:answer_question)
        expect(Samagotchi::Log).to have_received(:warn)
          .with(:bridge, "answer_expired", hash_including(sid: @session.id, late: be > 4))
      end

      it "takes an answer before its deadline, or with none" do
        start_bridge
        allow(@engine).to receive(:answer_question).and_return({ id: "q1" })

        expect(post_answer(JSON.generate(id: "q1", selected: ["A"], deadline: Time.now.to_f + 25)).first).to eq(200)
        expect(post_answer(JSON.generate(id: "q1", selected: ["A"])).first).to eq(200)
        expect(@engine).to have_received(:answer_question).twice
      end

      it "answers 400 for a deadline that is not a number" do
        start_bridge

        status, resp, = post_answer(JSON.generate(id: "q1", selected: ["A"], deadline: "soon"))

        expect(status).to eq(400)
        expect(resp["error"]).to eq("bad_deadline")
      end

      it "drops a dismissal whose deadline has passed: the question stays open" do
        start_bridge
        allow(@engine).to receive(:cancel_question)
        allow(Samagotchi::Log).to receive(:warn).and_call_original
        res = Net::HTTP.post(URI("http://127.0.0.1:#{@bridge_port}/session/#{@session.id}/question/dismiss"),
                             JSON.generate(id: "q1", deadline: Time.now.to_f - 5), "Content-Type" => "application/json")

        expect(res.code).to eq("408")
        expect(JSON.parse(res.body)).to include("error" => "deadline_passed")
        expect(@engine).not_to have_received(:cancel_question)
        expect(Samagotchi::Log).to have_received(:warn).with(:bridge, "dismiss_expired", hash_including(late: be > 4))
      end
    end

    describe "POST /session/:id/command" do
      def post_command(body)
        res = Net::HTTP.post(URI("http://127.0.0.1:#{@bridge_port}/session/#{@session.id}/command"),
                             body, "Content-Type" => "application/json")
        [res.code.to_i, JSON.parse(res.body)]
      end

      it "queues a command for the worker and announces it, answering at once" do
        queued = []
        start_bridge(on_command: ->(command) { queued << command })
        seen = []
        @engine.subscribe(observer: ->(e) { seen << e })

        status, body = post_command(JSON.generate(line: " /model x ", client_id: "tui:1"))

        expect(status).to eq(202)
        expect(queued).to eq([{ command_id: body["command_id"], client_id: "tui:1", line: "/model x" }])
        expect(seen).to eq([{ type: :command_queued, command_id: body["command_id"], client_id: "tui:1", line: "/model x",
                              event_seq: 1 }])
      end

      it "refuses what isn't a session command, bad JSON and other sessions" do
        start_bridge(on_command: ->(_) { raise "must not be called" })

        expect(post_command(JSON.generate(line: "hello")).first).to eq(400)
        expect(post_command(JSON.generate(line: "/foo")).last["detail"]).to eq("not a session command: /foo (known: !<cmd>, !rollback, /continue, " \
                                                 "/guardrails, /help, /model, /models; /help lists them)")
        expect(post_command(JSON.generate(line: "/recap")).first).to eq(400)
        expect(post_command("{nope").first).to eq(400)
        res = Net::HTTP.post(URI("http://127.0.0.1:#{@bridge_port}/session/other/command"),
                             JSON.generate(line: "/model"), "Content-Type" => "application/json")
        expect(res.code).to eq("404")
      end

      # chi send -m "/model x", chi -p "/model x", a web page whose command
      # list lags: a session command sent as a prompt runs as the command.
      it "runs a session command sent as a turn as the command, not as a prompt" do
        queued = []
        start_bridge(on_command: ->(command) { queued << command })
        @engine.command_registry.register("/hello", "greet", source: "sample-plugin") { |_args| "hi" }
        seen = []
        @engine.subscribe(observer: ->(e) { seen << e })

        status, body = post_turn(JSON.generate(session_id: @session.id, prompt: " /model x ", client_id: "cli:send"))
        _, plugin = post_turn(JSON.generate(session_id: @session.id, prompt: "/hello there", client_id: "cli:send"))

        expect(status).to eq(202)
        expect(body).to include("status" => "accepted", "command_id" => be_a(String))
        expect(body).not_to have_key("enqueued_id")
        expect(queued.map { |c| c.slice(:command_id, :client_id, :line) })
          .to eq([{ command_id: body["command_id"], client_id: "cli:send", line: "/model x" },
                  { command_id: plugin["command_id"], client_id: "cli:send", line: "/hello there" }])
        expect(seen.map { |e| e[:type] }).to eq(%i[command_queued command_queued])
        input_dir = File.join(Samagotchi::Session.session_dir(@session.id, state_dir: state_dir), "input")
        expect(Dir.exist?(input_dir) ? Dir.children(input_dir) : []).to be_empty
      end

      # As the TUIs send them: an unknown /word goes to the model.
      it "keeps a turn that only looks like a command a prompt: an unknown /word, a path" do
        start_bridge(on_command: ->(_) { raise "must not be called" })

        ["/usr/bin is slow", "/foo bar", "/modelx"].each do |prompt|
          status, body = post_turn(JSON.generate(session_id: @session.id, prompt: prompt))
          expect([status, body.keys]).to eq([202, %w[status enqueued_id session_id]])
        end
      end

      it "takes the Engine's plugin commands too (a card's action)" do
        queued = []
        start_bridge(on_command: ->(command) { queued << command })
        @engine.command_registry.register("/hello", "greet", source: "sample-plugin") { |_args| "hi" }

        expect(post_command(JSON.generate(line: "/hello again")).first).to eq(202)
        expect(queued.map { |c| c[:line] }).to eq(["/hello again"])
      end

      it "names the Engine's commands in its snapshot, plugins' too" do
        start_bridge
        @engine.command_registry.register("/hello", "greet", anytime: true, source: "sample-plugin") { |_args| "hi" }

        commands = @bridge.snapshot[:commands]
        expect(commands.map { |c| c[:name] }).to include("/model", "/stats", "/hello")
        expect(commands.find { |c| c[:name] == "/hello" })
          .to eq(name: "/hello", description: "greet", anytime: true, local: false, uis: nil, source: "sample-plugin")
      end

      it "answers 501 when nothing runs commands (a Bridge without a worker loop)" do
        start_bridge

        expect(post_command(JSON.generate(line: "/model"))).to eq([501, { "error" => "commands_unavailable" }])
      end

      # A command that waited in the socket while the worker was frozen: its
      # client has said it didn't run (a shell line must not run late).
      it "drops a command whose deadline has passed: not queued or announced, and a warning logged" do
        start_bridge(on_command: ->(_) { raise "must not be called" })
        seen = []
        @engine.subscribe(observer: ->(e) { seen << e })
        allow(Samagotchi::Log).to receive(:warn).and_call_original
        allow(@engine).to receive(:synchronize_events).and_call_original

        status, resp = post_command(JSON.generate(line: "!echo STALE", client_id: "web:1", deadline: Time.now.to_f - 5))

        expect(status).to eq(408)
        expect(resp).to include("error" => "deadline_passed")
        expect(seen).to be_empty
        expect(@engine).to have_received(:synchronize_events)
        expect(Samagotchi::Log).to have_received(:warn)
          .with(:bridge, "command_expired", hash_including(sid: @session.id, client_id: "web:1", late: be > 4))
      end

      # The real client against a worker that reads the request only after
      # the client gave up (its event log held past the read timeout).
      it "never runs a command its BridgeClient timed out on" do
        queued = []
        start_bridge(on_command: ->(command) { queued << command })
        dropped = Queue.new
        allow(Samagotchi::Log).to receive(:warn).and_wrap_original do |original, *args, **kw|
          dropped << args[1] if args[1] == "command_expired"
          original.call(*args, **kw)
        end
        held = Queue.new
        release = Queue.new
        # The event log held until the client gave up (past its read timeout).
        holder = Thread.new { @engine.synchronize_events { held << true; release.pop } }
        held.pop
        client = Samagotchi::BridgeClient.new(session_id: @session.id, port: @bridge_port, read_timeout: 0.5)

        expect { client.post_command(line: "!echo STALE", client_id: "tui:1") }.to raise_error(Errno::ETIMEDOUT)
        release << true
        holder.join

        expect(dropped.pop(timeout: 2)).to eq("command_expired")
        expect(queued).to be_empty
      ensure
        release&.push(true)
        holder&.join
      end

      it "queues a command before its deadline" do
        queued = []
        start_bridge(on_command: ->(command) { queued << command })

        status, = post_command(JSON.generate(line: "/model", deadline: Time.now.to_f + 25))

        expect(status).to eq(202)
        expect(queued.size).to eq(1)
      end

      it "answers 400 for a deadline that is not a number" do
        start_bridge(on_command: ->(_) { raise "must not be called" })

        status, resp = post_command(JSON.generate(line: "/model", deadline: "soon"))

        expect(status).to eq(400)
        expect(resp["error"]).to eq("bad_deadline")
      end
    end

    describe "POST /session/:id/recap" do
      def post_recap(session_id: @session.id)
        res = Net::HTTP.post(URI("http://127.0.0.1:#{@bridge_port}/session/#{session_id}/recap"), "{}",
                             "Content-Type" => "application/json")
        [res.code.to_i, JSON.parse(res.body)]
      end

      it "answers with the saved recap and asks for a new one" do
        start_bridge
        recap = instance_double(Samagotchi::IdleRecap, min_user_turns: 2)
        allow(@engine).to receive(:recap).and_return(recap)
        allow(@engine).to receive(:saved_recap).and_return({ text: "We set up Bluefin.", covered: 4, turns_since: 1, created_at: "t" })
        allow(@engine).to receive(:request_recap).and_return(:started)

        expect(post_recap).to eq([200, { "enabled" => true, "min_user_turns" => 2, "request" => "started",
                                         "saved" => { "text" => "We set up Bluefin.", "covered" => 4, "turns_since" => 1, "created_at" => "t" } }])
      end

      it "says when recap is off, and 404s other sessions" do
        start_bridge
        allow(@engine).to receive(:recap).and_return(nil)

        expect(post_recap).to eq([200, { "enabled" => false }])
        expect(post_recap(session_id: "other").first).to eq(404)
      end
    end

    describe "POST /session/:id/exit" do
      def post_exit(body, session_id: @session.id)
        res = Net::HTTP.post(URI("http://127.0.0.1:#{@bridge_port}/session/#{session_id}/exit"),
                             body, "Content-Type" => "application/json")
        [res.code.to_i, JSON.parse(res.body)]
      end

      it "asks the worker with the event log held and answers exiting" do
        asked = []
        start_bridge(on_exit_request: ->(client_id, **) { asked << client_id && nil })
        allow(@engine).to receive(:synchronize_events).and_call_original

        expect(post_exit(JSON.generate(client_id: "tui:1"))).to eq([200, { "status" => "exiting", "session_id" => @session.id }])
        expect(asked).to eq(["tui:1"])
        expect(@engine).to have_received(:synchronize_events)
      end

      it "tells the worker when the exit is to delete the session" do
        asked = []
        start_bridge(on_exit_request: ->(client_id, delete: false) { asked << [client_id, delete] && nil })
        post_exit(JSON.generate(client_id: "tui:1", delete: true))
        post_exit(JSON.generate(client_id: "tui:2"))
        expect(asked).to eq([["tui:1", true], ["tui:2", false]])
      end

      it "says whether the worker will delete the session as empty" do
        start_bridge(on_exit_request: ->(_, **) {}, exit_discards: -> { true })

        expect(post_exit(JSON.generate(client_id: "tui:1")))
          .to eq([200, { "status" => "exiting", "session_id" => @session.id, "discard" => true }])
      end

      it "answers 409 with what keeps the worker up" do
        start_bridge(on_exit_request: ->(_, **) { :client_connected })

        expect(post_exit(JSON.generate(client_id: "tui:1")))
          .to eq([409, { "status" => "held", "reason" => "client_connected", "session_id" => @session.id }])
      end

      it "refuses bad JSON and other sessions" do
        start_bridge(on_exit_request: ->(_, **) { raise "must not be called" })

        expect(post_exit("{nope").first).to eq(400)
        expect(post_exit(JSON.generate(client_id: "tui:1"), session_id: "other"))
          .to eq([404, { "error" => "unknown_session" }])
      end

      it "answers 501 when no worker loop takes the request" do
        start_bridge

        expect(post_exit(JSON.generate(client_id: "tui:1"))).to eq([501, { "error" => "exit_unavailable" }])
      end
    end

    describe "POST /session/:id/question/dismiss" do
      def post_dismiss(body)
        res = Net::HTTP.post(URI("http://127.0.0.1:#{@bridge_port}/session/#{@session.id}/question/dismiss"),
                             body, "Content-Type" => "application/json")
        [res.code.to_i, JSON.parse(res.body)]
      end

      # A turn whose tool asks a question and waits; returns what the tool got.
      def ask_in_turn
        tool_result = Queue.new
        allow(kernel).to receive(:run) do |messages, **_kwargs|
          tool_result << @engine.request_question(question: "Which?", options: %w[A B])
          Samagotchi::LLM::ModelResult.new(text: "done", conversation: messages, exhausted: false,
                                           pending_tool_calls: false, tool_activity: [])
        end
        @turn = Thread.new { run_turn_sync(@engine, @session, "ask me") }
        wait_until(timeout: 3) { @engine.pending_question }
        tool_result
      end

      after { @turn&.join(2) }

      it "dismisses the question it names: the tool returns and every UI is told" do
        start_bridge
        seen = []
        @engine.subscribe(observer: ->(e) { seen << e })
        tool_result = ask_in_turn
        id = @engine.pending_question[:id]

        status, resp = post_dismiss(JSON.generate(id: id))

        expect(status).to eq(200)
        expect(resp).to include("status" => "dismissed", "id" => id)
        expect(JSON.parse(tool_result.pop(timeout: 2))).to include("id" => id)
        expect(seen).to include(hash_including(type: :question_cancelled, id: id, reason: "dismissed"))
      end

      it "answers 409 and leaves the question open for a stale id" do
        start_bridge
        tool_result = ask_in_turn
        id = @engine.pending_question[:id]

        status, resp = post_dismiss(JSON.generate(id: "an-older-question"))

        expect(status).to eq(409)
        expect(resp["error"]).to eq("question_not_pending")
        expect(@engine.pending_question).to include(id: id, status: "pending")
        @engine.answer_question(id: id, selected: ["A"])
        expect(JSON.parse(tool_result.pop(timeout: 2))).to include("selected" => ["A"])
      end

      it "carries a question asked between turns in its snapshot's top level (the turn accumulator drops it)" do
        start_bridge
        id = @engine.post_question({ kind: "continue", question: "Continue?", options: %w[Continue Stop],
                                     multi_select: false, allow_freeform: true }, on_answer: ->(_a, client_id:) {})[:id]

        snap = Samagotchi::BridgeClient.new(session_id: @session.id, port: @bridge_port).get_json("snapshot")["snapshot"]
        expect(snap["current_turn"]).to be_nil
        expect(snap["pending_question"]).to include("id" => id, "kind" => "continue")
      end

      it "answers 409 not_dismissable for a standing question (the step limit's): it stays open" do
        start_bridge
        id = @engine.post_question({ kind: "continue", question: "Continue?", options: %w[Continue Stop],
                                     multi_select: false, allow_freeform: true }, on_answer: ->(_a, client_id:) {})[:id]

        status, resp = post_dismiss(JSON.generate(id: id))

        expect(status).to eq(409)
        expect(resp).to eq("error" => "not_dismissable", "detail" => "answer Continue or Stop")
        expect(@engine.pending_question).to include(id: id, status: "pending")
      end

      it "answers 409 with no question pending, and 400 without an id" do
        start_bridge

        expect(post_dismiss(JSON.generate(id: "q1")).first).to eq(409)
        expect(post_dismiss(JSON.generate({})).first).to eq(400)
      end
    end
  end

  # Drive a turn on a fresh engine while the SSE client reads concurrently.
  def engine_run_turn_events(prompt, raw_event)
    stub_kernel_emit(raw_event)
    run_turn_sync(@engine, @session, prompt)
  end

  def post_turn(body)
    uri = URI("http://127.0.0.1:#{@bridge_port}/session/#{@session.id}/turn")
    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    req.body = body
    res = Net::HTTP.start("127.0.0.1", @bridge_port, open_timeout: 2, read_timeout: 2) { |h| h.request(req) }
    [res.code.to_i, JSON.parse(res.body)]
  end

  def post_answer(body)
    uri = URI("http://127.0.0.1:#{@bridge_port}/session/#{@session.id}/answer")
    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    req.body = body
    res = Net::HTTP.start("127.0.0.1", @bridge_port, open_timeout: 2, read_timeout: 2) { |h| h.request(req) }
    [res.code.to_i, JSON.parse(res.body), res.message]
  end

  def get_state
    get_state_for(@session.id)
  end

    def get_state_for(sid)
      uri = URI("http://127.0.0.1:#{@bridge_port}/session/#{sid}/state")
      res = Net::HTTP.get_response(uri)
      [res.code.to_i, JSON.parse(res.body)]
    end

    def options_request
      uri = URI("http://127.0.0.1:#{@bridge_port}/session/#{@session.id}/turn")
      req = Net::HTTP::Options.new(uri)
      res = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 2) { |h| h.request(req) }
      [res.code.to_i, res.to_hash, res.body]
    end
end
