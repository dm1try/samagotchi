# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "support/test_kernel"

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/bridge"
require "samagotchi/owner_lock"
require "samagotchi/session_manager"
require "samagotchi/tools/delegate_relay"

# A grandchild's approval relayed hop by hop (a plugin's ctx.sessions.fork
# can make one): the middle child relays it as its own card, the parent
# relays that card one hop further, and the parent's user's answer goes back
# down the same hops, each child verifying with its own parent's Bridge.
RSpec.describe "approval relay, two hops" do
  let(:state_dir) { Dir.mktmpdir("relay-chain") }
  let(:top) { new_session(prompt: "ship it") }
  let(:middle) { new_session(parent_id: top.id, prompt: "release the gem") }
  let(:leaf) { new_session(parent_id: middle.id, prompt: "push the tag") }
  let(:approval) do
    { question: "execute: git push --tags", options: ["Allow once", "Allow this call for the session", "Deny"],
      header: "Approve tool call?", multi_select: false, allow_freeform: true, kind: "approval",
      approval: { tool: "execute", command: "git push --tags", scopes: %w[once session] } }
  end

  before do
    WebMock.allow_net_connect! if defined?(WebMock)
    stub_const("Samagotchi::QuestionDesk::WATCH_INTERVAL", 0.05)
    @bridges = []
    @locks = []
    @threads = []
  end

  after do
    @threads.each { |t| t.kill if t.alive? }
    @bridges.each(&:stop)
    @locks.each(&:release)
    WebMock.disable_net_connect! if defined?(WebMock)
    FileUtils.rm_rf(state_dir)
  end

  def new_session(prompt:, parent_id: nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd, parent_id: parent_id).tap do |s|
      s.last_prompt = prompt
      s.save(state_dir: state_dir)
    end
  end

  # A worker for +session+: its Engine (interface :worker), its Bridge, its owner lock.
  def worker(session)
    engine = Samagotchi::Engine.new(client: test_client, kernel: test_kernel)
    engine.interface = :worker
    engine.session_state_dir = state_dir
    engine.session = Samagotchi::Session.load(session.id, state_dir: state_dir)
    @bridges << Samagotchi::Bridge.new(engine: engine, state_dir: state_dir, session_id: session.id, heartbeat_interval: 0.2).start
    @locks << Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(session.id, state_dir: state_dir), kind: "worker")
    engine
  end

  def in_thread(&)
    box = {}
    @threads << Thread.new { box[:value] = yield }
    box
  end

  def pending_of(session) = Samagotchi::Session.load(session.id, state_dir: state_dir).pending_question

  it "carries the parent user's answer down both hops, and names the chain on the parent's card" do
    top_engine = worker(top)
    middle_engine = worker(middle)
    leaf_engine = worker(leaf)

    leaf_answer = in_thread { leaf_engine.open_question(approval) }
    wait_until(timeout: 2) { pending_of(leaf) }

    middle_outcome = in_thread do
      Samagotchi::Tools::DelegateRelay.call(leaf.id, pending_of(leaf), relay: middle_engine.relay_peer, state_dir: state_dir)
    end
    wait_until(timeout: 2) { pending_of(middle)&.dig(:relay) }
    expect(pending_of(leaf)[:relayed_to]).to include("parent_id" => middle.id)

    top_outcome = in_thread do
      Samagotchi::Tools::DelegateRelay.call(middle.id, pending_of(middle), relay: top_engine.relay_peer, state_dir: state_dir)
    end
    card = wait_until(timeout: 2) { top_engine.pending_question }
    expect(card[:relay][:chain]).to eq([leaf.id[0, 8], middle.id[0, 8]])
    expect(card[:question]).to start_with("delegate #{middle.id[0, 8]} → #{leaf.id[0, 8]} (\"push the tag\") asks:\n  execute: git push --tags")
    expect(card[:options][1]).to eq("Allow this call for delegate #{middle.id[0, 8]} → #{leaf.id[0, 8]}'s session")

    top_engine.answer_question(id: card[:id], selected: [card[:options][0]])

    wait_until(timeout: 5) { leaf_answer.key?(:value) }
    expect(leaf_answer[:value]).to include(selected: ["Allow once"], selected_indices: [0])
    wait_until(timeout: 5) { top_outcome.key?(:value) && middle_outcome.key?(:value) }
    expect(middle_outcome[:value].line).to eq("approval relayed to your user: execute: git push --tags → allowed once")
    expect(top_outcome[:value].line).to eq("approval relayed to your user: execute: git push --tags → allowed once")
  end

  it "stops the chain where a hop goes: the middle's card closes and the leaf's question waits where it is" do
    top_engine = worker(top)
    middle_engine = worker(middle)
    leaf_engine = worker(leaf)
    in_thread { leaf_engine.open_question(approval) }
    wait_until(timeout: 2) { pending_of(leaf) }
    middle_outcome = in_thread do
      Samagotchi::Tools::DelegateRelay.call(leaf.id, pending_of(leaf), relay: middle_engine.relay_peer, state_dir: state_dir)
    end
    wait_until(timeout: 2) { pending_of(middle)&.dig(:relay) }
    top_outcome = in_thread do
      Samagotchi::Tools::DelegateRelay.call(middle.id, pending_of(middle), relay: top_engine.relay_peer, state_dir: state_dir)
    end
    wait_until(timeout: 2) { top_engine.pending_question }

    # The leaf is answered on its own: the middle's card closes, then the parent's.
    leaf_engine.answer_question(id: leaf_engine.pending_question[:id], selected: ["Deny"])
    wait_until(timeout: 5) { middle_outcome.key?(:value) && top_outcome.key?(:value) }
    expect(middle_outcome[:value].line).to end_with("→ answered on the child")
    expect(top_outcome[:value].line).to end_with("→ answered on the child")
  end
end
