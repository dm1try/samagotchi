# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "stringio"
require "socket"
require "net/http"
require "json"

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/bridge"
require "samagotchi/bridge_client"

# A tiny monotonic clock so the specs don't depend on Time.now.
def mono
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

# Minimal SSE/HTTP client for the bridge integration specs. Talks a raw
# TCP request/response against the in-process bridge so we can read the
# live event-stream incrementally (Net::HTTP blocks on an open stream).
class SSEClient
  attr_reader :events

  def initialize(port, session_id, last_event_id: nil, snapshot: false)
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
    deadline = mono + timeout
    @mutex.synchronize do
      until @events.size >= count || mono > deadline
        @cv.wait(@mutex, [deadline - mono, 0].max)
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
  around do |example|
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    example.run
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
  end

  let(:client) { instance_double(Samagotchi::Client) }
  let(:kernel) { instance_double(Samagotchi::KernelLoop) }

  def make_engine
    Samagotchi::Engine.new(mode: :assist, client: client, kernel: kernel)
  end

  def make_session
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd)
  end

  # Stub the kernel to emit a canned set of raw kernel events, then complete.
  def stub_kernel_emit(*raw_events)
    allow(kernel).to receive(:run) do |_messages, **kwargs|
      cb = kwargs[:on_stream_event]
      raw_events.each { |e| cb.call(e) }
      Samagotchi::KernelLoop::Result.new(
        output: "ok", conversation: [], exhausted: false, pending_tool_calls: false, tool_activity: []
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
        engine:, ring:, session_id: "s1", last_event_id: "5",
        snapshot_provider: -> { {} }
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
        snapshot_provider: -> { {} }, heartbeat_interval: 0.05
      )
      writer_thread = Thread.new { writer.serve!(io) }
      sleep(0.3) # subscribe + replay complete

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
          snapshot_provider: -> { {} }, heartbeat_interval: 0.05
        )
        writer_thread = Thread.new { writer.serve!(io) }
        sleep(0.3)

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

    it "does not block the enqueuer while the writer thread is stuck writing" do
      engine = make_engine
      allow(engine).to receive(:run_turn)
      ring = Samagotchi::Bridge::RingBuffer.new(capacity: 64)
      io = ControllableIO.new
      io.write_sleep = 0.02 # simulate a slow / hung client socket
      writer = Samagotchi::Bridge::SSEWriter.new(
        engine:, ring:, session_id: "s1",
        snapshot_provider: -> { {} }, heartbeat_interval: 0.05
      )
      writer_thread = Thread.new { writer.serve!(io) }
      sleep(0.2) # subscribe + headers written

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

    def start_bridge(input_format: nil, on_input: nil)
      @engine = make_engine
      @session = make_session
      @bridge = described_class.new(
        engine: @engine, state_dir: state_dir, session_id: @session.id,
        heartbeat_interval: 0.2, input_format: input_format, on_input: on_input
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

    it "writes a discoverable port sidecar on start" do
      start_bridge
      expect(@bridge_port).to be > 0
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
          sleep(0.3)
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
        sleep(0.2)

        started = mono
        @bridge.stop
        expect(mono - started).to be < 0.5
      end
    end

    describe "client tracking" do
      def wait_until(timeout: 3)
        deadline = mono + timeout
        sleep(0.02) until yield || mono > deadline
        yield
      end

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
        sleep(0.1)
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
      sleep(0.3) # ensure the acceptor + per-connection subscribe happened

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
      sleep(0.3)
      stub_kernel_emit({ type: :generation_started, iteration: 1 })
      run_turn_sync(@engine, @session, "hi 1")
      last_seen = c1.last[:id]
      c1.stop

      # Turn runs while c1 is gone → buffered in the ring.
      stub_kernel_emit({ type: :generation_started, iteration: 1 })
      run_turn_sync(@engine, @session, "hi 2")

      # Reconnect from last_seen: replay the buffered window then go live.
      c2 = SSEClient.new(@bridge_port, @session.id, last_event_id: last_seen).start
      @clients << c2
      sleep(0.3)
      events = c2.wait_for(2, timeout: 3)
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
          Samagotchi::KernelLoop::Result.new(
            output: "done", conversation: messages + conversation, exhausted: false,
            pending_tool_calls: false, tool_activity: []
          )
        end
        release
      end

      def wait_until(timeout: 3)
        deadline = mono + timeout
        sleep(0.01) until yield || mono > deadline
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
        expect(body["session_state_snapshot"]).to include("status" => "running", "event_seq" => snap["event_seq"])
        expect(missing).to be_nil
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
        expect(stream.last_event_id).to eq(seqs.last.to_s)
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
          Samagotchi::KernelLoop::Result.new(
            output: "r-#{prompt}", conversation: messages + [{ role: "model", content: "r-#{prompt}" }],
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

      # The cursor was ahead of this worker (it restarted): later events must
      # still arrive, not be dropped as already seen.
      run_turn_sync(@engine, @session, "after the reset")
      after = c.wait_for(3).drop(1)
      expect(after.first[:data]).to include("type" => "turn_started", "prompt" => "after the reset")
      expect(after.first[:id].to_i).to eq(reset[:id].to_i + 1)
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
      sleep(0.3)
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

    it "announces nothing for a turn it forwards to another session, or fails to write" do
      start_bridge
      seen = []
      @engine.subscribe(observer: ->(e) { seen << e })

      other = make_session
      status, = post_turn(JSON.generate(session_id: other.id, prompt: "for someone else"))
      expect(status).to eq(202)

      allow(Samagotchi::SessionManager).to receive(:write_turn_input).and_return(false)
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

      post_turn(JSON.generate(session_id: make_session.id, prompt: "for someone else"))
      allow(Samagotchi::SessionManager).to receive(:write_turn_input).and_return(false)
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
    end

    it "rejects an unknown session on the read surface with 404" do
      start_bridge
      _status, resp = get_state_for("does-not-exist")
      expect(resp["error"]).to eq("unknown_session")
    end

    it "responds to CORS preflight OPTIONS" do
      start_bridge
      status, = options_request
      expect(status).to eq(204)
    end

    it "answers 409 Conflict when the question is no longer pending (another client won)" do
      start_bridge
      status, resp, reason = post_answer(JSON.generate(id: "q-gone", selected: ["Cats"]))
      expect(status).to eq(409)
      expect(reason).to eq("Conflict")
      expect(resp["error"]).to eq("question_not_pending")
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
          Samagotchi::KernelLoop::Result.new(output: "done", conversation: messages, exhausted: false,
                                             pending_tool_calls: false, tool_activity: [])
        end
        @turn = Thread.new { run_turn_sync(@engine, @session, "ask me") }
        deadline = mono + 3
        sleep(0.01) until @engine.pending_question || mono > deadline
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
      [res.code.to_i, res.body]
    end
end
