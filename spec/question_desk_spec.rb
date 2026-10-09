# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/question_desk"
require "samagotchi/session"
require "samagotchi/cancellation_controller"

# QuestionDesk on its own: the seams the approval relay builds on (a watch
# that closes an open question, who answered, a relay marker).
RSpec.describe Samagotchi::QuestionDesk do
  let(:tmpdir) { Dir.mktmpdir("question-desk") }
  let(:events) { [] }
  let(:inputs) { [] }
  let(:controller) { [nil] }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w").tap { |s| s.save(state_dir: tmpdir) }
  end
  let(:desk) do
    described_class.new(session: -> { session }, state_dir: -> { tmpdir }, emit: ->(e) { events << e },
                        cancel_controller: -> { controller[0] }, interface: -> { :worker },
                        user_input: ->(sid) { inputs << sid })
  end
  let(:fields) { { question: "Run it?", options: %w[Yes No], multi_select: false, allow_freeform: true } }

  before { stub_const("Samagotchi::QuestionDesk::WATCH_INTERVAL", 0.02) }
  after { FileUtils.rm_rf(tmpdir) }

  def open_in_background(**opts)
    box = {}
    thread = Thread.new { box[:answer] = desk.open_question(fields, **opts) }
    thread.report_on_exception = false
    # Past a standing question pending before it.
    wait_until(timeout: 2) { desk.pending && desk.pending[:kind] != "continue" }
    [thread, box, desk.pending[:id]]
  end

  def saved = Samagotchi::Session.load(session.id, state_dir: tmpdir).pending_question

  describe "#open_question watch:" do
    it "closes the question with the reason the watch returns, announced as a cancel" do
      calls = 0
      thread, box, id = open_in_background(watch: -> { (calls += 1) >= 3 ? "child_gone" : nil })
      thread.join(2)

      expect(box[:answer]).to eq(error: "cancelled", reason: "child_gone", id: id)
      expect(events.last).to eq(type: :question_cancelled, id: id, reason: "child_gone")
      expect(desk.pending).to be_nil
      expect(saved).to be_nil
    end

    it "is called no more often than WATCH_INTERVAL" do
      stub_const("Samagotchi::QuestionDesk::WATCH_INTERVAL", 0.2)
      calls = 0
      thread, box, id = open_in_background(watch: -> { calls += 1; nil })
      sleep(0.5)
      desk.answer(id: id, selected: ["Yes"])
      thread.join(2)

      expect(box[:answer]).to include(selected: ["Yes"])
      expect(calls).to be_between(2, 4)
    end

    it "lets an answer recorded first win over a watch close" do
      box = {}
      gate = Queue.new
      watch = lambda do
        gate.pop
        "child_gone"
      end
      thread = Thread.new { box[:answer] = desk.open_question(fields, watch: watch) }
      wait_until(timeout: 2) { desk.pending }
      desk.answer(id: desk.pending[:id], selected: ["No"])
      gate << :go
      thread.join(2)

      expect(box[:answer]).to include(selected: ["No"], selected_indices: [1])
      expect(events.map { |e| e[:type] }).not_to include(:question_cancelled)
    end

    it "keeps a watch that raises from closing anything" do
      thread, box, id = open_in_background(watch: -> { raise "boom" })
      sleep(0.1)
      desk.answer(id: id, selected: ["Yes"])
      thread.join(2)
      expect(box[:answer]).to include(selected: ["Yes"])
    end

    it "without a watch waits as before, and a Stop still cancels with its reason" do
      ctrl = Samagotchi::CancellationController.new
      controller[0] = ctrl
      thread, box, id = open_in_background
      ctrl.cancel!(:user)
      thread.join(2)
      expect(box[:answer]).to eq(error: "cancelled", reason: "user", id: id)
    end
  end

  describe "#answer parent_agent:" do
    let(:fields) do
      { question: "execute: x", options: ["Allow once", "Deny"], multi_select: false, allow_freeform: true,
        kind: "approval", approval: { tool: "execute", scopes: ["once"] } }
    end

    before do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("guardrails.parent_approvals").and_return("off")
    end

    it "holds an answer marked parent_agent to the setting, whatever its client id" do
      thread, box, id = open_in_background
      expect { desk.answer(id: id, selected: ["Allow once"], client_id: "relay:ab12cd34", parent_agent: true) }
        .to raise_error(Samagotchi::QuestionDesk::Refused)

      desk.answer(id: id, selected: ["Deny"], client_id: "relay:ab12cd34", parent_agent: true)
      thread.join(2)
      expect(box[:answer]).to include(selected: ["Deny"], by: "parent_agent")
      # A parent agent's answer doesn't bring the session back to the lists.
      expect(inputs).to be_empty
    end

    it "takes chi answer's client id as a parent agent by default, and a user's answer as before" do
      thread, _box, id = open_in_background
      expect { desk.answer(id: id, selected: ["Allow once"], client_id: "cli:answer") }
        .to raise_error(Samagotchi::QuestionDesk::Refused)

      answer = desk.answer(id: id, selected: ["Allow once"], client_id: "relay:ab12cd34", parent_agent: false)
      thread.join(2)
      expect(answer).to eq(id: id, selected: ["Allow once"], freeform: nil, selected_indices: [0])
      expect(inputs).to eq([session.id])
    end
  end

  # The REPL answers on the turn thread: a handler may return the tool
  # result's text itself.
  describe "a sync handler that returns text" do
    it "returns the text and leaves no question pending, in memory or the session file" do
      desk.sync_handler = ->(_pending) { "answered inline" }

      expect(desk.open_question(fields)).to eq("answered inline")
      expect(desk.pending).to be_nil
      expect(saved).to be_nil
    end

    it "announces the question answered, the text as its freeform" do
      desk.sync_handler = ->(_pending) { "answered inline" }
      desk.open_question(fields)

      id = events.first[:pending_question][:id]
      expect(events.last).to eq(type: :question_answered, id: id,
                                answer: { id: id, selected: [], freeform: "answered inline", selected_indices: [] })
    end
  end

  describe "#annotate" do
    it "sets and clears the pending question's relay marker, saved and announced" do
      thread, _box, id = open_in_background
      marker = { parent_id: "p-1", parent_short: "p-1", relay_id: "r-1" }

      expect(desk.annotate(id, relayed_to: marker)).to be(true)
      expect(desk.pending[:relayed_to]).to eq(marker)
      # Session.load leaves nested keys as strings.
      expect(saved[:relayed_to]).to eq(marker.transform_keys(&:to_s))
      expect(events.last).to eq(type: :question_relay, id: id, relayed_to: marker)

      expect(desk.annotate(id, relayed_to: nil, reason: "parent_gone")).to be(true)
      expect(desk.pending).not_to have_key(:relayed_to)
      expect(saved).not_to have_key(:relayed_to)
      expect(events.last).to eq(type: :question_relay, id: id, relayed_to: nil, reason: "parent_gone")

      desk.answer(id: id, selected: ["Yes"])
      thread.join(2)
    end

    it "does nothing for a question that isn't the one pending, or is answered" do
      thread, _box, id = open_in_background
      expect(desk.annotate("other", relayed_to: { relay_id: "r" })).to be(false)
      desk.answer(id: id, selected: ["Yes"])
      expect(desk.annotate(id, relayed_to: { relay_id: "r" })).to be(false)
      thread.join(2)
      expect(events.map { |e| e[:type] }).not_to include(:question_relay)
    end
  end

  describe "a standing question (#post, the step-limit question)" do
    let(:continue_fields) do
      { kind: "continue", header: "Step limit", question: "Continue it?", options: %w[Continue Stop],
        multi_select: false, allow_freeform: true, limit: 3 }
    end
    let(:answers) { [] }
    let(:on_answer) { ->(answer, client_id:) { answers << [answer, client_id] } }

    it "is pending, saved and announced as standing, and blocks no one" do
      pending = desk.post(continue_fields, on_answer: on_answer)

      expect(desk.pending).to include(id: pending[:id], kind: "continue", limit: 3, status: "pending")
      expect(saved).to include(id: pending[:id], kind: "continue")
      expect(events.last).to include(type: :question_requested, standing: true)
    end

    it "hands an answer to on_answer with who answered, after it is cleared and announced" do
      id = desk.post(continue_fields, on_answer: lambda { |answer, client_id:|
        answers << [answer, client_id, desk.pending, events.last[:type]]
      })[:id]

      result = desk.answer(id: id, selected: ["Stop"], freeform: "enough", client_id: "web:1")

      expect(result).to include(selected: ["Stop"], freeform: "enough")
      expect(answers).to eq([[result, "web:1", nil, :question_answered]])
      expect(saved).to be_nil
      expect(inputs).to eq([session.id])
      expect { desk.answer(id: id, selected: ["Continue"]) }.to raise_error(described_class::NotPending)
    end

    it "doesn't bring the session back to the lists on a parent agent's answer" do
      id = desk.post(continue_fields, on_answer: on_answer)[:id]
      desk.answer(id: id, selected: ["Stop"], client_id: "cli:answer")

      expect(answers.map(&:last)).to eq(["cli:answer"])
      expect(inputs).to be_empty
    end

    it "refuses a parent agent's Continue with turn.parent_continue: false, and takes its Stop" do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("turn.parent_continue").and_return(false)
      id = desk.post(continue_fields, on_answer: on_answer)[:id]

      expect { desk.answer(id: id, selected: ["Continue"], client_id: "cli:answer") }
        .to raise_error(described_class::Refused) { |e| expect(e.reason).to eq(:stop_only) }
      expect(desk.pending).to include(id: id)
      # A person's Continue is theirs to give.
      desk.answer(id: id, selected: ["Continue"], client_id: "web:1")
      expect(answers.map(&:last)).to eq(["web:1"])
    end

    it "lets a parent agent Continue by default (turn.parent_continue: true)" do
      id = desk.post(continue_fields, on_answer: on_answer)[:id]
      desk.answer(id: id, selected: ["Continue"], client_id: "cli:answer")
      expect(answers.map(&:last)).to eq(["cli:answer"])
    end

    it "takes Continue with a text, handed to the poster as the answer's freeform" do
      id = desk.post(continue_fields, on_answer: on_answer)[:id]

      answer = desk.answer(id: id, selected: ["Continue"], freeform: "  and also check X ", client_id: "web:1")

      expect(answer).to include(selected: ["Continue"], freeform: "and also check X")
      expect(answers.first.first).to include(selected: ["Continue"], freeform: "and also check X")
      expect(desk.pending).to be_nil
    end

    it "marks a parent agent's Continue with a text, so the poster can label the steer" do
      id = desk.post(continue_fields, on_answer: on_answer)[:id]

      desk.answer(id: id, selected: ["Continue"], freeform: "and also", client_id: "cli:answer")

      expect(answers.first.first).to include(freeform: "and also", by: "parent_agent")
    end

    it "still takes Stop with a text" do
      id = desk.post(continue_fields, on_answer: on_answer)[:id]

      desk.answer(id: id, selected: ["Stop"], freeform: "enough", client_id: "web:1")

      expect(answers.first.first).to include(selected: ["Stop"], freeform: "enough")
    end

    it "can't be dismissed: a UI's dismiss raises, a cancel with no id leaves it" do
      id = desk.post(continue_fields, on_answer: on_answer)[:id]

      expect { desk.cancel("dismissed", id: id) }.to raise_error(described_class::NotDismissable)
      expect(desk.cancel("user")).to be(false)
      expect(desk.pending).to include(id: id)
    end

    it "is withdrawn by its poster, announced with the reason" do
      id = desk.post(continue_fields, on_answer: on_answer)[:id]

      expect(desk.withdraw("dropped", id: "other")).to be(false)
      expect(desk.withdraw("dropped")).to be(true)
      expect(desk.pending).to be_nil
      expect(saved).to be_nil
      expect(events.last).to eq(type: :question_cancelled, id: id, reason: "dropped")
      expect(desk.withdraw("dropped")).to be(false)
    end

    it "gives way to a question opened meanwhile (superseded) and is offered again once that closes" do
      reposts = []
      id = desk.post(continue_fields, on_answer: on_answer, on_superseded_close: -> { reposts << desk.pending })[:id]

      thread, box, other = open_in_background
      expect(events.find { |e| e[:type] == :question_cancelled }).to eq(type: :question_cancelled, id: id, reason: "superseded")
      expect(desk.pending).to include(id: other, question: "Run it?")
      expect(reposts).to be_empty

      desk.answer(id: other, selected: ["Yes"])
      thread.join(2)
      expect(box[:answer]).to include(selected: ["Yes"])
      expect(reposts).to eq([nil])
    end

    it "is posted again as it was when it has no on_superseded_close" do
      desk.post(continue_fields, on_answer: on_answer)
      thread, _box, other = open_in_background
      desk.answer(id: other, selected: ["No"])
      thread.join(2)

      expect(desk.pending).to include(kind: "continue", status: "pending")
      desk.answer(id: desk.pending[:id], selected: ["Continue"], client_id: "tui:1")
      expect(answers.map(&:last)).to eq(["tui:1"])
    end

    it "waits for a question open as it is posted, then goes up" do
      thread, _box, other = open_in_background
      expect(desk.post(continue_fields, on_answer: on_answer)).to be_nil
      expect(desk.pending).to include(id: other)

      desk.answer(id: other, selected: ["Yes"])
      thread.join(2)
      expect(desk.pending).to include(kind: "continue")
    end

    it "isn't offered again once withdrawn while shelved" do
      desk.post(continue_fields, on_answer: on_answer)
      thread, _box, other = open_in_background
      desk.withdraw("dropped")
      desk.answer(id: other, selected: ["Yes"])
      thread.join(2)

      expect(desk.pending).to be_nil
    end
  end
end
