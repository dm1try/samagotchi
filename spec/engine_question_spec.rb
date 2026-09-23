# frozen_string_literal: true

require "json"
require "samagotchi/engine"
require "samagotchi/session"

# Covers the cross-thread ask_user_question path used by the Web UI / Bridge:
# Engine#request_question blocks the turn thread until Engine#answer_question
# is called from another thread (or the turn is cancelled).
RSpec.describe "Engine ask_user_question (cross-thread path)" do
  around do |example|
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    original_thinking = ENV["THINKING_MODE"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    ENV["THINKING_MODE"] = "false"
    example.run
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
    ENV["THINKING_MODE"] = original_thinking
  end

  let(:client) { instance_double(Samagotchi::Client) }
  let(:kernel) { instance_double(Samagotchi::KernelLoop) }

  let(:payload) do
    {
      question: "Which option?",
      options: %w[Cats Dogs],
      header: "Pet preference",
      multi_select: false,
      allow_freeform: false
    }
  end

  def build_engine(session: nil)
    engine = Samagotchi::Engine.new(mode: :assist, client: client, kernel: kernel)
    engine.session = session if session
    engine
  end

  # Runs request_question on a turn-like thread and yields the engine so the
  # caller can answer from "the UI thread" once the question event arrives.
  def request_in_background(engine, payload)
    events = []
    engine.subscribe(observer: ->(e) { events << e })
    result_box = {}
    turn_thread = Thread.new do
      result_box[:result] = engine.request_question(payload)
    rescue StandardError => e
      result_box[:error] = e
    end
    turn_thread.report_on_exception = false
    # Wait until the question is pending (question_requested emitted)
    deadline = mono + 2.0
    sleep(0.005) while engine.pending_question.nil? && mono < deadline
    [turn_thread, result_box, events]
  end

  def mono
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  describe "Engine#request_question / #answer_question" do
    it "emits question_requested with the normalized pending payload" do
      engine = build_engine
      turn_thread, result_box, events = request_in_background(engine, payload)

      pending = engine.pending_question
      expect(pending).not_to be_nil
      expect(pending[:question]).to eq("Which option?")
      expect(pending[:options]).to eq(%w[Cats Dogs])
      expect(pending[:header]).to eq("Pet preference")
      expect(pending[:multi_select]).to eq(false)
      expect(pending[:status]).to eq("pending")
      expect(pending[:id]).to be_a(String)

      requested = events.find { |e| e[:type] == :question_requested }
      expect(requested).not_to be_nil
      expect(requested[:pending_question][:id]).to eq(pending[:id])

      engine.answer_question(id: pending[:id], selected: ["Cats"])
      turn_thread.join(2)
      expect(result_box[:error]).to be_nil
    end

    it "strips wire control tokens from question, options, and header" do
      engine = build_engine
      dirty = payload.merge(
        question: "<|channel|>Which option?<|",
        options: ["|>Cats<|", "|>Dogs<|"],
        header: "<|tool_call|>Pet preference|>"
      )
      turn_thread, result_box, _events = request_in_background(engine, dirty)

      pending = engine.pending_question
      expect(pending[:question]).to eq("Which option?")
      expect(pending[:options]).to eq(%w[Cats Dogs])
      expect(pending[:header]).to eq("Pet preference")

      engine.answer_question(id: pending[:id], selected: ["Cats"])
      turn_thread.join(2)
      expect(result_box[:error]).to be_nil
    end

    it "persists pending_question to the session and clears it after answering" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd)
      allow(session).to receive(:save)
      engine = build_engine(session: session)
      turn_thread, _result_box, _events = request_in_background(engine, payload)

      expect(session.pending_question).not_to be_nil
      expect(session.pending_question[:question]).to eq("Which option?")

      engine.answer_question(id: session.pending_question[:id], selected: ["Dogs"])
      turn_thread.join(2)
      expect(session.pending_question).to be_nil
    end

    it "blocks until answer_question is called from another thread and returns answer JSON" do
      engine = build_engine
      turn_thread, result_box, events = request_in_background(engine, payload)
      qid = engine.pending_question[:id]

      engine.answer_question(id: qid, selected: ["Dogs"], freeform: nil)
      turn_thread.join(2)

      expect(result_box[:error]).to be_nil
      answer = JSON.parse(result_box[:result])
      expect(answer["id"]).to eq(qid)
      expect(answer["selected"]).to eq(["Dogs"])
      expect(answer["freeform"]).to be_nil
      expect(answer["selected_indices"]).to eq([1])

      answered = events.find { |e| e[:type] == :question_answered }
      expect(answered).not_to be_nil
      expect(answered[:id]).to eq(qid)
    end

    it "returns a cancelled error payload when the turn is cancelled while pending" do
      engine = build_engine
      ctrl = Samagotchi::Client::CancellationController.new
      engine.instance_variable_set(:@active_cancel_controller, ctrl)

      events = []
      engine.subscribe(observer: ->(e) { events << e })
      result_box = {}
      turn_thread = Thread.new do
        result_box[:result] = engine.request_question(payload)
      end
      turn_thread.report_on_exception = false
      deadline = mono + 2.0
      sleep(0.005) while engine.pending_question.nil? && mono < deadline

      ctrl.cancel!(:user)
      turn_thread.join(2)

      answer = JSON.parse(result_box[:result])
      expect(answer["error"]).to eq("cancelled")
      expect(answer["reason"]).to eq("user")
      expect(engine.pending_question).to be_nil

      cancelled = events.find { |e| e[:type] == :question_cancelled }
      expect(cancelled).not_to be_nil
    end

    it "cancel_question names the question it cancelled, and announces nothing with none pending" do
      engine = build_engine
      events = []
      engine.subscribe(observer: ->(e) { events << e })
      engine.cancel_question("user")
      expect(events.map { |e| e[:type] }).not_to include(:question_cancelled)

      turn_thread = Thread.new { engine.request_question(payload) }
      turn_thread.report_on_exception = false
      deadline = mono + 2.0
      sleep(0.005) while engine.pending_question.nil? && mono < deadline
      id = engine.pending_question[:id]

      engine.cancel_question("user")
      turn_thread.join(2)

      cancelled = events.select { |e| e[:type] == :question_cancelled }
      expect(cancelled.map { |e| e.slice(:id, :reason) }).to eq([{ id: id, reason: "user" }])
    end

    it "returns an error payload without blocking for an empty question" do
      engine = build_engine
      result = engine.request_question(question: "", options: %w[A B])
      expect(JSON.parse(result)["error"]).to eq("invalid question")
      expect(engine.pending_question).to be_nil
    end

    it "returns an error payload without blocking when options are missing" do
      engine = build_engine
      result = engine.request_question(question: "Pick", options: [])
      expect(JSON.parse(result)["error"]).to eq("invalid question")
      expect(engine.pending_question).to be_nil
    end
  end

  describe "Engine#answer_question validation" do
    it "raises when there is no pending question" do
      engine = build_engine
      expect { engine.answer_question(id: "q-1", selected: ["A"]) }
        .to raise_error(ArgumentError, /no pending question/)
    end

    it "raises on id mismatch" do
      engine = build_engine
      turn_thread, _box, _events = request_in_background(engine, payload)
      expect { engine.answer_question(id: "wrong-id", selected: ["Cats"]) }
        .to raise_error(ArgumentError, /id mismatch/)
      engine.answer_question(id: engine.pending_question[:id], selected: ["Cats"])
      turn_thread.join(2)
    end

    it "raises when the selection is not a subset of the options" do
      engine = build_engine
      turn_thread, _box, _events = request_in_background(engine, payload)
      expect { engine.answer_question(id: engine.pending_question[:id], selected: ["Birds"]) }
        .to raise_error(ArgumentError, /invalid selection/)
      engine.answer_question(id: engine.pending_question[:id], selected: ["Cats"])
      turn_thread.join(2)
    end

    it "raises when multiple selections are given for a single-select question" do
      engine = build_engine
      turn_thread, _box, _events = request_in_background(engine, payload)
      expect { engine.answer_question(id: engine.pending_question[:id], selected: %w[Cats Dogs]) }
        .to raise_error(ArgumentError, /single-select/)
      engine.answer_question(id: engine.pending_question[:id], selected: ["Cats"])
      turn_thread.join(2)
    end

    it "raises when neither selection nor freeform is provided" do
      engine = build_engine
      turn_thread, _box, _events = request_in_background(engine, payload)
      expect { engine.answer_question(id: engine.pending_question[:id], selected: [], freeform: nil) }
        .to raise_error(ArgumentError, /selection required/)
      engine.answer_question(id: engine.pending_question[:id], selected: ["Cats"])
      turn_thread.join(2)
    end

    it "accepts multiple selections for a multi-select question" do
      engine = build_engine
      turn_thread, result_box, _events = request_in_background(engine, payload.merge(multi_select: true))
      engine.answer_question(id: engine.pending_question[:id], selected: %w[Cats Dogs])
      turn_thread.join(2)

      answer = JSON.parse(result_box[:result])
      expect(answer["selected"]).to eq(%w[Cats Dogs])
      expect(answer["selected_indices"]).to eq([0, 1])
    end

    it "accepts freeform-only answers when allow_freeform is set" do
      engine = build_engine
      turn_thread, result_box, _events = request_in_background(engine, payload.merge(allow_freeform: true))
      engine.answer_question(id: engine.pending_question[:id], selected: [], freeform: "Something else")
      turn_thread.join(2)

      answer = JSON.parse(result_box[:result])
      expect(answer["selected"]).to eq([])
      expect(answer["freeform"]).to eq("Something else")
    end
  end

  describe "first responder wins (several UIs answering the same question)" do
    it "rejects a second answer that lands before the turn thread clears the question" do
      engine = build_engine
      turn_thread, result_box, _events = request_in_background(engine, payload)
      qid = engine.pending_question[:id]

      # Hold the question lock across both answers: this is exactly the window
      # between the first answer and the turn thread clearing @pending_question.
      engine.instance_variable_get(:@question_mutex).synchronize do
        engine.answer_question(id: qid, selected: ["Cats"])
        expect { engine.answer_question(id: qid, selected: ["Dogs"]) }
          .to raise_error(Samagotchi::Engine::QuestionNotPending, /already answered/)
      end
      turn_thread.join(2)

      expect(JSON.parse(result_box[:result])["selected"]).to eq(["Cats"])
    end

    it "rejects an answer to a cancelled question" do
      engine = build_engine
      turn_thread, _result_box, _events = request_in_background(engine, payload)
      qid = engine.pending_question[:id]

      engine.instance_variable_get(:@question_mutex).synchronize do
        engine.cancel_question("other client")
        expect { engine.answer_question(id: qid, selected: ["Cats"]) }
          .to raise_error(Samagotchi::Engine::QuestionNotPending, /cancelled/)
      end
      turn_thread.join(2)
    end

    it "doesn't cancel a question once an answer is recorded (the answer wins, nothing is announced)" do
      engine = build_engine
      turn_thread, result_box, events = request_in_background(engine, payload)
      qid = engine.pending_question[:id]

      cancelled = nil
      engine.instance_variable_get(:@question_mutex).synchronize do
        engine.answer_question(id: qid, selected: ["Cats"])
        cancelled = engine.cancel_question("dismissed", id: qid)
      end
      turn_thread.join(2)

      expect(cancelled).to be(false)
      expect(JSON.parse(result_box[:result])["selected"]).to eq(["Cats"])
      expect(events.map { |e| e[:type] }).not_to include(:question_cancelled)
    end

    it "cancels only the question it names with id:" do
      engine = build_engine
      turn_thread, result_box, events = request_in_background(engine, payload)
      qid = engine.pending_question[:id]

      expect(engine.cancel_question("dismissed", id: "an-older-one")).to be(false)
      expect(engine.pending_question[:status]).to eq("pending")

      expect(engine.cancel_question("dismissed", id: qid)).to be(true)
      turn_thread.join(2)
      expect(JSON.parse(result_box[:result])["error"]).to eq("no answer")
      expect(events.select { |e| e[:type] == :question_cancelled }.map { |e| e[:id] }).to eq([qid])
    end

    it "keeps QuestionNotPending an ArgumentError for existing callers" do
      expect(Samagotchi::Engine::QuestionNotPending.ancestors).to include(ArgumentError)
    end
  end
end

RSpec.describe "Engine ↔ KernelLoop question link" do
  # A real kernel (as the TUI builds it, before the Engine) must route
  # ask_user_question into the Engine's blocking request_question.
  it "the kernel's ask_user_question reaches Engine#request_question" do
    kernel = Samagotchi::KernelLoop.new(client: double("client"))
    engine = Samagotchi::Engine.new(mode: :assist, client: double("client"), kernel: kernel)
    allow(engine).to receive(:request_question).and_return('{"selected":["Cats"]}')

    result = kernel.dispatch_tool_call(name: "ask_user_question", question: "Pets?", options: %w[Cats Dogs])

    expect(engine).to have_received(:request_question).with(include(question: "Pets?", options: %w[Cats Dogs]))
    expect(result[:output]).to eq(%([ask_user_question]\n{"selected":["Cats"]}))
  end
end
