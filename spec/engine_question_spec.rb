# frozen_string_literal: true

require "timeout"

require "json"
require "tmpdir"
require "samagotchi/engine"
require "samagotchi/session"
require "support/thinking_off"

# Covers the cross-thread ask_user_question path used by the Web UI / Bridge:
# Engine#request_question blocks the turn thread until Engine#answer_question
# is called from another thread (or the turn is cancelled).
RSpec.describe "Engine ask_user_question (cross-thread path)" do
  include_context "thinking off"

  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

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
    engine = Samagotchi::Engine.new(client: client, kernel: kernel)
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
    wait_until(timeout: 2.0, interval: 0.005) { engine.pending_question }
    [turn_thread, result_box, events]
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

    it "opens a validated call with wire control tokens stripped from question, options, and header" do
      engine = build_engine
      dirty = payload.merge(
        question: "<|channel|>Which option?<|",
        options: ["|>Cats<|", "|>Dogs<|"],
        header: "<|tool_call|>Pet preference|>"
      )
      turn_thread, result_box, _events = request_in_background(engine, Samagotchi::Tools::AskUserQuestion.validate(dirty))

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

    it "saves the question into the engine's session state dir (the file the hub watches)" do
      state_dir = Dir.mktmpdir("engine-question-state")
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd)
      engine = build_engine(session: session)
      engine.session_state_dir = state_dir
      turn_thread, = request_in_background(engine, payload)

      # The question is saved right after it is set: wait for the file, not just the engine.
      on_disk = nil
      wait_until(timeout: 2) do
        on_disk = Samagotchi::Session.load(session.id, state_dir: state_dir)
        on_disk.pending_question
      rescue ArgumentError
        nil
      end
      expect(on_disk.pending_question[:id]).to eq(engine.pending_question[:id])

      engine.answer_question(id: engine.pending_question[:id], selected: ["Dogs"])
      turn_thread.join(2)
      expect(Samagotchi::Session.load(session.id, state_dir: state_dir).pending_question).to be_nil
    ensure
      FileUtils.rm_rf(state_dir) if state_dir
    end

    it "brings an archived session back to the lists: a human answered" do
      state_dir = Dir.mktmpdir("engine-question-archive")
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd)
      session.save(state_dir: state_dir)
      Samagotchi::ArchiveStore.archive(session.id, state_dir: state_dir)
      engine = build_engine(session: session)
      engine.session_state_dir = state_dir
      allow(session).to receive(:save)
      turn_thread, = request_in_background(engine, payload)

      engine.answer_question(id: engine.pending_question[:id], selected: ["Dogs"])
      turn_thread.join(2)

      expect(Samagotchi::ArchiveStore.archived?(Samagotchi::Session.session_dir(session.id, state_dir: state_dir))).to be(false)
    ensure
      FileUtils.rm_rf(state_dir) if state_dir
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
      engine.send(:turn_state).begin!(controller: ctrl, sink: nil)

      events = []
      engine.subscribe(observer: ->(e) { events << e })
      result_box = {}
      turn_thread = Thread.new do
        result_box[:result] = engine.request_question(payload)
      end
      turn_thread.report_on_exception = false
      wait_until(timeout: 2.0, interval: 0.005) { engine.pending_question }

      ctrl.cancel!(:user)
      turn_thread.join(2)

      answer = JSON.parse(result_box[:result])
      expect(answer["error"]).to eq("cancelled")
      expect(answer["reason"]).to eq("user")
      expect(engine.pending_question).to be_nil

      cancelled = events.find { |e| e[:type] == :question_cancelled }
      expect(cancelled).not_to be_nil
    end

    # Bridge#handle_snapshot holds the event lock and reads the pending
    # question; the cancelled turn announces :question_cancelled, which needs
    # the event lock. Neither may hold the question lock while waiting.
    it "doesn't deadlock when a cancelled question races a snapshot taken with the event log held" do
      engine = build_engine
      ctrl = Samagotchi::Client::CancellationController.new
      engine.send(:turn_state).begin!(controller: ctrl, sink: nil)
      result_box = {}
      turn_thread = Thread.new { result_box[:result] = engine.request_question(payload) }
      turn_thread.report_on_exception = false
      wait_until(timeout: 2.0, interval: 0.005) { engine.pending_question }

      held = Queue.new
      go = Queue.new
      state_box = {}
      bridge_thread = Thread.new do
        engine.synchronize_events do
          held << true
          go.pop
          state_box[:state] = engine.session_state_snapshot
        end
      end
      bridge_thread.report_on_exception = false
      held.pop

      ctrl.cancel!(:user)
      # The turn thread wakes and parks on the event lock, announcing the cancel.
      parked = wait_until(timeout: 2.0, interval: 0.005) do
        Array(turn_thread.backtrace).any? { |l| l.include?("session_observer.rb") && l.include?("notify") }
      end
      raise "turn thread never reached SessionObserver#notify" unless parked
      go << true

      begin
        expect(bridge_thread.join(2)).not_to be_nil, "the snapshot deadlocked on the question lock"
        expect(turn_thread.join(2)).not_to be_nil
      ensure
        [bridge_thread, turn_thread].each { |t| t.kill if t.alive? }
      end
      expect(state_box[:state][:pending_question]).to be_nil
      expect(JSON.parse(result_box[:result])["error"]).to eq("cancelled")
    end

    it "cancel_question names the question it cancelled, and announces nothing with none pending" do
      engine = build_engine
      events = []
      engine.subscribe(observer: ->(e) { events << e })
      engine.cancel_question("user")
      expect(events.map { |e| e[:type] }).not_to include(:question_cancelled)

      turn_thread = Thread.new { engine.request_question(payload) }
      turn_thread.report_on_exception = false
      wait_until(timeout: 2.0, interval: 0.005) { engine.pending_question }
      id = engine.pending_question[:id]

      engine.cancel_question("user")
      turn_thread.join(2)

      cancelled = events.select { |e| e[:type] == :question_cancelled }
      expect(cancelled.map { |e| e.slice(:id, :reason) }).to eq([{ id: id, reason: "user" }])
    end
  end

  # The REPL answers on the turn thread itself, through a sync handler.
  describe "a synchronous handler (REPL)" do
    it "returns the answer the handler recorded and announces it" do
      engine = build_engine
      events = []
      engine.subscribe(observer: ->(e) { events << e })
      engine.set_question_sync_handler do |pending|
        engine.answer_question(id: pending[:id], selected: ["Cats"])
        nil
      end
      answer = JSON.parse(engine.request_question(payload))
      expect(answer).to include("selected" => ["Cats"], "selected_indices" => [0])
      expect(engine.pending_question).to be_nil
      expect(events.map { |e| e[:type] }).to eq(%i[question_requested question_answered])
    end

    it "says the user dismissed it (not an error) when the handler records nothing" do
      engine = build_engine
      engine.set_question_sync_handler { |_pending| nil }
      answer = JSON.parse(engine.request_question(payload))
      expect(answer).not_to have_key("error")
      expect(answer).to include("dismissed" => true)
      expect(answer["note"]).to include("dismissed the question without answering", "Don't do what you asked about")
      expect(engine.pending_question).to be_nil
    end
  end

  describe "Engine#open_question" do
    it "carries extra keys through to pending_question and returns the answer hash" do
      engine = build_engine
      result = nil
      thread = Thread.new do
        result = engine.open_question(question: "Run it?", options: %w[Yes No], kind: "approval",
                                      approval: { tool: "execute" })
      end
      wait_until(timeout: 2.0, interval: 0.005) { engine.pending_question }
      pending = engine.pending_question
      expect(pending).to include(kind: "approval", approval: { tool: "execute" }, status: "pending")
      engine.answer_question(id: pending[:id], selected: ["No"])
      thread.join(2)
      expect(result).to include(id: pending[:id], selected: ["No"], selected_indices: [1])
    end

    it "shows the question text as given (no wire-token stripping)" do
      engine = build_engine
      engine.set_question_sync_handler { |_pending| nil }
      seen = nil
      engine.subscribe(observer: ->(e) { seen = e[:pending_question] if e[:type] == :question_requested })
      engine.open_question(question: "echo '<|x|>'", options: %w[Yes No])
      expect(seen[:question]).to eq("echo '<|x|>'")
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
      engine.instance_variable_get(:@question_desk).instance_variable_get(:@lock).synchronize do
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

      engine.instance_variable_get(:@question_desk).instance_variable_get(:@lock).synchronize do
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
      engine.instance_variable_get(:@question_desk).instance_variable_get(:@lock).synchronize do
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
      expect(JSON.parse(result_box[:result])).to include("dismissed" => true).and(satisfy { |r| !r.key?("error") })
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
    engine = Samagotchi::Engine.new(client: double("client"), kernel: kernel)
    allow(engine).to receive(:request_question).and_return('{"selected":["Cats"]}')

    result = kernel.dispatch_tool_call(name: "ask_user_question", question: "Pets?", options: %w[Cats Dogs])

    expect(engine).to have_received(:request_question).with(include(question: "Pets?", options: %w[Cats Dogs]))
    expect(result[:output]).to eq(%([ask_user_question]\n{"selected":["Cats"]}))
  end

  # The kernel validates; a bad call never opens a question.
  it "answers a bad call with the plain-text validation error, without asking" do
    kernel = Samagotchi::KernelLoop.new(client: double("client"))
    engine = Samagotchi::Engine.new(client: double("client"), kernel: kernel)
    allow(engine.instance_variable_get(:@question_desk)).to receive(:open_question)

    nine = (1..9).map { |n| "Option #{n}" }
    outputs = [
      kernel.dispatch_tool_call(name: "ask_user_question", question: "<|tool_call|>", options: %w[A B]),
      kernel.dispatch_tool_call(name: "ask_user_question", question: "Pick", options: []),
      kernel.dispatch_tool_call(name: "ask_user_question", question: "Pick", options: nine)
    ].map { |r| r[:output] }

    expect(outputs).to eq([
      "[ask_user_question]\nError: ask_user_question requires 'question'",
      "[ask_user_question]\n#{Samagotchi::Tools::AskUserQuestion.options_count_error(0)}",
      "[ask_user_question]\n#{Samagotchi::Tools::AskUserQuestion.options_count_error(9)}"
    ])
    expect(engine.instance_variable_get(:@question_desk)).not_to have_received(:open_question)
    expect(engine.pending_question).to be_nil
  end
end
