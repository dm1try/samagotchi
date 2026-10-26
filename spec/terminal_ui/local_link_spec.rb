# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/terminal_ui/local_link"

RSpec.describe Samagotchi::TerminalUI::LocalLink do
  let(:state_dir) { Dir.mktmpdir("local-link") }
  let(:id) { "s-1234" }
  let(:session_dir) { Samagotchi::Session.session_dir(id, state_dir: state_dir) }
  let(:client) { Samagotchi::BridgeClient.new(session_id: id, port: 4100, secret: nil) }
  let(:link) { described_class.new(client: client, state_dir: state_dir) }

  before { FileUtils.mkdir_p(session_dir) }
  after { FileUtils.rm_rf(state_dir) }

  def fixture(name) = File.expand_path("../fixtures/images/#{name}", __dir__)

  it "defines every AttachLink method itself" do
    missing = Samagotchi::TerminalUI::AttachLink.public_instance_methods(false).reject do |name|
      described_class.instance_method(name).owner == described_class
    end
    expect(missing).to eq([])
  end

  describe "#live_worker" do
    it "finds the sidecar's worker, none while there is none, and is gone once the session was stopped" do
      found = instance_double(Samagotchi::BridgeClient)
      allow(Samagotchi::BridgeClient).to receive(:discover).and_return(nil, found)

      expect(link.live_worker).to eq([nil, nil])
      expect(link.live_worker).to eq([found, nil])
      expect(Samagotchi::BridgeClient).to have_received(:discover).with(id, session_dir: session_dir, host: "127.0.0.1").twice

      # The stop marker in the link's state dir.
      allow(Samagotchi::Session).to receive(:stopped_marker?).with(id, state_dir: state_dir).and_return(true)
      expect(link.live_worker).to eq([:gone, "stopped"])
    end
  end

  it "switches to the new worker's port, for its client from then on" do
    moved = link.switched({ port: 4200 })

    expect([moved.session_id, moved.port, moved.host]).to eq([id, 4200, "127.0.0.1"])
    expect(link.client).to be(moved)
    expect(link.switched({ "port" => 4300 }).port).to eq(4300)
  end

  it "switches with the secret the new worker's sidecar names, none when the sidecar names another port" do
    Samagotchi::WorkerSidecar.new(port: 4200, session_id: id, secret: "5e" * 32).write(session_dir)

    expect(link.switched({ port: 4200 }).send(:secret_headers)).to eq("X-Chi-Bridge" => "5e" * 32)
    expect(link.switched({ port: 4300 }).send(:secret_headers)).to eq({})
  end

  describe "#queues? and #unqueues?" do
    def sidecar(features) = Samagotchi::WorkerSidecar.new(port: 1, session_id: id, features: features).write(session_dir)

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
