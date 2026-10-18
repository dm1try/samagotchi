# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "socket"
require "json"
require "support/test_kernel"

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/bridge"

# What a :generation_chunk looks like on a worker's SSE stream, live and
# replayed (Bridge::ClientEvent): chi's counts, the ring keeping the raw event.
RSpec.describe "Bridge SSE generation_chunk" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:state_dir) { Dir.mktmpdir }
  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:payload) { { "content" => "hi", "tokens" => [1, 2], "tokens_predicted" => 2, "tokens_evaluated" => 489 } }
  let(:chunk) { { type: :generation_chunk, iteration: 1, content: "hi", text: "hi", thinking: "", payload: payload } }

  before do
    WebMock.allow_net_connect! if defined?(WebMock)
    @engine = Samagotchi::Engine.new(client: client, kernel: kernel)
    @session = Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd)
    @bridge = Samagotchi::Bridge.new(engine: @engine, state_dir: state_dir, session_id: @session.id, heartbeat_interval: 0.2)
    @bridge.start
    sidecar = File.join(Samagotchi::Session.session_dir(@session.id, state_dir: state_dir), "bridge.json")
    @port = JSON.parse(File.read(sidecar))["port"]
    @sockets = []
    allow(kernel).to receive(:run) do |_messages, **kwargs|
      kwargs[:on_stream_event].call(chunk)
      Samagotchi::LLM::ModelResult.new(text: "ok", conversation: [], exhausted: false, pending_tool_calls: false, tool_activity: [])
    end
  end

  after do
    @sockets.each { |s| s.close rescue nil }
    @bridge&.stop
    WebMock.disable_net_connect! if defined?(WebMock)
  end

  def open_stream(query = "")
    socket = TCPSocket.new("127.0.0.1", @port)
    @sockets << socket
    socket.write("GET /session/#{@session.id}/stream#{query} HTTP/1.1\r\nHost: 127.0.0.1\r\nUser-Agent: spec\r\n\r\n")
    socket
  end

  # The stream's frames' data, read until a turn_completed frame.
  def frames_until_turn_completed(socket, timeout: 5)
    buffer = +""
    deadline = SpecWaiting.mono + timeout
    until buffer.include?("event: turn_completed") && buffer.split("event: turn_completed", 2).last.include?("\r\n\r\n")
      raise "timed out reading the stream" if SpecWaiting.mono > deadline

      buffer << socket.read_nonblock(65_536) if socket.wait_readable(0.1)
    end
    buffer.scan(/^data: (.*)\r$/).flatten.map { |line| JSON.parse(line) }
  end

  def stream_chunk(frames) = frames.find { |f| f["type"] == "generation_chunk" }

  it "carries the chunk's counts live" do
    socket = open_stream
    SpecWaiting.wait_until! "the stream" do
      @bridge.open_streams == 1
    end
    @engine.run_turn(@session, "hi", on_event: ->(_e) {})

    expect(stream_chunk(frames_until_turn_completed(socket))["counts"])
      .to eq("prompt_tokens" => 489, "completion_tokens" => 2, "total_tokens" => 491)
  end

  it "carries them on replay, and the ring keeps the raw event" do
    @engine.run_turn(@session, "hi", on_event: ->(_e) {})

    replayed = stream_chunk(frames_until_turn_completed(open_stream))
    expect(replayed["counts"]).to eq("prompt_tokens" => 489, "completion_tokens" => 2, "total_tokens" => 491)

    ring = @bridge.instance_variable_get(:@ring)
    kept = ring.events_in_range(after_seq: 0, to_seq: @engine.event_count).map { |r| r[:data] }
                .find { |e| e[:type] == :generation_chunk }
    expect(kept[:payload]).to eq(payload)
    expect(kept).not_to have_key(:counts)
  end
end
