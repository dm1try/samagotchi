# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require_relative "support/fake_chat_adapter"
require "support/test_kernel"

# How Engine#run_turn ends a turn, as data: one row per way a turn ends
# (native answer, empty answers, a resumable turn, a Stop, a Ctrl-C, a
# failure). Each row pins one timeline of what the turn did, in order:
# the events the subscribers saw (`:type`), the hooks that fired
# (`hook:after_turn=completed`), `persist` (SessionMetrics#persist),
# `save` (Session#save) and `replace` (a write of session.messages);
# a trailing `!` marks one made with the event lock held. Plus the
# session's messages tail, its state when the end event was delivered, the
# return value or the error re-raised, and the engine's state afterwards.
RSpec.describe Samagotchi::Engine, "#run_turn endings" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:engine) { described_class.new(client: client, kernel: kernel, profile: "gemma4") }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  let(:nudge) { Samagotchi::TurnNote.empty_retry }
  let(:timeline) { [] }
  let(:at_end) { {} }
  let(:probe_before) { Object.new }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(Samagotchi::Log).to receive(:info).and_call_original
    # A reminder due when the turn starts.
    store = engine.reminder_store
    store.register({ name: "tea", description: "brew", interval_minutes: 5 })
    store.instance_variable_get(:@mutex).synchronize { store.reminders["tea"][:next_fire_at] = 0.0 }
    session.used_memory_names = ["notes"]
    allow(engine.metrics).to receive(:persist) { timeline << mark("persist") }
    allow(session).to receive(:save) { timeline << mark("save") }
    allow(session).to receive(:messages=).and_wrap_original do |original, messages|
      timeline << mark("replace")
      original.call(messages)
    end
    engine.subscribe(observer: lambda { |event|
      timeline << event[:type].to_s
      if %i[turn_completed turn_canceled turn_failed].include?(event[:type]) && at_end.empty?
        at_end.merge!(status: session.status, outcome: session.last_turn&.outcome)
      end
    })
  end

  def locked?
    engine.instance_variable_get(:@session_observer).instance_variable_get(:@mutex).mon_owned?
  end

  def mark(name) = locked? ? "#{name}!" : name

  def record_hooks(after_turn: true)
    return if @recorded

    @recorded = true
    hooks = engine.instance_variable_get(:@hooks)
    %i[session_start before_turn session_end].each do |name|
      hooks.register_persistent(name) { |_event| timeline << "hook:#{name}" }
    end
    hooks.register_persistent(:after_turn) { |event| timeline << "hook:after_turn=#{event[:status]}" } if after_turn
    # Turn-scoped: gone after the turn.
    engine.register_hook(:session_end) { |_event| nil }
  end

  def reply(text) = { role: "model", content: text }

  def native(&block)
    allow(kernel).to receive(:run, &block)
  end

  def kernel_result(conversation, text: "done", **fields)
    Samagotchi::LLM::ModelResult.new(text: text, conversation: conversation, exhausted: false,
                                     pending_tool_calls: false, tool_activity: [], canceled: false, **fields)
  end

  def chat(*steps)
    backend = Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: FakeChatAdapter.new(*steps))
    allow(engine).to receive(:backend_for).and_return(backend)
  end

  # Runs the turn; returns the result or the error it re-raised.
  def run(prompt = "hi", after_turn: true, **options)
    record_hooks(after_turn: after_turn)
    Samagotchi::Client.swap_probe_cancel(probe_before)
    begin
      engine.run_turn(session, prompt, **options)
    rescue Exception => e # rubocop:disable Lint/RescueException
      e
    end
  ensure
    @probe_after = Samagotchi::Client.swap_probe_cancel(nil)
  end

  def tail(count = 3)
    session.messages.last(count).map { |m| "#{m[:role]}:#{m[:content].to_s[0, 44]}" }
  end

  def expect_released
    expect(engine.turn_running?).to be(false)
    expect(engine.active_cancel_controller).to be_nil
    expect(engine.send(:turn_state).in_turn_sink).to eq([false, nil])
    expect(engine.instance_variable_get(:@hooks).any?(:session_end)).to be(true) # the persistent one
    expect(engine.instance_variable_get(:@hooks).instance_variable_get(:@hooks)).to be_empty
    expect(@probe_after).to equal(probe_before)
  end

  def expect_steer_dropped
    expect(Samagotchi::Log).to have_received(:info).with(:turn, "steer_dropped", hash_including(why: "turn_ended"))
  end

  it "1. native answer" do
    native do |messages, **|
      engine.steer("late", source: "spec")
      kernel_result(messages + [reply("done")])
    end

    result = run

    expect(timeline).to eq(%w[turn_started hook:session_start hook:before_turn reminder_injected used_memories_updated
                              replace! turn_completed persist hook:after_turn=completed answer_display hook:session_end])
    expect(result).to be_a(Samagotchi::LLM::ModelResult).and have_attributes(output: "done")
    expect(tail).to eq(["system:[SYSTEM: REMINDERS DUE]\n  tea: brew (interva", "user:hi", "model:done"])
    expect(at_end).to eq(status: "idle", outcome: "completed")
    expect_released
    expect_steer_dropped
  end

  it "1b. native answer, no after_turn hook: nothing pending, no answer_display" do
    native { |messages, **| kernel_result(messages + [reply("done")]) }
    completed = nil
    engine.subscribe(observer: ->(e) { completed = e if e[:type] == :turn_completed })

    run(after_turn: false)

    expect(timeline).to eq(%w[turn_started hook:session_start hook:before_turn reminder_injected used_memories_updated
                              replace! turn_completed persist hook:session_end])
    expect(completed).to include(display_pending: false, result: be_a(Samagotchi::LLM::ModelResult))
    expect(completed[:turn_summary]).to include(output: "done", resumable: false)
    expect(session.last_turn.to_file.keys).not_to include("exhausted", "limit")
  end

  it "2. native empty: TurnNote.empty with its marker, the nudge dropped, no made-up answer" do
    native { |messages, **| kernel_result(messages + [nudge], text: "", empty_retries: 1) }
    summary = nil
    engine.subscribe(observer: ->(e) { summary = e[:turn_summary] if e[:type] == :turn_completed })

    result = run

    expect(timeline).to eq(%w[turn_started hook:session_start hook:before_turn reminder_injected used_memories_updated
                              replace! turn_completed persist hook:after_turn=completed answer_display hook:session_end])
    expect(tail(2)).to eq(["user:hi", "system:[SYSTEM: the previous turn ended with no vis"])
    expect(result.conversation.last).to eq(Samagotchi::TurnNote.empty(retries: 1))
    expect(summary).to include(output: "", empty_answer: { retries: 1 })
    expect(result.conversation).not_to include(nudge)
    expect(at_end).to eq(status: "idle", outcome: "completed")
    expect_released
  end

  it "3. chat empty: no placeholder anywhere, the summary says it was empty" do
    chat(FakeChatAdapter.text(""))
    summary = nil
    engine.subscribe(observer: ->(e) { summary = e[:turn_summary] if e[:type] == :turn_completed })

    result = run

    expect(timeline).to eq(%w[turn_started hook:session_start hook:before_turn reminder_injected
                              context_status generation_started generation_chunk generation_completed
                              empty_answer_retry context_status generation_started generation_chunk
                              generation_completed used_memories_updated replace! turn_completed persist
                              hook:after_turn=completed answer_display hook:session_end])
    expect(tail(2)).to eq(["user:hi", "system:[SYSTEM: the previous turn ended with no vis"])
    expect(summary).to include(output: "", empty_answer: { retries: 1 })
    expect(result.output).to eq("")
    expect(session.messages.last).to include(kind: "turn_note", empty_answer: { retries: 1, steps: [{ role: "model", content: "" }] * 2 })
    expect(at_end).to eq(status: "idle", outcome: "completed")
    expect_released
  end

  it "4. resumable: ends at its tool results, no note" do
    native do |messages, **|
      kernel_result(messages + [reply("calling"), { role: "tool_response", content: "r" }],
                    text: "", exhausted: true, pending_tool_calls: true)
    end

    run(max_iterations: 7)

    expect(timeline).to eq(%w[turn_started hook:session_start hook:before_turn reminder_injected used_memories_updated
                              replace! turn_completed persist hook:after_turn=completed answer_display hook:session_end])
    expect(tail).to eq(["user:hi", "model:calling", "tool_response:r"])
    expect(at_end).to eq(status: "idle", outcome: "completed")
    # It ran out at the limit it was given: a wait nobody answers says so.
    expect(session.last_turn.to_file).to include("outcome" => "completed", "exhausted" => true, "limit" => 7)
    expect_released
  end

  it "5. cancelled result (Stop): a note saying who stopped it, after_turn status canceled" do
    controller = Samagotchi::CancellationController.new
    native do |messages, **|
      controller.cancel!(:hook, { by: "loop-guard", reason: "looping" })
      kernel_result(messages, text: "", canceled: true, cancellation_reason: :hook)
    end
    canceled = nil
    engine.subscribe(observer: ->(e) { canceled = e if e[:type] == :turn_canceled })

    result = run(cancel_controller: controller)

    expect(timeline).to eq(%w[turn_started hook:session_start hook:before_turn reminder_injected used_memories_updated
                              replace! turn_canceled persist hook:after_turn=canceled hook:session_end])
    expect(tail(2)).to eq(["user:hi", "system:[SYSTEM: the previous turn was cancelled (ho"])
    expect(session.messages.last[:content]).to start_with("[SYSTEM: the previous turn was cancelled (hook loop-guard: looping)")
    expect(canceled).to include(cancellation_reason: :hook, cancelled_by: "loop-guard", duration_ms: be_a(Integer))
    expect(session.last_turn.to_file).to include("outcome" => "canceled", "cancel_reason" => "hook", "stopped_by" => "loop-guard")
    expect(result.conversation.last).to eq(session.messages.last)
    expect(at_end).to eq(status: "idle", outcome: "canceled")
    expect_released
  end

  it "6. Interrupt from the backend: the cancel note on the turn's messages, re-raised" do
    native do |_messages, **|
      engine.steer("late", source: "spec")
      raise Interrupt
    end

    error = run

    expect(error).to be_a(Interrupt)
    expect(timeline).to eq(%w[turn_started hook:session_start hook:before_turn reminder_injected
                              replace! turn_canceled persist])
    expect(tail).to eq(["system:[SYSTEM: REMINDERS DUE]\n  tea: brew (interva", "user:hi",
                        "system:[SYSTEM: the previous turn was cancelled (ct"])
    expect(engine.active_cancel_controller).to be_nil
    expect(at_end).to eq(status: "idle", outcome: "canceled")
    expect_released
    expect_steer_dropped
  end

  it "7. Interrupt before the turn's messages (in a before_turn hook): no replace" do
    record_hooks
    engine.instance_variable_get(:@hooks).register_persistent(:before_turn) { |_event| raise Interrupt }
    session.messages = [{ role: "user", content: "old" }]
    timeline.clear

    error = run

    expect(error).to be_a(Interrupt)
    expect(timeline).to eq(%w[turn_started hook:session_start hook:before_turn turn_canceled persist])
    expect(session.messages).to eq([{ role: "user", content: "old" }])
    expect(at_end).to eq(status: "idle", outcome: "canceled")
    expect_released
  end

  it "8. ProviderError with a partial conversation: kept with a failed note, saved, re-raised" do
    partial = [{ role: "user", content: "hi" }, reply("calling"), { role: "tool_response", content: "ok" }]
    error = Samagotchi::LLM::FailedTurn.attach(
      Samagotchi::LLM::RateLimited.new("fw: HTTP 429: slow down", host: "fw", status: 429), partial
    )
    native { |_messages, **| raise error }
    failed = nil
    engine.subscribe(observer: ->(e) { failed = e if e[:type] == :turn_failed })

    raised = run

    expect(raised).to equal(error)
    expect(timeline).to eq(%w[turn_started hook:session_start hook:before_turn reminder_injected
                              replace! turn_failed save persist])
    expect(tail).to eq(["model:calling", "tool_response:ok", "system:[SYSTEM: the previous turn failed after 1 to"])
    expect(failed).to include(error_class: "Samagotchi::LLM::RateLimited", error_kind: :rate_limited, host: "fw", kept_steps: 1)
    expect(error.kept_steps).to eq(1)
    expect(at_end).to eq(status: "idle", outcome: "failed")
    expect_released
  end

  it "9. image error before the turn's messages: no note, no replace, still saved" do
    session.messages = [{ role: "user", content: "old" }]
    timeline.clear

    raised = run(images: [{ path: "/nonexistent/b3.png" }])

    expect(raised).to be_a(Samagotchi::ImageStore::Error)
    expect(timeline).to eq(%w[turn_started turn_failed save persist])
    expect(session.messages).to eq([{ role: "user", content: "old" }])
    expect(at_end).to eq(status: "idle", outcome: "failed")
    expect_released
  end

  it "10. a continue turn failing: the note says the continued turn stopped" do
    session.messages = [{ role: "user", content: "go" }, { role: "tool_response", content: "r" }]
    timeline.clear
    native { |_messages, **| raise "boom" }

    raised = run(nil, continue: true)

    expect(raised).to be_a(RuntimeError)
    expect(timeline).to eq(%w[turn_started hook:session_start hook:before_turn reminder_injected
                              replace! turn_failed save persist])
    expect(session.messages.last[:content]).to eq(
      "[SYSTEM: the previous turn failed before any answer: boom. The continued turn stopped there.]"
    )
    expect(tail(3).first(2)).to eq(["tool_response:r", "system:[SYSTEM: REMINDERS DUE]\n  tea: brew (interva"])
    expect(at_end).to eq(status: "idle", outcome: "failed")
    expect_released
  end

  it "11. an after_turn hook presenting the answer: display_pending, then answer_display with the text" do
    record_hooks
    native { |messages, **| kernel_result(messages + [reply("done")]) }
    engine.instance_variable_get(:@hooks).register_persistent(:after_turn) do |event|
      event[:present].call { |text| text.upcase }
    end
    displays = []
    pending = nil
    engine.subscribe(observer: lambda { |e|
      displays << e[:display] if e[:type] == :answer_display
      pending = e[:display_pending] if e[:type] == :turn_completed
    })

    run

    expect(pending).to be(true)
    expect(displays).to eq(["DONE"])
    expect(timeline).to eq(%w[turn_started hook:session_start hook:before_turn reminder_injected used_memories_updated
                              replace! turn_completed persist hook:after_turn=completed replace! answer_display
                              hook:session_end])
    expect(session.messages.last).to include(role: "model", content: "done")
  end

  # The turn has ended once turn_completed is out: an Interrupt in the
  # post-turn hooks only re-raises (no second ending; the answer stays).
  it "12. Interrupt after turn_completed (an after_turn hook): re-raised, no second ending, the answer kept" do
    record_hooks
    native { |messages, **| kernel_result(messages + [reply("done")]) }
    engine.instance_variable_get(:@hooks).register_persistent(:after_turn) { |_event| raise Interrupt }

    error = run

    expect(error).to be_a(Interrupt)
    expect(timeline).to eq(%w[turn_started hook:session_start hook:before_turn reminder_injected used_memories_updated
                              replace! turn_completed persist hook:after_turn=completed])
    expect(tail(2)).to eq(["user:hi", "model:done"])
    expect(session.last_turn.outcome).to eq("completed")
    expect_released
  end

  # The same for a StandardError after turn_completed (post-turn work, here
  # storing the answer's display): re-raised, no turn_failed, nothing saved
  # over the answer.
  it "13. StandardError after turn_completed: re-raised, no second ending, the answer kept" do
    record_hooks
    native { |messages, **| kernel_result(messages + [reply("done")]) }
    allow(engine).to receive(:store_answer_display).and_raise(RuntimeError, "post-turn boom")

    error = run

    expect(error).to be_a(RuntimeError).and have_attributes(message: "post-turn boom")
    expect(timeline).to eq(%w[turn_started hook:session_start hook:before_turn reminder_injected used_memories_updated
                              replace! turn_completed persist hook:after_turn=completed])
    expect(tail(2)).to eq(["user:hi", "model:done"])
    expect(session.last_turn.outcome).to eq("completed")
    expect_released
  end

  # A Stop while the turn probes the server (/props): the turn ends there,
  # before the hooks run or a reminder is used up; the model is not asked.
  it "14. Stop during the turn-start probe: canceled before the hooks, the reminder still due" do
    controller = Samagotchi::CancellationController.new
    allow(engine).to receive(:refresh_profile!) { controller.cancel! }
    native { |_messages, **| raise "the model must not be asked" }
    session.messages = [{ role: "user", content: "old" }]
    timeline.clear
    canceled = nil
    engine.subscribe(observer: ->(e) { canceled = e if e[:type] == :turn_canceled })

    result = run(cancel_controller: controller)

    expect(result).to be_a(Samagotchi::LLM::ModelResult).and have_attributes(canceled?: true, conversation: nil)
    expect(timeline).to eq(%w[turn_started turn_canceled persist])
    expect(canceled).to include(cancellation_reason: :manual, duration_ms: be_a(Integer))
    expect(session.messages).to eq([{ role: "user", content: "old" }])
    expect(engine.reminder_store.due_reminders.map { |r| r[:name] }).to eq(["tea"])
    expect(at_end).to eq(status: "idle", outcome: "canceled")
    expect_released
  end

  # The load-failure warnings show once per Engine; a turn stopped before
  # the model is asked leaves them for the next turn.
  it "15. Stop during the turn-start probe keeps the guardrail warning for the next turn" do
    engine.guardrail_failures.add("hook g.rb (config)", "LoadError: x", required: false)
    controller = Samagotchi::CancellationController.new
    allow(engine).to receive(:refresh_profile!) { controller.cancel! }
    native { |messages, **| kernel_result(messages + [reply("done")]) }
    timeline.clear

    run(cancel_controller: controller)
    expect(timeline).to eq(%w[turn_started turn_canceled persist])

    allow(engine).to receive(:refresh_profile!)
    timeline.clear
    run
    expect(timeline.first(2)).to eq(%w[turn_started guardrail_warning])
  end
end
