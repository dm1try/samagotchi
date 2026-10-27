# frozen_string_literal: true

require "json"
require "socket"
require "samagotchi/worker_link"
require_relative "../support/worker_fixtures"
require_relative "../support/worker_links"
require "tmpdir"
require "samagotchi/session_manager"
require "samagotchi/terminal_ui/local_link"

RSpec.describe Samagotchi::TerminalUI::LocalLink do
  include WorkerFixtures
  include WorkerLinks

  let(:state_dir) { Dir.mktmpdir("local-link") }
  let(:id) { "s-1234" }
  let(:session_dir) { Samagotchi::Session.session_dir(id, state_dir: state_dir) }
  let(:client) { Samagotchi::BridgeClient.new(session_id: id, port: 4100, secret: nil) }
  let(:link) { described_class.new(client: client, state_dir: state_dir) }

  before { FileUtils.mkdir_p(session_dir) }
  after { FileUtils.rm_rf(state_dir) }

  def fixture(name) = File.expand_path("../fixtures/images/#{name}", __dir__)

  def sidecar(port, secret)
    Samagotchi::WorkerSidecar.new(port: port, session_id: id, secret: secret, pid: Process.pid).write(session_dir)
  end

  it "defines every AttachLink method itself" do
    missing = Samagotchi::TerminalUI::AttachLink.public_instance_methods(false).reject do |name|
      described_class.instance_method(name).owner == described_class
    end
    expect(missing).to eq([])
  end

  describe "#live_worker" do
    it "finds the sidecar's worker, none while there is none, and is gone once the session was stopped" do
      found = instance_double(Samagotchi::BridgeClient)
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(none_link, live_link(client: found))

      expect(link.live_worker).to eq([nil, nil])
      expect(link.live_worker).to eq([found, nil])
      expect(Samagotchi::WorkerLink).to have_received(:resolve).with(session_dir, unlink: true, host: "127.0.0.1").twice

      # The stop marker in the link's state dir.
      allow(Samagotchi::Session).to receive(:stopped_marker?).with(id, state_dir: state_dir).and_return(true)
      expect(link.live_worker).to eq([:gone, "stopped"])
    end
  end

  it "switches to the new worker's port, for its client from then on" do
    hold_worker(session_dir)
    sidecar(4200, "ab" * 32)
    moved = link.switched({ port: 4200 })

    expect([moved.session_id, moved.port, moved.host]).to eq([id, 4200, "127.0.0.1"])
    expect(moved.send(:secret_headers)).to eq("X-Chi-Bridge" => "ab" * 32)
    expect(link.client).to be(moved)
    sidecar(4300, "cd" * 32)
    expect(link.switched({ "port" => 4300 }).port).to eq(4300)
  end

  it "never creates a secretless client when the sidecar names another port" do
    hold_worker(session_dir)
    sidecar(4200, "5e" * 32)

    expect(link.switched({ port: 4200 }).send(:secret_headers)).to eq("X-Chi-Bridge" => "5e" * 32)
    expect(link.switched({ port: 4300 })).to be_nil
  end

  it "follows the new worker after restart falls back to TERM, without treating it as stopped" do
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: state_dir)
    session.save(state_dir: state_dir)
    dir = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)
    old_listener = TCPServer.new("127.0.0.1", 0)
    old_port = old_listener.local_address.ip_port
    old_listener.close
    new_listener = TCPServer.new("127.0.0.1", 0)
    new_port = new_listener.local_address.ip_port
    old_lock = hold_worker(dir)
    Samagotchi::WorkerSidecar.new(port: old_port, session_id: session.id, secret: "ab" * 32, pid: Process.pid,
                                  protocol: Samagotchi::WorkerLink::PROTOCOL, epoch: "old", started_at: "old",
                                  version: "0.18.1", features: ["restart"]).write(dir)
    attached_client = Samagotchi::BridgeClient.new(session_id: session.id, port: old_port, secret: "ab" * 32)
    attached_link = described_class.new(client: attached_client, state_dir: state_dir)
    replacement = Samagotchi::WorkerSidecar.new(port: new_port, session_id: session.id, secret: "cd" * 32,
                                                pid: Process.pid, protocol: Samagotchi::WorkerLink::PROTOCOL,
                                                epoch: "new", started_at: "new", version: "0.19.0",
                                                features: ["restart"])
    allow(Process).to receive(:kill) do |signal, pid|
      expect([signal, pid]).to eq(["TERM", Process.pid])
      old_lock.release
      worker_locks.delete(old_lock)
    end
    allow(Samagotchi::SessionManager).to receive(:resume_session) do |_session_id, state_dir:|
      hold_worker(dir)
      replacement.write(dir)
    end

    restarted = Samagotchi::SessionManager.restart_session(session.id, state_dir: state_dir, wait: 1)
    expect(restarted).to have_attributes(from_version: "0.18.1", version: "0.19.0")
    expect(Samagotchi::Session.stopped_marker?(session.id, state_dir: state_dir)).to be(false)

    connection = Queue.new
    bridge_thread = Thread.new do
      socket = new_listener.accept
      connection << socket
      request = +""
      request << socket.gets.to_s until request.end_with?("\r\n\r\n")
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n")
      socket.read
    rescue IOError, SystemCallError
      nil
    ensure
      socket&.close
      new_listener.close unless new_listener.closed?
    end
    bridge_thread.report_on_exception = false
    events = Queue.new
    stream = attached_client.follow(rediscover: attached_link.method(:live_worker), reconnect_delays: [0.01]) do |event|
      attached_link.switched(event) if event["type"] == "worker_changed"
      events << event
    end

    expect(pop!(events, "the restarted worker's stream")).to include("type" => "worker_changed", "port" => new_port)
    expect(attached_link.client.port).to eq(new_port)
    expect(events).to be_empty
  ensure
    stream&.close
    new_listener&.close unless new_listener&.closed?
    join!(bridge_thread, "the replacement worker's Bridge") if bridge_thread
    connection.pop.close unless connection && connection.empty?
  end

  it "switches to the very client #live_worker found for the stream, whatever the sidecar says by now" do
    found = Samagotchi::BridgeClient.new(session_id: id, port: 4200, secret: "ab" * 32)
    allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(live_link(client: found))
    link.live_worker
    Samagotchi::WorkerSidecar.new(port: 4900, session_id: id, secret: "cd" * 32).write(session_dir) # a later worker

    expect(link.switched({ "port" => 4200 })).to be(found)
    expect(link.client).to be(found)
  end

  describe "#queues? and #unqueues?" do
    def sidecar(features)
      hold_worker(session_dir) if worker_locks.empty?
      Samagotchi::WorkerSidecar.new(port: 1, session_id: id, features: features, pid: Process.pid).write(session_dir)
    end

    it "are true with no sidecar to read (its Bridge answers)" do
      expect([link.queues?, link.unqueues?]).to eq([true, true])
    end

    it "follow the sidecar's features" do
      sidecar(%w[delivery])
      expect([link.queues?, link.unqueues?]).to eq([true, false])
      sidecar(%w[unqueue])
      expect([link.queues?, link.unqueues?]).to eq([false, true])
    end
  end

  describe "#stats_metrics" do
    it "reads the stats route, then an older worker's state" do
      allow(client).to receive(:get_json).with("stats").and_return({ "metrics" => { "turns" => 2 } })
      expect(link.stats_metrics).to eq("turns" => 2)

      allow(client).to receive(:get_json).with("stats").and_return(nil)
      allow(client).to receive(:get_json).with("state").and_return({ "session_state_snapshot" => { "metrics" => { "turns" => 1 } } })
      expect(link.stats_metrics).to eq("turns" => 1)

      allow(client).to receive(:get_json).with("state").and_return(nil)
      expect(link.stats_metrics).to be_nil
    end
  end

  describe "#ingest_images" do
    it "stores each in the session's images/ and gives its ref" do
      refs = link.ingest_images([fixture("tiny.png")])

      expect(refs.size).to eq(1)
      expect(refs.first.keys).to eq(%i[file name])
      expect(refs.first[:name]).to eq("tiny.png")
      expect(File).to exist(Samagotchi::ImageStore.path_for(session_dir, refs.first))
    end

    it "raises ImageStore::Error for one it can't use" do
      expect { link.ingest_images([File.join(state_dir, "missing.png")]) }.to raise_error(Samagotchi::ImageStore::Error)
    end
  end

  describe "saved records" do
    before do
      File.write(File.join(session_dir, "analytics.json"), JSON.generate(
        "tool_records" => [{ "turn_id" => "t1", "tool" => "read", "duration_ms" => 5 }],
        "turn_records" => [{ "id" => "t1", "status" => "failed" }]
      ))
    end

    it "reads a turn's tool records and its record from analytics.json" do
      expect(link.saved_tool_records("t1")).to eq([{ "turn_id" => "t1", "tool" => "read", "duration_ms" => 5 }])
      expect(link.saved_turn_record("t1")).to eq("id" => "t1", "status" => "failed")
      expect([link.saved_tool_records("t9"), link.saved_turn_record(nil)]).to eq([[], nil])
    end

    it "has none for a session id that isn't one" do
      bad = described_class.new(client: Samagotchi::BridgeClient.new(session_id: "../x", port: 1, secret: nil), state_dir: state_dir)
      expect([bad.saved_tool_records("t1"), bad.saved_turn_record("t1")]).to eq([[], nil])
    end
  end

  it "calls its session callables with the session id" do
    calls = []
    link = described_class.new(client: client, state_dir: state_dir,
                               delete_session: ->(sid) { calls << [:delete, sid] },
                               archive_session: ->(sid) { (calls << [:archive, sid]) && { discarded: [] } },
                               installed_version: -> { "9.9.9" },
                               children_counts: ->(sid) { (calls << [:children, sid]) && :counts })

    expect([link.children_counts, link.archive_session, link.installed_version]).to eq([:counts, { discarded: [] }, "9.9.9"])
    link.delete_session
    expect(calls).to eq([[:children, id], [:archive, id], [:delete, id]])
  end

  it "counts the session's delegates from its state dir by default" do
    expect(link.children_counts).to eq(Samagotchi::ChildrenStatus::Counts.none)
  end

  it "reads this machine's default model and the session's parent strategy" do
    allow(Samagotchi::ModelProfile).to receive(:default_model_name).and_return("m1")
    allow(Samagotchi::ParentReport).to receive(:strategy_for).with(id, state_dir: state_dir).and_return(:strategy)

    expect([link.default_model_name, link.parent_strategy]).to eq(["m1", :strategy])
  end

  it "offers every completion, reconnects as the loop did, and spells commands for this machine" do
    expect(link.completions).to eq(Samagotchi::TerminalUI::AttachLink::Completions.new(paths: true, memories: true))
    expect(link.reconnect_delays).to eq(Samagotchi::BridgeClient::EventStream::REDISCOVER_DELAYS)
    expect(link.via).to be(Samagotchi::ChiInvocation::HERE)
  end
end
