# frozen_string_literal: true

require "timeout"
require "tmpdir"
require "json"
require "spec_helper"
require "samagotchi/tools/delegate_wait"
require "samagotchi/relay_desk"
require "samagotchi/owner_lock"
require "samagotchi/session_manager"

# DelegateWait with a relay: a child's approval goes to the parent's own
# question flow, the child is told through its Bridge (a fake here), and the
# parent's model sees only the outcome line.
RSpec.describe Samagotchi::Tools::DelegateWait, "approval relay" do
  let(:tmpdir) { Dir.mktmpdir("delegate-relay") }
  let(:locks) { [] }
  let(:parent) { make }
  let(:child) { make(parent_id: parent.id, prompt: "push the fix", status: "running", owner: true) }
  let(:cancelled) { [false] }
  let(:relay) { FakeRelay.new }
  let(:peers) do
    Samagotchi::Tools::Peers.new(session_id: parent.id, cwd: "/w", state_dir: tmpdir, cancelled: -> { cancelled[0] }, relay: relay)
  end
  let(:client) { FakeChild.new }
  let(:approval) do
    { id: "q1", kind: "approval", status: "pending", question: "execute: git push\n  why: publishes (rule git-push)",
      options: ["Allow once", "Allow this call for the session", "Deny"], multi_select: false, allow_freeform: true,
      approval: { tool: "execute", command: "git push", rule: "git-push", scopes: %w[once session] } }
  end

  # The parent's question flow: hands each card to the test's block, which
  # plays the user (an answer hash) or the watch (calls it until it closes).
  class FakeRelay
    attr_reader :cards, :relay_desk
    attr_accessor :answer

    def initialize
      @cards = []
      @relay_desk = Samagotchi::RelayDesk.new
    end

    def open_question(fields, watch:)
      @cards << fields
      answer.call(fields, watch)
    end
  end

  # The child's Bridge as BridgeClient sees it: records each relay POST and
  # answers with the status the test sets (and runs its on_answered).
  class FakeChild
    Response = Samagotchi::BridgeClient::Response
    attr_reader :posts
    attr_accessor :status, :on_answered

    def initialize
      @posts = []
      @status = 200
    end

    def relay(action:, relay_id:, question_id:, **extra)
      @posts << { action: action, relay_id: relay_id, question_id: question_id, **extra }
      on_answered&.call if action == "answered"
      Response.new(status: action == "answered" ? status : 200, body: status == 200 ? "{}" : %({"error":"x"}))
    end
  end

  before do
    stub_const("Samagotchi::Tools::DelegateWait::POLL_INTERVAL", 0.05)
    described_class.seen.clear
    described_class.baselines.clear
    allow(Samagotchi::BridgeClient).to receive(:discover).and_return(client)
  end

  after do
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
  end

  def make(prompt: "hello", parent_id: nil, status: nil, owner: false)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w", parent_id: parent_id).tap do |s|
      s.last_prompt = prompt
      s.status = status if status
      s.save(state_dir: tmpdir)
      locks << Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(s.id, state_dir: tmpdir), kind: "worker") if owner
    end
  end

  def update(session, **fields)
    s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
    fields.each { |name, value| s.public_send(:"#{name}=", value) }
    s.save(state_dir: tmpdir)
  end

  # The child takes the answer: its question goes, its turn ends with +reply+.
  def finish_child(reply = "pushed", after: 0.1)
    update(child, pending_question: nil)
    Thread.new do
      sleep(after)
      Samagotchi::SessionInbox.write_output(Samagotchi::Session.session_dir(child.id, state_dir: tmpdir), reply)
      update(child, status: "idle")
    end
  end

  def wait(timeout: 5) = Timeout.timeout(10) { described_class.call(child.id, peers: peers, timeout: timeout, owner_grace: 0.3) }

  def user_answers(label, index, freeform: nil)
    relay.answer = ->(fields, _watch) { { id: "pq", selected: [label], freeform: freeform, selected_indices: [index] } }
  end

  it "relays the approval to the parent's user and returns the child's reply with the outcome line" do
    update(child, pending_question: approval)
    user_answers("Allow once", 0)
    client.on_answered = -> { finish_child }

    expect(wait).to eq("session: #{child.id}\nstatus: answered\n" \
                       "approval relayed to your user: execute: git push → allowed once\n---\npushed")

    card = relay.cards.first
    expect(card).to include(kind: "approval", header: "Approve delegate #{child.id[0, 8]}'s tool call?")
    expect(card[:relay]).to include(child_id: child.id, child_question_id: "q1")
    expect(card[:question]).to start_with("delegate #{child.id[0, 8]} (\"push the fix\") asks:\n  execute: git push")
    expect(client.posts.map { |p| p[:action] }).to eq(%w[opened answered])
    relay_id = client.posts.first[:relay_id]
    expect(relay.relay_desk.status(relay_id)).to include(state: "answered", by: "user",
                                                         answer: { selected_indices: [0], freeform: nil, dismissed: false })
  end

  it "says denied with the user's reason, and a dismiss as dismissed (denied)" do
    update(child, pending_question: approval)
    user_answers("Deny", 2, freeform: "not on main")
    client.on_answered = -> { finish_child("ok, not pushing") }
    expect(wait).to include("approval relayed to your user: execute: git push → denied (\"not on main\")\n---\nok, not pushing")

    # A second approval in a later turn (the first reply was given).
    update(child, pending_question: approval.merge(id: "q2"), status: "running")
    relay.answer = ->(_fields, _watch) { { error: "no answer", id: "pq" } }
    client.on_answered = -> { finish_child("dropped it") }
    expect(wait).to include("→ dismissed (denied)\n---\ndropped it")
    expect(relay.relay_desk.status(client.posts.last[:relay_id])).to include(answer: { selected_indices: [], freeform: nil, dismissed: true })
  end

  it "records a parent agent's answer as one, so the child holds it to its own setting" do
    update(child, pending_question: approval)
    relay.answer = ->(_f, _w) { { id: "pq", selected: ["Allow once"], selected_indices: [0], by: "parent_agent" } }
    client.status = 403
    client.on_answered = -> { finish_child }
    expect(wait).to include("→ refused by the child (a parent agent may not allow it); it waits for the user there")
    expect(relay.relay_desk.status(client.posts.last[:relay_id])).to include(by: "parent_agent")
  end

  it "closes the card when the child is answered first, and says so" do
    update(child, pending_question: approval)
    relay.answer = lambda do |_fields, watch|
      expect(watch.call).to be_nil
      finish_child("answered there")
      { error: "cancelled", reason: watch.call, id: "pq" }
    end
    expect(wait).to eq("session: #{child.id}\nstatus: answered\n" \
                       "approval relayed to your user: execute: git push → answered on the child\n---\nanswered there")
    expect(client.posts.map { |p| p[:action] }).to eq(%w[opened])
  end

  it "says answered on the child when the child took another answer before the parent's (409)" do
    update(child, pending_question: approval)
    user_answers("Allow once", 0)
    client.status = 409
    client.on_answered = -> { finish_child }
    expect(wait).to include("→ answered on the child\n---\npushed")
  end

  it "closes the card when the child's worker is gone, and reports the worker gone" do
    update(child, pending_question: approval)
    relay.answer = lambda do |_fields, watch|
      locks.each(&:release)
      { error: "cancelled", reason: watch.call, id: "pq" }
    end
    expect(wait).to eq("session: #{child.id}\nstatus: worker_gone\n" \
                       "approval relayed to your user: execute: git push → not delivered (the child's worker is gone)\n" \
                       "the child's worker is gone (it stopped or crashed); delegate with session: #{child.id} starts it again with a message")
  end

  it "on a Stop leaves the child's question open, tells the child, and returns wait canceled" do
    update(child, pending_question: approval)
    relay.answer = ->(_f, _w) { { error: "cancelled", reason: "user", id: "pq" } }
    expect(wait).to eq("session: #{child.id}\nstatus: running\n" \
                       "approval relayed to your user: execute: git push → still open (your turn was stopped)\n" \
                       "wait canceled; the child keeps running; delegate_result #{child.id} waits again")
    expect(client.posts.last).to include(action: "closed", reason: "stopped")
    expect(Samagotchi::Session.load(child.id, state_dir: tmpdir).pending_question[:id]).to eq("q1")
  end

  it "closes the relay on the desk when the relay fails before it settles, so none stays open" do
    update(child, pending_question: approval)
    relay.answer = ->(_f, _w) { raise IOError, "question flow broke" }
    expect { wait }.to raise_error(IOError)
    relay_id = client.posts.first[:relay_id]
    expect(relay.relay_desk.status(relay_id)).to include(state: "closed")
  end

  it "waits on after the relay for a turn that ends with no reply, not until the timeout" do
    update(child, pending_question: approval)
    user_answers("Deny", 2)
    client.on_answered = lambda do
      update(child, pending_question: nil)
      Thread.new do
        sleep(0.1)
        update(child, status: "idle", last_turn: { "outcome" => "completed", "ended_at" => Time.now.iso8601(3) })
      end
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(wait(timeout: 30)).to include("status: no_answer\napproval relayed to your user: execute: git push → denied\n")
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
  end

  it "doesn't count the time the card was open against the timeout" do
    update(child, pending_question: approval)
    relay.answer = lambda do |_f, _w|
      sleep(1.3)
      { id: "pq", selected: ["Allow once"], selected_indices: [0] }
    end
    client.on_answered = -> { finish_child }
    expect(wait(timeout: 1)).to include("status: answered\napproval relayed to your user: execute: git push → allowed once\n---\npushed")
  end

  it "pauses the timeout during the relay, never starts it over" do
    Thread.new do
      sleep(0.7)
      update(child, pending_question: approval)
    end
    user_answers("Allow once", 0)
    client.on_answered = -> { finish_child(after: 0.6) }
    expect(wait(timeout: 1)).to include("status: running\napproval relayed to your user: execute: git push → allowed once\nno reply yet after 1 s")
  end

  describe "other running children's approvals while the parent waits (D2)" do
    let(:other) { make(parent_id: parent.id, prompt: "lint it", status: "running", owner: true) }

    before { stub_const("Samagotchi::Tools::DelegateRelay::OTHERS_EVERY", 0.05) }

    it "relays them too, and gives each outcome in that child's own next result" do
      update(other, pending_question: approval.merge(id: "o1", approval: approval[:approval].merge(command: "rm -rf tmp")))
      user_answers("Allow once", 0)
      client.on_answered = lambda do
        next unless client.posts.last[:question_id] == "o1"

        update(other, pending_question: nil)
        Thread.new do
          sleep(0.2)
          Samagotchi::SessionInbox.write_output(Samagotchi::Session.session_dir(child.id, state_dir: tmpdir), "child done")
          update(child, status: "idle")
        end
      end

      expect(wait).to eq("session: #{child.id}\nstatus: answered\n---\nchild done")
      expect(relay.cards.map { |c| c[:relay][:child_id] }).to eq([other.id])

      Samagotchi::SessionInbox.write_output(Samagotchi::Session.session_dir(other.id, state_dir: tmpdir), "linted")
      update(other, status: "idle")
      expect(described_class.call(other.id, peers: peers, timeout: 5)).to eq(
        "session: #{other.id}\nstatus: answered\napproval relayed to your user: execute: rm -rf tmp → allowed once\n---\nlinted"
      )
    end

    it "says on the card how many more delegates wait, one card at a time" do
      update(other, pending_question: approval.merge(id: "o1", created_at: "2026-01-01T00:00:01Z"))
      update(child, pending_question: approval.merge(created_at: "2026-01-01T00:00:02Z"))
      user_answers("Deny", 2)
      client.on_answered = lambda do
        posted = client.posts.last[:question_id]
        if posted == "q1"
          finish_child
        else
          update(other, pending_question: nil)
        end
      end

      expect(wait).to include("approval relayed to your user: execute: git push → denied\n---\npushed")
      expect(relay.cards.first[:header]).to end_with("(+1 more delegate waiting)")
      expect(relay.cards.first[:relay][:child_id]).to eq(child.id)
    end
  end

  it "keeps today's path for the model's own questions, and without a relay" do
    update(child, pending_question: { id: "q1", question: "Which one?", options: %w[A B] })
    expect(wait).to include("status: question\nChild #{child.id} is waiting for an answer (question): Which one?")

    update(child, pending_question: approval)
    plain = Samagotchi::Tools::Peers.new(session_id: parent.id, state_dir: tmpdir, cancelled: false)
    expect(described_class.call(child.id, peers: plain, timeout: 5)).to include("waiting for an answer (approval)")
    expect(relay.cards).to be_empty
  end
end
