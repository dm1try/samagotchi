# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "support/test_kernel"

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/bridge"
require "samagotchi/bridge_client"

# The approval relay's Bridge routes, between two real workers' Bridges in
# one state dir: the child's POST relay (opened, closed, answered) and the
# parent's POST relay/status, which the child asks before it believes an
# answer.
RSpec.describe Samagotchi::Bridge, "approval relay" do
  let(:state_dir) { Dir.mktmpdir("bridge-relay") }
  let(:parent) { new_session }
  let(:child) { new_session(parent_id: parent.id) }
  let(:parent_engine) { Samagotchi::Engine.new(client: test_client, kernel: test_kernel) }
  let(:child_engine) do
    Samagotchi::Engine.new(client: test_client, kernel: test_kernel).tap do |engine|
      engine.session_state_dir = state_dir
      engine.session = child
    end
  end
  let(:events) { [] }
  let(:approval) do
    { question: "execute: git push", options: ["Allow once", "Allow this call for the session", "Deny"],
      header: "Approve tool call?", multi_select: false, allow_freeform: true, kind: "approval",
      approval: { tool: "execute", command: "git push", scopes: %w[once session] } }
  end

  before do
    WebMock.allow_net_connect! if defined?(WebMock)
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("guardrails.parent_approvals").and_return("off")
    @bridges = []
  end

  after do
    @bridges.each(&:stop)
    @threads&.each { |t| t.kill if t.alive? }
    WebMock.disable_net_connect! if defined?(WebMock)
    FileUtils.rm_rf(state_dir)
  end

  def new_session(parent_id: nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd, parent_id: parent_id)
                       .tap { |s| s.save(state_dir: state_dir) }
  end

  def serve(engine, session)
    bridge = described_class.new(engine: engine, state_dir: state_dir, session_id: session.id, heartbeat_interval: 0.2).start
    @bridges << bridge
    bridge
  end

  def client_for(session)
    Samagotchi::BridgeClient.discover(session.id, session_dir: Samagotchi::Session.session_dir(session.id, state_dir: state_dir))
  end

  # The child's approval, waiting on its turn thread.
  def ask_child(fields = approval)
    box = {}
    child_engine.subscribe(observer: ->(e) { events << e })
    (@threads ||= []) << Thread.new { box[:answer] = child_engine.open_question(fields) }
    wait_until(timeout: 2) { child_engine.pending_question }
    [box, child_engine.pending_question[:id]]
  end

  def saved_question = Samagotchi::Session.load(child.id, state_dir: state_dir).pending_question

  def relay(action, relay_id, qid, **extra)
    client_for(child).relay(action: action, relay_id: relay_id, question_id: qid, **extra)
  end

  describe "opened / closed" do
    before { serve(child_engine, child) }

    it "marks the child's question as waiting in the parent, saved and announced, and clears it on closed" do
      _box, qid = ask_child

      expect(relay("opened", "r-1", qid).status).to eq(200)
      marker = { parent_id: parent.id, parent_short: parent.id[0, 8], relay_id: "r-1" }
      expect(child_engine.pending_question[:relayed_to]).to eq(marker)
      expect(saved_question[:relayed_to]).to eq(marker.transform_keys(&:to_s))
      expect(events.last).to include(type: :question_relay, id: qid, relayed_to: marker)

      # Another relay's close, or a reason it doesn't know, changes nothing / is "closed".
      expect(relay("closed", "r-other", qid).status).to eq(409)
      expect(relay("closed", "r-1", qid, reason: "made up").status).to eq(200)
      expect(child_engine.pending_question).not_to have_key(:relayed_to)
      expect(events.last).to include(type: :question_relay, id: qid, relayed_to: nil, reason: "closed")
    end

    it "keeps the marker on the cards' open question (a joining UI's)" do
      cards = @bridges.first.instance_variable_get(:@cards)
      # A question is a row of a running turn.
      cards.call({ type: :turn_started })
      _box, qid = ask_child
      relay("opened", "r-1", qid)
      card = wait_until(timeout: 2) { cards.list.find { |e| e[:type] == :question && e[:pending_question][:relayed_to] } }
      expect(card[:pending_question][:relayed_to]).to include(relay_id: "r-1")
    end

    it "clears the mark (parent_gone) when the parent's worker isn't up, the question still open" do
      stub_const("Samagotchi::RelayWatcher::INTERVAL", 0.05)
      _box, qid = ask_child
      relay("opened", "r-1", qid)

      wait_until(timeout: 2) { !child_engine.pending_question.key?(:relayed_to) }
      expect(child_engine.pending_question).to include(id: qid, status: "pending")
      expect(child_engine.pending_question).not_to have_key(:relayed_to)
      # The event follows the mark's clearing: wait for it too.
      wait_until(timeout: 2) { events.last&.dig(:reason) == "parent_gone" }
      expect(events.last).to include(type: :question_relay, id: qid, relayed_to: nil, reason: "parent_gone")
    end

    it "ends its relay watchers when it stops" do
      _box, qid = ask_child
      relay("opened", "r-1", qid)
      watchers = @bridges.first.instance_variable_get(:@relay_watchers)
      expect(watchers.size).to eq(1)

      @bridges.first.stop

      expect(watchers.first).not_to be_alive
    end

    it "answers 409 for a question not pending, 422 in a session with no parent, 400 for a bad request" do
      _box, qid = ask_child
      expect(relay("opened", "r-1", "other").status).to eq(409)
      expect(client_for(child).relay(action: "nope", relay_id: "r", question_id: qid).status).to eq(400)
      expect(client_for(child).relay(action: "opened", relay_id: "", question_id: qid).status).to eq(400)

      orphan = new_session
      orphan_engine = Samagotchi::Engine.new(client: test_client, kernel: test_kernel)
      serve(orphan_engine, orphan)
      expect(client_for(orphan).relay(action: "opened", relay_id: "r", question_id: "q").status).to eq(422)
    end
  end

  describe "relay/status (the parent's)" do
    before { serve(parent_engine, parent) }

    it "reports what the parent's relay holds, 404 for one it doesn't know" do
      id = parent_engine.relay_desk.open(child_id: child.id, child_question_id: "q-1")
      parent_engine.relay_desk.record(id, selected_indices: [0], freeform: nil, by: "user")

      response = client_for(parent).relay_status(id)
      expect(response.status).to eq(200)
      expect(response.json).to eq("child_id" => child.id, "child_question_id" => "q-1", "state" => "answered",
                                  "answer" => { "selected_indices" => [0], "freeform" => nil, "dismissed" => false },
                                  "by" => "user")
      expect(client_for(parent).relay_status("nope").status).to eq(404)
    end
  end

  describe "answered: the child asks its parent" do
    before do
      serve(parent_engine, parent)
      serve(child_engine, child)
    end

    def parent_relay(qid, child_id: child.id, indices: [0], by: "user", freeform: nil, dismissed: false, record: true)
      id = parent_engine.relay_desk.open(child_id: child_id, child_question_id: qid)
      parent_engine.relay_desk.record(id, selected_indices: indices, freeform: freeform, dismissed: dismissed, by: by) if record
      id
    end

    it "takes the user's answer by index, as the child's own option, recorded as the relay's" do
      box, qid = ask_child
      relay_id = parent_relay(qid, indices: [1])

      response = relay("answered", relay_id, qid)
      expect(response.status).to eq(200)
      @threads.last.join(2)
      expect(box[:answer]).to include(selected: ["Allow this call for the session"], selected_indices: [1])
      expect(box[:answer]).not_to have_key(:by)
    end

    it "takes a deny with the user's reason, and a dismiss as a cancel (the approval denied)" do
      box, qid = ask_child
      expect(relay("answered", parent_relay(qid, indices: [2], freeform: "not on main"), qid).status).to eq(200)
      @threads.last.join(2)
      expect(box[:answer]).to include(selected: ["Deny"], freeform: "not on main")

      box, qid = ask_child
      expect(relay("answered", parent_relay(qid, indices: [], dismissed: true), qid).status).to eq(200)
      @threads.last.join(2)
      expect(box[:answer]).to include(error: "no answer")
    end

    it "holds a parent agent's answer to the child's own guardrails.parent_approvals (403, still open)" do
      _box, qid = ask_child
      response = relay("answered", parent_relay(qid, indices: [0], by: "parent_agent"), qid)
      expect(response.status).to eq(403)
      expect(response.json).to include("error" => "parent_approval_refused", "reason" => "off")
      expect(child_engine.pending_question[:id]).to eq(qid)

      expect(relay("answered", parent_relay(qid, indices: [2], by: "parent_agent"), qid).status).to eq(200)
    end

    it "refuses even Allow once from a parent agent on chi's own config, whatever the setting" do
      allow(Samagotchi::Config).to receive(:get).with("guardrails.parent_approvals").and_return("once")
      _box, qid = ask_child(approval.merge(approval: approval[:approval].merge(rule: "chi-config")))
      response = relay("answered", parent_relay(qid, indices: [0], by: "parent_agent"), qid)
      expect([response.status, response.json["reason"]]).to eq([403, "protected"])
    end

    it "believes nothing the parent doesn't hold for this child, this question, answered (422, still open)" do
      _box, qid = ask_child
      unanswered = parent_relay(qid, record: false)
      stranger = parent_relay(qid, child_id: "someone-else")
      other_question = parent_relay("q-old")
      out_of_range = parent_relay(qid, indices: [7])

      [unanswered, stranger, "no-such-relay", out_of_range].each do |relay_id|
        expect(relay("answered", relay_id, qid).status).to eq(422), relay_id
      end
      expect(relay("answered", other_question, qid).status).to eq(422)
      expect(child_engine.pending_question[:id]).to eq(qid)
    end

    it "answers 409 for a replayed relay of an earlier question, or one answered on the child first" do
      box, qid = ask_child
      relay_id = parent_relay(qid)
      child_engine.answer_question(id: qid, selected: ["Deny"])
      @threads.last.join(2)
      expect(box[:answer]).to include(selected: ["Deny"])

      _box, _next_qid = ask_child
      expect(relay("answered", relay_id, qid).status).to eq(409)
    end

    it "believes nothing once the parent's worker is gone (422, still open)" do
      _box, qid = ask_child
      relay_id = parent_relay(qid)
      @bridges.first.stop
      expect(relay("answered", relay_id, qid).status).to eq(422)
      expect(child_engine.pending_question[:id]).to eq(qid)
    end
  end
end
