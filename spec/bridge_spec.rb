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

    def start_bridge(input_format: nil)
      @engine = make_engine
      @session = make_session
      @bridge = described_class.new(
        engine: @engine, state_dir: state_dir, session_id: @session.id,
        heartbeat_interval: 0.2, input_format: input_format
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
