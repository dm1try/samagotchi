# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require_relative "support/fake_chat_adapter"

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

  let(:client) { instance_double(Samagotchi::Client) }
  let(:kernel) { instance_double(Samagotchi::KernelLoop) }
  let(:engine) { described_class.new(client: client, kernel: kernel, profile: "gemma4") }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  let(:nudge) { Samagotchi::TurnNote.empty_retry }
  let(:reminders) { double("reminders", due_reminders: [{ name: "tea", description: "brew", interval_minutes: 5 }], clear_due: nil) }
  let(:timeline) { [] }
  let(:at_end) { {} }
  let(:probe_before) { Object.new }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(kernel).to receive(:sampling=)
    allow(Samagotchi::Log).to receive(:info).and_call_original
    engine.instance_variable_set(:@reminders, reminders)
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
        at_end.merge!(status: session.status, outcome: session.last_turn&.fetch("outcome"))
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
  end

  it "2. native empty: [No response] and TurnNote.empty, the nudge dropped" do
    native { |messages, **| kernel_result(messages + [nudge], text: "") }

    result = run

    expect(timeline).to eq(%w[turn_started hook:session_start hook:before_turn reminder_injected used_memories_updated
                              replace! turn_completed persist hook:after_turn=completed answer_display hook:session_end])
    expect(tail).to eq(["user:hi", "model:[No response]", "system:[SYSTEM: the previous turn ended with no vis"])
    expect(result.conversation.last).to eq(Samagotchi::TurnNote.empty)
    expect(result.conversation).not_to include(nudge)
    expect(at_end).to eq(status: "idle", outcome: "completed")
    expect_released
  end

  it "3. chat empty: no placeholder message, turn_summary.output is the placeholder" do
    placeholder = "(the model returned an empty answer)"
    chat(FakeChatAdapter.text(""))
    summary = nil
    engine.subscribe(observer: ->(e) { summary = e[:turn_summary] if e[:type] == :turn_completed })

    result = run

    expect(timeline).to eq(%w[turn_started hook:session_start hook:before_turn reminder_injected
                              generation_started generation_chunk generation_completed empty_answer_retry
                              generation_started generation_chunk generation_completed
                              used_memories_updated replace! turn_completed persist hook:after_turn=completed answer_display
                              hook:session_end])
    expect(tail(2)).to eq(["user:hi", "system:[SYSTEM: the previous turn ended with no vis"])
    expect(summary[:output]).to eq(placeholder)
    expect(result.output).to eq(placeholder)
    expect(at_end).to eq(status: "idle", outcome: "completed")
    expect_released
  end

  it "4. resumable: ends at its tool results, no note" do
    native do |messages, **|
      kernel_result(messages + [reply("calling"), { role: "tool_response", content: "r" }],
                    text: "", exhausted: true, pending_tool_calls: true)
    end

    run

    expect(timeline).to eq(%w[turn_started hook:session_start hook:before_turn reminder_injected used_memories_updated
                              replace! turn_completed persist hook:after_turn=completed answer_display hook:session_end])
    expect(tail).to eq(["user:hi", "model:calling", "tool_response:r"])
    expect(at_end).to eq(status: "idle", outcome: "completed")
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
    expect(canceled).to include(cancellation_reason: :hook, duration_ms: be_a(Integer))
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
    expect(tail).to eq(["model:calling", "tool_response:ok", "system:[SYSTEM: the previous turn failed before any"])
    expect(failed).to include(error_class: "Samagotchi::LLM::RateLimited", error_kind: :rate_limited, host: "fw")
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
    expect(session.last_turn["outcome"]).to eq("completed")
    expect_released
  end
end
