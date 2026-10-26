# frozen_string_literal: true

require "spec_helper"
require "samagotchi/worker_link"
require "tmpdir"
require "json"
require "support/test_kernel"

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/bridge"
require "samagotchi/bridge_client"

# POST /session/:id/turn/dequeue: a queued message (one that waits for the
# running turn's end) taken back before it runs.
RSpec.describe Samagotchi::Bridge, "dequeue" do
  let(:state_dir) { Dir.mktmpdir("bridge-dequeue") }
  let(:engine) { Samagotchi::Engine.new(client: test_client, kernel: test_kernel) }
  let(:on_input) { instance_double(Proc, call: nil) }
  let(:session_dir) { Samagotchi::Session.session_dir("s1", state_dir: state_dir) }
  let(:events) { [] }

  before do
    WebMock.allow_net_connect! if defined?(WebMock)
    @bridge = described_class.new(engine: engine, state_dir: state_dir, session_id: "s1", heartbeat_interval: 0.2,
                                  on_input: on_input).start
    @client = Samagotchi::WorkerLink.client("s1", session_dir: session_dir)
    engine.subscribe(observer: ->(event) { events << event if %i[turn_enqueued turn_dequeued].include?(event[:type]) })
  end

  after do
    @bridge.stop
    WebMock.disable_net_connect! if defined?(WebMock)
    FileUtils.rm_rf(state_dir)
  end

  def accumulator = @bridge.instance_variable_get(:@accumulator)
  def running_turn! = accumulator.call(type: :turn_started, prompt: "long one")

  def send_prompt(prompt, delivery: "queue")
    @client.post_turn(prompt: prompt, client_id: "tui:a", delivery: delivery).json.fetch("enqueued_id")
  end

  def inbox_prompts
    Samagotchi::SessionInbox.find_new_input_files(session_dir).sort.map { |f| JSON.parse(File.read(f))["prompt"] }
  end

  it "removes a queued message before the drain: 200 with its prompt, the file gone, a tombstone, " \
     ":turn_dequeued after its :turn_enqueued, and the snapshot no longer lists it" do
    running_turn!
    id = send_prompt("later")

    reply = @client.dequeue(enqueued_id: id, client_id: "web:tab-2")

    expect(reply.status).to eq(200)
    expect(reply.json).to eq("status" => "removed", "enqueued_id" => id, "prompt" => "later", "session_id" => "s1")
    expect(inbox_prompts).to eq([])
    expect(Samagotchi::SessionInbox.removed?(session_dir, id)).to be(true)
    expect(events.map { |e| e[:type] }).to eq(%i[turn_enqueued turn_dequeued])
    expect(events.last).to include(enqueued_id: id, client_id: "web:tab-2")
    expect(accumulator.queued).to eq([])
  end

  it "does not wake the worker: a removal is no input" do
    running_turn!
    id = send_prompt("later")
    expect(on_input).to have_received(:call).once

    @client.dequeue(enqueued_id: id)

    expect(on_input).to have_received(:call).once
  end

  it "removes only the one asked for: of two queued, the first still runs" do
    running_turn!
    first = send_prompt("first")
    second = send_prompt("second")

    expect(@client.dequeue(enqueued_id: second).status).to eq(200)

    expect(inbox_prompts).to eq(["first"])
    expect(accumulator.queued.map { |q| q[:enqueued_id] }).to eq([first])
  end

  it "answers 409 already_started when the drain took the file first (claimed), and removes nothing" do
    running_turn!
    id = send_prompt("later")
    Samagotchi::SessionInbox.claim_input_file(Samagotchi::SessionInbox.find_new_input_files(session_dir).first)

    reply = @client.dequeue(enqueued_id: id)

    expect([reply.status, reply.json["error"]]).to eq([409, "already_started"])
    expect(Dir.glob(File.join(session_dir, "input", "*.processing")).size).to eq(1)
    expect(Samagotchi::SessionInbox.removed?(session_dir, id)).to be(false)
    expect(events.map { |e| e[:type] }).to eq([:turn_enqueued])
  end

  it "answers 409 already_started while the snapshot still lists it with no file left (taken, not announced yet)" do
    running_turn!
    id = send_prompt("later")
    FileUtils.rm_f(Samagotchi::SessionInbox.find_new_input_files(session_dir))

    reply = @client.dequeue(enqueued_id: id)

    expect([reply.status, reply.json["error"]]).to eq([409, "already_started"])
  end

  it "answers 409 not_queued for a next-step message (a drain may merge it any moment), and leaves it" do
    running_turn!
    id = send_prompt("now", delivery: nil)

    reply = @client.dequeue(enqueued_id: id)

    expect([reply.status, reply.json["error"]]).to eq([409, "not_queued"])
    expect(inbox_prompts).to eq(["now"])
  end

  it "answers 404 unknown_enqueued_id (not the unrouted path's not_found) for an id it never had" do
    reply = @client.dequeue(enqueued_id: "nope")

    expect([reply.status, reply.json["error"]]).to eq([404, "unknown_enqueued_id"])
  end

  it "answers 400 without an id, and 408 past its deadline (nothing removed)" do
    running_turn!
    id = send_prompt("later")

    _, status, = @bridge.send(:handle_dequeue_turn, "s1", JSON.generate(client_id: "x"))
    expect(status).to eq(400)
    _, status, body = @bridge.send(:handle_dequeue_turn, "s1", JSON.generate(enqueued_id: id, deadline: Time.now.to_f - 5))
    expect([status, body[:error]]).to eq([408, "deadline_passed"])
    expect(inbox_prompts).to eq(["later"])
  end

  it "writes nothing once the bridge is stopped (intake closed)" do
    running_turn!
    id = send_prompt("later")
    @bridge.stop

    expect { @bridge.send(:handle_dequeue_turn, "s1", JSON.generate(enqueued_id: id)) }
      .to raise_error(described_class::IntakeClosed)
    expect(inbox_prompts).to eq(["later"])
  end

  it "names the unqueue feature in its sidecar" do
    expect(JSON.parse(File.read(File.join(session_dir, "bridge.json")))["features"]).to include("unqueue")
  end
end
