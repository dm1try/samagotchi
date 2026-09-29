# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "samagotchi/terminal_ui"

# Golden output for one interactive REPL turn, driven end to end: the real
# assist loop reads a prompt, the kernel replays a fixture of stream events and
# returns a result, and we capture everything written to the terminal. These
# pin what the user sees while the turn plumbing underneath is refactored.
#
# Regenerate after an intended change with:
#   UPDATE_GOLDEN=1 bundle exec rspec spec/terminal_ui_golden_spec.rb
RSpec.describe "TerminalUI interactive turn output (golden)" do
  def golden_dir = File.expand_path("fixtures/terminal_ui_golden", __dir__)

  let(:client) { instance_double(Samagotchi::Client) }
  let(:history_dir) { Dir.mktmpdir("golden-history") }

  around do |example|
    saved = ENV.to_h.slice("SAMAGOTCHI_DEFAULT_MODEL", "SAMAGOTCHI_HISTORY_FILE", "XDG_STATE_HOME")
    ENV["SAMAGOTCHI_HISTORY_FILE"] = File.join(history_dir, "history.json")
    ENV["XDG_STATE_HOME"] = history_dir
    example.run
  ensure
    %w[SAMAGOTCHI_DEFAULT_MODEL SAMAGOTCHI_HISTORY_FILE XDG_STATE_HOME].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
    FileUtils.remove_entry(history_dir)
  end

  before { allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("") }

  # Chunk events as KernelLoop emits them (thinking split by the profile).
  def chunks(profile, *pieces, iteration: 1, payload: nil)
    splitter = Samagotchi::ThoughtStreamSplitter.for_profile(Samagotchi::ModelProfile.normalize(profile))
    pieces.map do |content|
      { type: :generation_chunk, iteration: iteration, content: content,
        thinking: splitter.feed(content)[:thinking], payload: payload || { "content" => content } }
    end
  end

  def generation(profile, *pieces, iteration: 1, payload: nil)
    [{ type: :generation_started, iteration: iteration }] +
      chunks(profile, *pieces, iteration: iteration, payload: payload) +
      [{ type: :generation_completed, iteration: iteration, content_length: pieces.join.length }]
  end

  def result_for(messages, output:, **overrides)
    Samagotchi::KernelLoop::Result.new(
      output: output, conversation: messages + [{ role: "model", content: output }],
      exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: false, **overrides
    )
  end

  # Run one REPL turn: +events+ replay through the kernel's stream callback;
  # +finish+ receives the messages the kernel got and returns its result (or
  # raises). Returns the normalized terminal output.
  def run_turn(model:, events:, tty: true, prompt: "hi", &finish)
    run_session(model: model, tty: tty, prompts: [prompt], turns: [[events, finish]])
  end

  # Run a REPL session: +prompts+ feed the main prompt, +answers+ the
  # continue(yes/no) prompt, and each kernel run consumes the next
  # [events, finish] pair from +turns+. +setup+ gets the UI before it runs.
  #
  # On a terminal (+tty+) the UI draws on a live region, a 24x100 Screen, so
  # the goldens pin its frames; without one it prints plainly to $stdout.
  def run_session(model:, prompts:, turns:, answers: [], tty: true, setup: nil)
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = model
    out = StringIO.new
    surface = Samagotchi::TerminalUI::Screen.new(out: out, size: -> { [24, 100] }) if tty
    ui = Samagotchi::TerminalUI.new(mode: :assist, client: client, no_default_input: true, surface: surface)
    allow(ui).to receive(:thinking_spinner_enabled?).and_return(tty)
    allow(ui).to receive(:color_output?).and_return(tty)
    allow(ui).to receive(:thinking_render_min_interval).and_return(0.0)
    allow(ui).to receive(:status_effective_width).and_return(100)
    allow(ui).to receive(:status_server_segment).and_return("")
    allow(Reline).to receive(:readmultiline).and_return(*prompts, nil)
    allow(Reline).to receive(:readline).and_return(*answers, nil)
    @kernel_inputs = []
    pending = turns.dup
    allow(ui.instance_variable_get(:@kernel)).to receive(:run) do |messages, **kwargs|
      @kernel_inputs << messages.drop(1).map { |m| "#{m[:role]}: #{m[:content].inspect}" }
      events, finish = pending.shift
      events.each { |event| kwargs[:on_stream_event]&.call(event) }
      finish.call(messages)
    end
    setup&.call(ui)

    original = $stdout
    $stdout = out
    begin
      ui.run
    ensure
      $stdout = original
    end
    normalize(out.string + kernel_inputs + persisted_conversation)
  end

  # What each kernel run was asked to continue from (leading system prompt
  # elided).
  def kernel_inputs
    return "" if @kernel_inputs.to_a.length < 2

    @kernel_inputs.each_with_index.map { |lines, i| "--- kernel run #{i + 1} ---\n#{lines.join("\n")}\n" }.join
  end

  # The saved session's conversation (system prompt elided), so the goldens
  # also pin what a turn leaves behind for --resume.
  def persisted_conversation
    path = Dir.glob(File.join(history_dir, "samagotchi", "sessions", "*.json")).first
    return "--- no session saved ---\n" unless path

    messages = JSON.parse(File.read(path))["messages"]
    lines = messages.each_with_index.map do |m, i|
      i.zero? && m["role"] == "system" ? "system: <prompt>" : "#{m["role"]}: #{m["content"].inspect}"
    end
    "--- session ---\n#{lines.join("\n")}\n"
  end

  def normalize(text)
    text.gsub(/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/, "<session-id>")
      .gsub(/\((\d+(\.\d+)?(ms|s)|\d+m \d+s)\)/, "(<elapsed>)")
      .gsub("\e", "\\e")
      .gsub("\r\n", "\n").gsub("\r", "\\r")
  end

  def expect_golden(name, actual)
    path = File.join(golden_dir, "#{name}.txt")
    if ENV["UPDATE_GOLDEN"] == "1"
      FileUtils.mkdir_p(golden_dir)
      File.write(path, actual)
    end
    expect(actual).to eq(File.read(path))
  end

  let(:memory_activity) { { action: "loading memory", tool: "memory_read", params: 'name="notes"', status: "ok" } }
  let(:failed_activity) { { action: "running command", tool: "execute", params: 'command="false"', status: "error" } }

  def tool_round(profile)
    generation(profile, "<think>need notes</think>", "<tool_call><function=memory_read>…</function></tool_call>") + [
      { type: :tool_dispatch_started, iteration: 1, call_count: 1 },
      { type: :tool_call_started, iteration: 1, call_count: 1, call_index: 1, tool: "memory_read",
        call: { name: "memory_read", content: "notes" }, params: 'name="notes"' },
      { type: :tool_call_completed, iteration: 1, call_count: 1, call_index: 1, tool: "memory_read",
        output: "remember milk", output_truncated: false, activity: memory_activity },
      { type: :tool_dispatch_completed, iteration: 1, call_count: 1 }
    ]
  end

  it "renders a Qwen answer with the turn preamble and server context" do
    payload = { "content" => "x", "timings" => { "prompt_n" => 1200, "predicted_n" => 40 }, "n_ctx" => 32_000 }
    events = generation("qwen36", "<think>TURN: checking the greeting\n", "some reasoning</think>", "Hello there", payload: payload)

    output = run_turn(model: "Qwen3-14B", events: events) { |messages| result_for(messages, output: "Hello there") }

    expect_golden("qwen_answer", output)
  end

  it "renders a Gemma answer with its thinking sentence" do
    events = generation("gemma4", "<|channel>thought\nweighing ", "options<channel|>", "Hi!")

    output = run_turn(model: "gemma-4-e4b", events: events) { |messages| result_for(messages, output: "Hi!") }

    expect_golden("gemma_answer", output)
  end

  it "renders streamed and end-of-turn tool activity plus the memory line" do
    events = tool_round("qwen36") + generation("qwen36", "Done.", iteration: 2)

    output = run_turn(model: "Qwen3-14B", events: events) do |messages|
      result_for(messages, output: "Done.", tool_activity: [memory_activity, failed_activity])
    end

    expect_golden("tool_activity", output)
  end

  it "renders tool activity without a terminal (no spinner, no color)" do
    events = tool_round("qwen36") + generation("qwen36", "Done.", iteration: 2)

    output = run_turn(model: "Qwen3-14B", events: events, tty: false) do |messages|
      result_for(messages, output: "Done.", tool_activity: [memory_activity, failed_activity])
    end

    expect_golden("tool_activity_plain", output)
  end

  it "renders a network retry in the spinner" do
    events = [{ type: :generation_started, iteration: 1 },
              { type: :generation_retrying, iteration: 1, attempt: 1, max_retries: 3, next_delay: 0.5, error_class: "Errno::ECONNREFUSED" }] +
             chunks("qwen36", "ok") + [{ type: :generation_completed, iteration: 1, content_length: 2 }]

    output = run_turn(model: "Qwen3-14B", events: events) { |messages| result_for(messages, output: "ok") }

    expect_golden("retry", output)
  end

  it "stops at the iteration limit and offers to continue" do
    output = run_turn(model: "Qwen3-14B", events: tool_round("qwen36")) do |messages|
      Samagotchi::KernelLoop::Result.new(
        output: "", conversation: messages + [{ role: "tool_response", content: "remember milk" }],
        exhausted: true, pending_tool_calls: true, tool_activity: [memory_activity], canceled: false
      )
    end

    expect_golden("iteration_limit", output)
  end

  it "reports a Ctrl-C cancel that kept partial progress" do
    events = generation("qwen36", "<think>hmm</think>", "Partial").first(3) +
             [{ type: :generation_cancelled, iteration: 1, reason: :ctrl_c }]

    output = run_turn(model: "Qwen3-14B", events: events) do |messages|
      Samagotchi::KernelLoop::Result.new(
        output: "", conversation: messages + [{ role: "model", content: "Partial\n[interrupted]", interrupted: true }],
        exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: true, cancellation_reason: :ctrl_c
      )
    end

    expect_golden("ctrl_c_cancel", output)
  end

  it "reports an Interrupt raised mid-turn" do
    events = generation("qwen36", "<think>hmm").first(2)

    output = run_turn(model: "Qwen3-14B", events: events) { |_messages| raise Interrupt }

    expect_golden("interrupt", output)
  end

  def exhausted_result(messages)
    Samagotchi::KernelLoop::Result.new(
      output: "", conversation: messages + [{ role: "tool_response", content: "remember milk" }],
      exhausted: true, pending_tool_calls: true, tool_activity: [memory_activity], canceled: false
    )
  end

  describe "multi-turn REPL flows" do
    let(:answer_turn) { [generation("qwen36", "Finished."), ->(messages) { result_for(messages, output: "Finished.") }] }

    it "continues after the iteration limit on yes" do
      output = run_session(model: "Qwen3-14B", prompts: ["go"], answers: ["yes"],
                           turns: [[tool_round("qwen36"), method(:exhausted_result)], answer_turn])

      expect_golden("continue_yes", output)
    end

    it "discards the interrupted turn on no" do
      output = run_session(model: "Qwen3-14B", prompts: ["go"], answers: ["no"],
                           turns: [[tool_round("qwen36"), method(:exhausted_result)]])

      expect_golden("continue_no", output)
    end

    it "records the reason on no, <reason>" do
      output = run_session(model: "Qwen3-14B", prompts: ["go", "next"], answers: ["no, too slow"],
                           turns: [[tool_round("qwen36"), method(:exhausted_result)], answer_turn])

      expect_golden("continue_no_reason", output)
    end

    it "keeps !cmd output in the next turn's context" do
      allow(Samagotchi::Tools::Execute).to receive(:call).with("echo hi").and_return("hi\n")

      output = run_session(model: "Qwen3-14B", prompts: ["!echo hi", "what did it print?"], turns: [answer_turn])

      expect_golden("bang_command", output)
    end

    it "answers !rollback after a Ctrl-C" do
      cancel = lambda do |messages|
        Samagotchi::KernelLoop::Result.new(
          output: "", conversation: messages + [{ role: "model", content: "Partial\n[interrupted]", interrupted: true }],
          exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: true, cancellation_reason: :ctrl_c
        )
      end

      output = run_session(model: "Qwen3-14B", prompts: ["go", "!rollback", "again"],
                           turns: [[generation("qwen36", "<think>hmm</think>").first(2), cancel], answer_turn])

      expect_golden("ctrl_c_rollback", output)
    end

    it "has nothing to roll back once !cmd output followed the Ctrl-C" do
      allow(Samagotchi::Tools::Execute).to receive(:call).with("echo hi").and_return("hi\n")
      cancel = lambda do |messages|
        Samagotchi::KernelLoop::Result.new(
          output: "", conversation: messages + [{ role: "model", content: "Partial\n[interrupted]", interrupted: true }],
          exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: true, cancellation_reason: :ctrl_c
        )
      end

      output = run_session(model: "Qwen3-14B", prompts: ["go", "!echo hi", "!rollback"],
                           turns: [[generation("qwen36", "<think>hmm</think>").first(2), cancel]])

      expect_golden("ctrl_c_bang_rollback", output)
    end

    it "runs a due reminder as a synthetic turn" do
      setup = lambda do |ui|
        engine = ui.instance_variable_get(:@engine)
        engine.reminder_store.register({ name: "tick", description: "Say TICK", interval_minutes: 1 })
        engine.reminder_store.instance_variable_get(:@mutex).synchronize do
          engine.reminder_store.reminders["tick"][:next_fire_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1
        end
        engine.note_due_reminders(["tick"])
      end
      tick = [generation("qwen36", "TICK"), ->(messages) { result_for(messages, output: "TICK") }]

      output = run_session(model: "Qwen3-14B", prompts: [], turns: [tick], setup: setup)

      expect_golden("reminder_turn", output)
    end
  end

  it "shows the tools a round runs and their tally" do
    calls = %w[ls pwd date].each_with_index.flat_map do |command, index|
      activity = { action: "running command", tool: "execute", params: "command=\"#{command}\"", status: "ok" }
      [{ type: :tool_call_started, iteration: 1, call_count: 3, call_index: index + 1, tool: "execute",
         call: { name: "execute", content: command }, params: "command=\"#{command}\"" },
       { type: :tool_call_completed, iteration: 1, call_count: 3, call_index: index + 1, tool: "execute",
         output: "", output_truncated: false, activity: activity }]
    end
    events = generation("qwen36", "<think>look around</think>", "<tool_call>…</tool_call>") +
             [{ type: :tool_dispatch_started, iteration: 1, call_count: 3 }] + calls +
             [{ type: :tool_dispatch_completed, iteration: 1, call_count: 3 }] +
             generation("qwen36", "Looked.", iteration: 2)

    output = run_turn(model: "Qwen3-14B", events: events) { |messages| result_for(messages, output: "Looked.") }

    expect_golden("tool_tally", output)
  end

  it "shows the answer a steering merge follows and the merge note" do
    events = generation("qwen36", "First part.") +
             [{ type: :pending_input_merged, iteration: 1, count: 1, answer: "First part." }] +
             generation("qwen36", "Second part.", iteration: 2)

    output = run_turn(model: "Qwen3-14B", events: events) { |messages| result_for(messages, output: "Second part.") }

    expect_golden("steering_merge", output)
  end

  it "shows a plugin's init task before and during a turn" do
    task = { bundle: "mcp", id: "mcp-1", label: "starting servers" }
    engine = nil
    setup = lambda do |ui|
      engine = ui.instance_variable_get(:@engine)
      engine.announce({ type: :plugin_init_started, **task })
    end
    events = [{ type: :plugin_init_wait, tasks: [task] }] + generation("qwen36", "Ready.")
    finish = lambda do |messages|
      engine.announce({ type: :plugin_init_finished, **task, ok: true, summary: "2 servers" })
      result_for(messages, output: "Ready.")
    end

    output = run_session(model: "Qwen3-14B", prompts: ["hi"], turns: [[events, finish]], setup: setup)

    expect_golden("init_task", output)
  end

  it "restores the prompt after the network retries run out" do
    events = [{ type: :generation_started, iteration: 1 }]
    error = Samagotchi::Client::RetryExhausted.new(attempts: 4, last_error: Errno::ECONNREFUSED.new)

    output = run_turn(model: "Qwen3-14B", events: events) { |_messages| raise error }

    expect_golden("retry_exhausted", output)
  end

  it "prints a provider error's one line and restores the prompt" do
    events = [{ type: :generation_started, iteration: 1 }]
    error = Samagotchi::LLM::AuthError.new("fw: set FW_KEY (the API key for host fw)", host: "fw")

    output = run_turn(model: "Qwen3-14B", events: events) { |_messages| raise error }

    expect(output).to include("model> auth failed for host fw: set FW_KEY (the API key for host fw); prompt restored for retry")
    expect_golden("provider_error", output)
  end
end
