# frozen_string_literal: true

require "json"
require "samagotchi/terminal_ui"
require "samagotchi/terminal_ui/attached_loop"
require_relative "../support/recording_surface"

# AttachedLoop on a link (AttachLink) instead of a client: where the session
# is, what its worker can do and how the printed commands are spelled are
# the link's.
RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "on a link" do
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:stream) { instance_double(Samagotchi::BridgeClient::EventStream, close: nil) }
  let(:via) do
    instance_double(Samagotchi::ChiInvocation, attach: "chi -r x --attach s-1234", resume: "chi -r x --resume s-1234")
      .tap { |v| allow(v).to receive(:command) { |words| "chi -r x #{words}" } }
  end
  let(:link) do
    instance_double(Samagotchi::TerminalUI::LocalLink, client: client, via: via, reconnect_delays: [0.5], queues?: true,
                                                       unqueues?: true, children_counts: Samagotchi::ChildrenStatus::Counts.none,
                                                       installed_version: nil, default_model_name: "dm",
                                                       completions: Samagotchi::TerminalUI::AttachLink::Completions::ALL)
  end
  let(:attached) { described_class.new(link: link, screen: screen, client_id: "tui:1") }
  let(:joined) do
    JSON.parse(JSON.generate(type: :snapshot, snapshot: { messages: [], queued: [], event_seq: 1 },
                             session_state_snapshot: { status: "idle", message_count: 0 }))
  end

  def reply(body, status: 202) = Samagotchi::BridgeClient::Response.new(status: status, body: JSON.generate(body))

  def run_with(inputs)
    allow(client).to receive(:follow) do |&block|
      block.call(joined)
      stream
    end
    attached.run(input: ->(_prompt, _prefill) { inputs.shift })
  end

  it "follows the link's client with the link's reconnect delays, and spells the detach line the link's way" do
    expect(run_with([nil])).to eq(:detached)

    expect(client).to have_received(:follow).with(client_id: "tui:1", rediscover: anything, reconnect_delays: [0.5])
    expect(screen.lines.last).to eq("Detached; the session keeps running. Re-attach with: chi -r x --attach s-1234")
  end

  it "rediscovers through the link: its client, or :gone whatever the reason" do
    found = instance_double(Samagotchi::BridgeClient)
    allow(link).to receive(:live_worker).and_return([found, nil], [nil, nil], [:gone, "stopped"])

    expect(Array.new(3) { attached.send(:live_worker) }).to eq([found, nil, :gone])
  end

  it "sends requests to the client the link switched to" do
    moved = instance_double(Samagotchi::BridgeClient, session_id: "s-1234")
    allow(link).to receive(:switched).and_return(moved)
    attached.handle_event({ "type" => "worker_changed", "port" => 4321 })

    expect(link).to have_received(:switched).with(hash_including(port: 4321))
    expect(attached.instance_variable_get(:@client)).to be(moved)
  end

  it "asks the link whether the worker unqueues, and words the refusal the link's way" do
    allow(link).to receive(:unqueues?).and_return(false)

    run_with(["/unqueue", nil])

    expect(screen.lines).to include("(/unqueue needs a newer worker: restart it with chi -r x sessions restart)")
  end

  it "stores @path images through the link and sends its refs" do
    ref = { file: "img-1.png", name: "a.png" }
    allow(link).to receive(:ingest_images).and_return([ref])
    allow(client).to receive(:post_turn).and_return(reply({ "enqueued_id" => "e1" }))

    png = File.expand_path("../fixtures/images/tiny.png", __dir__)
    run_with(["look @#{png}", nil])

    expect(link).to have_received(:ingest_images).with([png])
    expect(client).to have_received(:post_turn).with(hash_including(images: [ref]))
  end

  it "reads /stats from the link" do
    allow(link).to receive(:stats_metrics).and_return(nil)
    run_with(["/stats", nil])
    expect(screen.lines).to include("(no metrics: the worker did not answer)")
  end

  it "offers @path and #memory completions only as the link does" do
    allow(link).to receive(:completions)
      .and_return(Samagotchi::TerminalUI::AttachLink::Completions.new(paths: false, memories: false))

    expect(attached.send(:assist_path_completion_candidates, "@li")).to eq([])
    expect(attached.send(:assist_path_completion_candidates, "#a")).to eq([])
    expect(attached.send(:assist_path_completion_candidates, "/q")).to eq(%w[/queue /quit])
  end
end
