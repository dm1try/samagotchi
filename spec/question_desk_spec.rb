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
    wait_until(timeout: 2) { desk.pending }
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
end
