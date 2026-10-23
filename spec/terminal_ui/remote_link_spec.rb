# frozen_string_literal: true

require "spec_helper"
require "samagotchi/terminal_ui/remote_link"
require "samagotchi/session_commands"
require "samagotchi/guardrails/parent_policy"

# TerminalUI::RemoteLink: a session on another machine as the attached loop
# sees it, through that machine's chi web (SessionAccess::Remote a double
# here; its requests are remote_attach_spec's and web_bridge_client_spec's).
RSpec.describe Samagotchi::TerminalUI::RemoteLink do
  let(:entry) { Samagotchi::Remotes::Entry.new(name: "studio", url: "http://192.0.2.10:4567", token: "t") }
  let(:remote) do
    instance_double(Samagotchi::SessionAccess::Remote, name: "studio", entry: entry,
                                                       invocation: Samagotchi::ChiInvocation.new(remote: "studio"))
  end
  let(:soft) { Samagotchi::Guardrails::ParentPolicy.strategy("soft") }
  let(:hard) { Samagotchi::Guardrails::ParentPolicy.strategy("hard") }
  let(:worker) { { "epoch" => "e1", "started_at" => "t1", "version" => "1.0.0", "features" => %w[delivery unqueue] } }
  let(:woke) do
    Samagotchi::SessionAccess::WakeReply.new(woke: false, worker: worker, default_model: "studio-default", strategy: soft,
                                             installed: "1.1.0")
  end
  let(:now) { [0.0] }
  let(:link) { described_class.new(remote: remote, session_id: "s-1", woke: woke, clock: -> { now.first }) }

  def state(live: true, stopped: false, worker: self.worker, strategy: hard)
    Samagotchi::SessionAccess::WorkerReply.new(live: live, stopped: stopped, worker: (worker if live), strategy: strategy)
  end

  before do
    allow(remote).to receive(:attach_client) do |id, worker:|
      Samagotchi::SessionAccess::WebBridgeClient.new(remote: remote, session_id: id, worker_key: worker["epoch"])
    end
  end

  it "defines every AttachLink method itself" do
    missing = Samagotchi::TerminalUI::AttachLink.public_instance_methods(false).reject do |name|
      described_class.instance_method(name).owner == described_class
    end
    expect(missing).to eq([])
  end

  it "is one client for the attach, keyed by the woken worker's epoch, with what the wake said of that machine" do
    expect(link.client).to have_attributes(session_id: "s-1", worker_key: "e1")
    expect([link.queues?, link.unqueues?]).to eq([true, true])
    expect([link.installed_version, link.default_model_name]).to eq(["1.1.0", "studio-default"])
    expect(link.via.attach("s-1")).to eq("chi --remote studio --attach s-1")
    expect(link.completions).to eq(Samagotchi::TerminalUI::AttachLink::Completions.new(paths: true, memories: false))
    expect(link.reconnect_delays.sum).to be_between(55, 65)
  end

  describe "#live_worker" do
    it "updates the same client's key in place: a new epoch is a move, the same one isn't" do
      allow(remote).to receive(:attach_worker).and_return(state, state(worker: worker.merge("epoch" => "e2", "features" => [])))

      client = link.client
      expect(link.live_worker).to eq([client, nil])
      expect(client.worker_key).to eq("e1")
      expect(link.live_worker).to eq([client, nil])
      expect(client.worker_key).to eq("e2")
      expect(link.queues?).to be(false)
    end

    it "gives each reason: stopped, auth refused and too old stop at once; unreachable and worker gone retry" do
      down = Samagotchi::SessionAccess::RemoteFailed.new("remote studio (http://192.0.2.10:4567): connection refused")
      allow(remote).to receive(:attach_worker).and_return(state(stopped: true, live: false))
      expect(link.live_worker).to eq([:gone, "stopped"])

      allow(remote).to receive(:attach_worker).and_raise(down)
      expect(link.live_worker).to eq([nil, "unreachable"])
      expect(link.failure).to eq(down.message)

      allow(remote).to receive(:attach_worker).and_raise(Samagotchi::SessionAccess::AuthRefused, "token refused")
      expect(link.live_worker).to eq([:gone, "auth_failed"])
      expect(link.failure).to eq("token refused")

      allow(remote).to receive(:attach_worker).and_raise(Samagotchi::SessionAccess::RemoteTooOld, "too old")
      expect(link.live_worker).to eq([:gone, "too_old"])

      allow(remote).to receive(:attach_worker).and_raise(ArgumentError, "Session not found: s-1")
      expect(link.live_worker).to eq([:gone, "unknown_session"])
    end

    it "wakes a worker that isn't live and isn't stopped once per outage, after WAKE_AFTER (P4-D9)" do
      allow(remote).to receive(:attach_worker).and_return(state(live: false))
      woken = woke.with(woke: true, worker: worker.merge("epoch" => "e3"))
      allow(remote).to receive(:attach_wake).and_return(woken)

      expect(link.live_worker).to eq([nil, "worker_gone"])
      now[0] = described_class::WAKE_AFTER - 0.1
      expect(link.live_worker).to eq([nil, "worker_gone"])
      expect(remote).not_to have_received(:attach_wake)

      now[0] = described_class::WAKE_AFTER + 0.1
      expect(link.live_worker).to eq([link.client, nil])
      expect(link.client.worker_key).to eq("e3")
      expect(remote).to have_received(:attach_wake).with("s-1", wait: described_class::WAKE_WAIT).once
    end

    it "wakes no more than once while the worker stays gone" do
      allow(remote).to receive(:attach_worker).and_return(state(live: false))
      allow(remote).to receive(:attach_wake)
        .and_raise(Samagotchi::SessionAccess::Refused.new("the worker for session s-1 did not start its Bridge in time",
                                                          code: "worker_timeout"))
      now[0] = 10.0
      link.live_worker
      now[0] = 20.0
      expect(link.live_worker).to eq([nil, "worker_gone"])
      expect(remote).to have_received(:attach_wake).once
      expect(link.failure).to include("did not start its Bridge in time")
    end
  end

  it "keeps the client on a worker change, its key the event's epoch, and reads the new worker's features" do
    allow(remote).to receive(:attach_worker).and_return(state(worker: worker.merge("epoch" => "e2", "features" => [])))

    expect(link.switched({ port: nil, epoch: "e2" })).to be(link.client)
    expect(link.client.worker_key).to eq("e2")
    expect(link.unqueues?).to be(false)
  end

  it "reads the parent strategy again at report time, the wake's when chi web can't be asked (L4)" do
    allow(remote).to receive(:attach_worker).and_return(state(strategy: hard))
    expect(link.parent_strategy).to eq(hard)

    allow(remote).to receive(:attach_worker).and_raise(Samagotchi::SessionAccess::RemoteFailed, "down")
    expect(link.parent_strategy).to eq(soft)
  end

  it "ingests @path images here, uploads them there, and removes its scratch dir at the end" do
    png = File.expand_path("../fixtures/images/tiny.png", __dir__)
    allow(remote).to receive(:upload_images) { |_id, refs, from:| refs.map { |ref| { file: "up-#{ref[:name]}", name: ref[:name], from: from } } }

    refs = link.ingest_images([png])
    dir = refs.first[:from]
    expect(refs.first).to include(file: "up-tiny.png", name: "tiny.png")
    expect(Dir.children(dir)).not_to be_empty
    link.close
    expect(File.exist?(dir)).to be(false)

    allow(remote).to receive(:upload_images).and_raise(Samagotchi::SessionAccess::RemoteFailed, "remote studio: refused")
    expect { link.ingest_images([png]) }.to raise_error(Samagotchi::SessionAccess::WebBridgeClient::Unreachable, "remote studio: refused")
    link.close
  end

  describe "the join's reads: a turn's saved records, the children counts" do
    it "reads a turn's records once for both, and nothing for a prompt without a turn id" do
      allow(link.client).to receive(:turn_records)
        .and_return({ "tool_records" => [{ "tool" => "read", "duration_ms" => 12 }], "turn_record" => { "status" => "failed" } })

      expect(link.saved_tool_records("t1")).to eq([{ "tool" => "read", "duration_ms" => 12 }])
      expect(link.saved_turn_record("t1")).to eq({ "status" => "failed" })
      expect([link.saved_tool_records(nil), link.saved_turn_record(nil)]).to eq([[], nil])
      expect(link.client).to have_received(:turn_records).once
    end

    it "reads again at the next join (a running turn's records grow)" do
      allow(link.client).to receive(:turn_records).and_return({ "tool_records" => [], "turn_record" => nil })
      2.times do
        link.saved_tool_records("t1")
        link.saved_turn_record("t1")
      end
      expect(link.client).to have_received(:turn_records).twice
    end

    it "draws without them when chi web can't give them: [] and nil, Counts.none" do
      unreachable = Samagotchi::SessionAccess::WebBridgeClient::Unreachable.new("remote studio: timed out")
      allow(link.client).to receive(:turn_records).and_raise(unreachable)
      allow(link.client).to receive(:children_counts).and_raise(unreachable)

      expect([link.saved_tool_records("t1"), link.saved_turn_record("t1"), link.children_counts])
        .to eq([[], nil, Samagotchi::ChildrenStatus::Counts.none])
    end

    it "gives the children counts chi web read there" do
      allow(link.client).to receive(:children_counts).and_return({ "running" => 2, "waiting" => 1, "unreported" => 0 })
      expect(link.children_counts).to eq(Samagotchi::ChildrenStatus::Counts.new(running: 2, waiting: 1, unreported: 0))
    end
  end

  describe "/stats, /exit --delete and /archive" do
    it "reads the stats through the client, and lets chi web's failure through for the loop to word" do
      allow(link.client).to receive(:stats).and_return({ "turns" => 3 })
      expect(link.stats_metrics).to eq("turns" => 3)

      allow(link.client).to receive(:stats).and_raise(Samagotchi::SessionAccess::WebBridgeClient::Unreachable, "down")
      expect { link.stats_metrics }.to raise_error(Samagotchi::SessionAccess::WebBridgeClient::Unreachable, "down")
    end

    it "deletes (force) and archives there; a request that can't be made is Unreachable" do
      allow(remote).to receive(:delete).and_return({ id: "s-1", stopped: true })
      allow(remote).to receive(:archive).and_return({ id: "s-1", archived: ["s-1"], stopped: [], discarded: [] })

      expect(link.delete_session).to eq({ id: "s-1", stopped: true })
      expect(remote).to have_received(:delete).with("s-1", force: true)
      expect(link.archive_session[:archived]).to eq(["s-1"])

      allow(remote).to receive(:archive).and_raise(Samagotchi::SessionAccess::RemoteFailed, "remote studio: refused")
      expect { link.archive_session }.to raise_error(Samagotchi::SessionAccess::WebBridgeClient::Unreachable, "remote studio: refused")
      allow(remote).to receive(:delete).and_raise(Samagotchi::SessionManager::DeleteRefused.new("s-1", :worker_running))
      expect { link.delete_session }.to raise_error(Samagotchi::SessionManager::DeleteRefused)
    end
  end

  it "takes the default model of a new worker's machine (GET …/worker), the wake's until then" do
    allow(remote).to receive(:attach_worker).and_return(
      Samagotchi::SessionAccess::WorkerReply.new(live: true, stopped: false, worker: worker, strategy: hard,
                                                 default_model: "after-restart")
    )
    expect(link.default_model_name).to eq("studio-default")
    link.switched({ epoch: "e2" })
    expect(link.default_model_name).to eq("after-restart")
  end

  # A new terminal command (local: true, shown in the attached TUI) must
  # say what it does remotely.
  it "handles every terminal command of the attached TUI remotely" do
    ids = Samagotchi::SessionCommands.builtin_registry.entries.select { |entry| entry.local && entry.in_ui?(:attached) }.map(&:id).uniq
    expect(ids.sort).to eq(described_class::HANDLED_COMMANDS.sort)
  end
end
