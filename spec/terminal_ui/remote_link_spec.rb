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
    expect([link.saved_tool_records("t"), link.saved_turn_record("t"), link.children_counts])
      .to eq([[], nil, Samagotchi::ChildrenStatus::Counts.none])
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

  it "refuses the terminal's commands chi web has no route for yet, in one line, and only those" do
    expect(link.unavailable(:exit, "/exit --delete ")).to eq(format(described_class::NOT_YET, "/exit --delete"))
    expect(link.unavailable(:stats, "/stats")).to eq("(/stats isn't available through a remote yet: /detach leaves the session running)")
    expect(link.unavailable(:unqueue, "/unqueue")).to be_nil
  end

  # A new terminal command (local: true, shown in the attached TUI) must
  # say what it does remotely: handled, or refused for now.
  it "covers every terminal command of the attached TUI: handled remotely, or NOT_YET" do
    ids = Samagotchi::SessionCommands.builtin_registry.entries.select { |entry| entry.local && entry.in_ui?(:attached) }.map(&:id).uniq
    covered = described_class::HANDLED_COMMANDS + described_class::NOT_YET_COMMANDS
    expect(ids - covered).to eq([])
    expect(covered - ids).to eq([])
    expect(described_class::HANDLED_COMMANDS & described_class::NOT_YET_COMMANDS).to eq([])
  end
end
