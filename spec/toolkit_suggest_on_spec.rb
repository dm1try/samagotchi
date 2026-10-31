# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/system_one/client"
require "samagotchi/system_one/fake_backend"
require "samagotchi/terminal_ui/event_renderer"
require "support/thinking_off"
require "support/test_kernel"

# toolkit.suggest.mode: on — the first eligible turn joins System 1's
# toolkit ask before apply_toolkit!, so its first request declares the
# suggested kit; every other outcome is the default, as before.
RSpec.describe Samagotchi::Engine, "toolkit suggestion on mode" do
  include_context "thinking off"

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:events) { [] }
  let(:declared) { [] }
  let(:tmp) { Dir.mktmpdir("toolkit-on") }
  let(:state_dir) { File.join(tmp, "sessions").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:defer_turns) { 3 }
  let(:answers) { [] }
  let(:asked) { [] }
  let(:backend) do
    Samagotchi::SystemOne::FakeBackend.new do |state, _questions|
      asked << state
      answer = answers.shift
      answer.respond_to?(:call) ? answer.call : answer
    end
  end
  let(:system_one) { Samagotchi::SystemOne::Client.new(backend: backend, mode: "on", host: "judge", tag: :toolkit) }

  around do |example|
    original = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    example.run
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original
  end

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(Samagotchi::Toolkit).to receive(:config_kits).and_return({
      "web" => { "base" => "lean", "add" => ["delegate"], "description" => "Browser work" },
      "coding" => { "base" => "child", "description" => "Code changes" }
    })
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("toolkit.suggest.mode").and_return("on")
    allow(Samagotchi::Config).to receive(:get).with("toolkit.suggest.threshold").and_return(0.5)
    allow(Samagotchi::Config).to receive(:get).with("toolkit.suggest.defer_turns") { defer_turns }
    allow(Samagotchi::Config).to receive(:get).with("toolkit.suggest.defer_tokens").and_return(5000)
    allow(Samagotchi::SystemOne::Client).to receive(:from_config).and_return(system_one)
    allow(kernel).to receive(:run) do |messages, **|
      declared << kernel.tools.names
      Samagotchi::LLM::ModelResult.new(text: "ok", conversation: messages.reject { |m| m[:role].to_s == "system" } +
                                                                 [{ role: "model", content: "ok" }],
                                       exhausted: false, pending_tool_calls: false, tool_activity: [])
    end
  end

  after do
    @engine&.shutdown
    FileUtils.rm_rf(tmp)
  end

  def engine
    @engine ||= described_class.new(client: client, kernel: kernel, profile: "gemma4").tap do |e|
      e.session_state_dir = state_dir
    end
  end

  def session(origin: "default")
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd).tap do |s|
      s.toolkit = Samagotchi::Toolkit.new(name: "full")
      s.toolkit_origin = origin
    end
  end

  def pick(choice, confidence)
    { "toolkit" => Samagotchi::SystemOne::Answer.new(id: "toolkit", type: :choice, choice: choice, confidence: confidence) }
  end

  def turn(sess, prompt = "Fix the browser flow", **)
    engine.run_turn(sess, prompt, on_event: ->(event) { events << event }, **)
  end

  def log_lines
    path = File.join(File.dirname(state_dir), Samagotchi::ToolkitSuggest::FILE)
    File.exist?(path) ? File.readlines(path).map { |line| JSON.parse(line) } : []
  end

  def notices = events.select { |e| e[:type] == :hook_notice && e[:hook] == "toolkit" }

  def full_tools = Samagotchi::Tools::Builtins.default.names

  it "starts the session on a confidently picked kit: saved as suggested, declared by the first request, and said" do
    answers << pick("kit:web", 0.71)
    sess = session

    turn(sess)

    expect(sess.toolkit).to eq(Samagotchi::Toolkit.new(name: "web"))
    expect(sess.toolkit_origin).to eq("suggested")
    saved = Samagotchi::Session.load(sess.id, state_dir: state_dir)
    expect([saved.toolkit.name, saved.toolkit_origin]).to eq(%w[web suggested])
    expect(declared.first).to include("delegate")
    expect(declared.first).not_to eq(full_tools)
    expect(declared.first.sort).to eq(kernel.tools.names.sort)
    expect(kernel.tools.toolkit.name).to eq("web")
    expect(notices.map { |e| e[:text] }).to eq(["toolkit: web (suggested, p=0.71) · /toolkit to change"])
    expect(notices.first[:toolkit]).to include(name: "web")
    expect(log_lines.last).to include("would" => "suggested", "did" => "suggested", "kit" => "web")
  end

  it "keeps the default below the threshold, logging what it did" do
    answers << pick("kit:web", 0.3)
    sess = session

    turn(sess)

    expect([sess.toolkit.name, sess.toolkit_origin]).to eq(%w[full default])
    expect(declared.first).to eq(full_tools)
    expect(notices).to be_empty
    expect(log_lines.last).to include("would" => "below_threshold", "did" => "default")
  end

  it "defers on undecided, then switches from the next prompt within the window, saying from this turn" do
    answers << pick("undecided", 0.9) << pick("kit:web", 0.8)
    sess = session

    turn(sess, "hi there")
    turn(sess, "now fix the browser flow")

    expect(declared[0]).to eq(full_tools)
    expect(declared[1]).to include("delegate")
    expect(declared[1]).not_to eq(full_tools)
    expect([sess.toolkit.name, sess.toolkit_origin]).to eq(%w[web suggested])
    expect(notices.map { |e| e[:text] }).to eq(["toolkit: web from this turn (suggested, p=0.80) · /toolkit to change"])
    expect(log_lines.map { |line| line["did"] }).to eq(%w[defer suggested])
  end

  context "with a defer window of one prompt" do
    let(:defer_turns) { 1 }

    it "doesn't ask again after undecided once the window has closed" do
      answers << pick("undecided", 0.9) << pick("kit:web", 0.8)
      sess = session

      turn(sess, "hi there")
      turn(sess, "now fix the browser flow")

      expect(asked.size).to eq(1)
      expect([sess.toolkit.name, sess.toolkit_origin]).to eq(%w[full default])
    end
  end

  it "runs the default with one :toolkit warn when System 1 fails" do
    failing = Samagotchi::SystemOne::Client.new(backend: Samagotchi::SystemOne::FakeBackend.new(failing: true),
                                                mode: "on", host: "judge", tag: :toolkit)
    allow(Samagotchi::SystemOne::Client).to receive(:from_config).and_return(failing)
    allow(Samagotchi::Log).to receive(:warn).and_call_original
    sess = session

    turn(sess)

    expect(Samagotchi::Log).to have_received(:warn).with(:toolkit, "system_one_failed", anything).once
    expect([sess.toolkit.name, sess.toolkit_origin]).to eq(%w[full default])
    expect(declared.first).to eq(full_tools)
    expect(log_lines.last).to include("would" => "no_judgment", "did" => "default")
    expect(notices.map { |e| [e[:level], e[:text]] })
      .to eq([[:warn, "toolkit: full (no suggestion: System 1 gave no answer) · /toolkit to change"]])
  end

  it "waits at most System 1's timeout, then runs the default (a warn, a notice); the late answer is logged as timeout" do
    allow(Samagotchi::SystemOne::Client).to receive(:configured_timeout_ms).and_return(100)
    allow(Samagotchi::Log).to receive(:warn).and_call_original
    release = Queue.new
    answers << -> { release.pop && pick("kit:web", 0.9) }
    sess = session

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    turn(sess)
    waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    expect(waited).to be < time_bound(2.0)
    expect(declared.first).to eq(full_tools)
    expect([sess.toolkit.name, sess.toolkit_origin]).to eq(%w[full default])
    expect(Samagotchi::Log).to have_received(:warn)
      .with(:toolkit, "toolkit_suggest_timeout", hash_including(session_id: sess.id, timeout_ms: 100)).once
    expect(notices.map { |e| [e[:level], e[:text]] })
      .to eq([[:warn, "toolkit: full (no suggestion: System 1 took over 100 ms) · /toolkit to change"]])
    release << true
    join!(engine.instance_variable_get(:@side_judgments).thread(:toolkit), "the toolkit ask")
    expect(log_lines.last).to include("would" => "suggested", "did" => "timeout")
  ensure
    release << true
  end

  it "ends the turn before the model when a Stop comes during the wait, and cuts the ask's request" do
    entered = Queue.new
    waiting = Queue.new
    release = Queue.new
    answers << -> { (entered << true) && release.pop && pick("kit:web", 0.9) }
    allow(system_one).to receive(:ask).and_call_original
    allow_any_instance_of(Samagotchi::ToolkitSuggest::Pending).to receive(:wait).and_wrap_original do |original, ctrl|
      waiting << true
      original.call(ctrl)
    end
    controller = Samagotchi::CancellationController.new
    sess = session

    stopper = Thread.new do
      pop!(entered, "the toolkit ask")
      pop!(waiting, "the turn to wait for it")
      controller.cancel!(:manual)
    end
    result = turn(sess, cancel_controller: controller)
    join!(stopper, "the Stop")

    expect(system_one).to have_received(:ask) { |**kw| expect(kw[:cancel_controller]).to be_cancelled }
    expect(declared).to be_empty
    expect(events.map { |e| e[:type] }).to include(:turn_canceled)
    expect(result).not_to be_nil
    expect([sess.toolkit.name, sess.toolkit_origin]).to eq(%w[full default])
    release << true
    join!(engine.instance_variable_get(:@side_judgments).thread(:toolkit), "the toolkit ask")
    expect(log_lines.last).to include("did" => "canceled")
  ensure
    release << true
  end

  it "logs a Stop that came before the wait (during the probes) as canceled too" do
    release = Queue.new
    answers << -> { release.pop && pick("kit:web", 0.9) }
    controller = Samagotchi::CancellationController.new
    allow(engine).to receive(:refresh_profile!).and_wrap_original do |original|
      controller.cancel!(:manual)
      original.call
    end

    turn(session, cancel_controller: controller)
    release << true
    join!(engine.instance_variable_get(:@side_judgments).thread(:toolkit), "the toolkit ask")

    expect(declared).to be_empty
    expect(log_lines.last).to include("did" => "canceled")
  ensure
    release << true
  end

  it "never asks a session whose toolkit was chosen (/toolkit, ctx.use_toolkit)" do
    sess = session(origin: "chosen")

    turn(sess)

    expect(asked).to be_empty
    expect(declared.first).to eq(full_tools)
  end

  it "doesn't switch when the user chose a toolkit while it was asked" do
    sess = session
    answers << lambda {
      sess.toolkit_origin = "chosen"
      pick("kit:web", 0.9)
    }

    turn(sess)

    expect(sess.toolkit.name).to eq("full")
    expect(notices).to be_empty
    expect(log_lines.last).to include("would" => "suggested", "did" => "chosen")
  end

  it "asks no participant's turn" do
    sess = session
    origin = Samagotchi::TurnOrigin.new(author: "participant:p1")

    turn(sess, origin: origin)

    expect(asked).to be_empty
  end

  def ask_thread = engine.instance_variable_get(:@side_judgments).thread(:toolkit)

  it "lets a Stop win over an answer already in: no switch, the line says canceled (M1)" do
    answers << pick("kit:web", 0.9)
    controller = Samagotchi::CancellationController.new
    allow(engine).to receive(:apply_staged_tools!).and_wrap_original do |original|
      join!(ask_thread, "the toolkit ask")
      controller.cancel!(:manual)
      original.call
    end
    sess = session

    turn(sess, cancel_controller: controller)

    expect(declared).to be_empty
    expect([sess.toolkit.name, sess.toolkit_origin]).to eq(%w[full default])
    expect(notices).to be_empty
    expect(log_lines.last).to include("would" => "suggested", "did" => "canceled")
  end

  it "keeps a late ask going when the turn is stopped after its timeout, and logs it as timeout (L1)" do
    allow(Samagotchi::SystemOne::Client).to receive(:configured_timeout_ms).and_return(50)
    release = Queue.new
    seen = Queue.new
    allow(system_one).to receive(:ask).and_wrap_original do |original, **kw|
      seen << kw[:cancel_controller]
      original.call(**kw)
    end
    answers << -> { release.pop && pick("kit:web", 0.9) }
    controller = Samagotchi::CancellationController.new
    allow(kernel).to receive(:run) do |messages, **|
      # A Stop while the model runs, after the toolkit wait timed out.
      controller.cancel!(:manual)
      Samagotchi::LLM::ModelResult.new(text: "ok", conversation: messages + [{ role: "model", content: "ok" }],
                                       exhausted: false, pending_tool_calls: false, tool_activity: [])
    end

    turn(session, cancel_controller: controller)
    ask_controller = pop!(seen, "the ask's controller")
    release << true
    join!(ask_thread, "the toolkit ask")

    expect(ask_controller).not_to be_cancelled
    expect(log_lines.last).to include("did" => "timeout")
  ensure
    release << true
  end

  it "logs an ask whose turn was interrupted before it settled as failed (L1)" do
    answers << pick("kit:web", 0.9)
    allow(engine).to receive(:refresh_profile!) do
      join!(ask_thread, "the toolkit ask")
      raise Interrupt
    end
    sess = session

    expect { turn(sess) }.to raise_error(Interrupt)
    expect(sess.toolkit_origin).to eq("default")
    expect(log_lines.last).to include("did" => "failed")
  end

  it "doesn't switch when the save fails: the session keeps its default, the line says failed (L1)" do
    answers << pick("kit:web", 0.9)
    sess = session
    allow(sess).to receive(:save).and_call_original
    allow(sess).to receive(:save).with(state_dir: state_dir).and_wrap_original do |original, **kw|
      raise Errno::ENOSPC if sess.toolkit_origin == "suggested"

      original.call(**kw)
    end
    allow(Samagotchi::Log).to receive(:warn).and_call_original

    turn(sess)

    expect([sess.toolkit.name, sess.toolkit_origin]).to eq(%w[full default])
    expect(declared.first).to eq(full_tools)
    expect(Samagotchi::Log).to have_received(:warn).with(:toolkit, "toolkit_suggest_failed", anything)
    expect(log_lines.last).to include("did" => "failed")
  end

  it "says unavailable when the picked kit is gone by the time it applies (L3)" do
    answers << pick("kit:web", 0.9)
    binding = engine.instance_variable_get(:@toolkit_binding)
    calls = 0
    allow(binding).to receive(:kits).and_wrap_original do |original, *args|
      calls += 1
      kits = original.call(*args)
      calls == 1 ? kits : kits.except("web")
    end
    sess = session

    turn(sess)

    expect(sess.toolkit_origin).to eq("default")
    expect(log_lines.last).to include("did" => "unavailable")
  end

  context "when System 1 shares the model's local single-slot host (M2)" do
    before do
      allow(engine).to receive(:toolkit_judge_shares_local_host?).and_return(true)
      allow(Samagotchi::Log).to receive(:info).and_call_original
    end

    it "asks on the first turn, but not on the deferred path" do
      answers << pick("undecided", 0.9) << pick("kit:web", 0.9)
      sess = session

      turn(sess, "hi there")
      turn(sess, "now fix the browser flow")

      expect(asked.size).to eq(1)
      expect(Samagotchi::Log).to have_received(:info).with(:toolkit, "toolkit_suggest_shared_host_skipped",
                                                           hash_including(host: "judge"))
      expect(sess.toolkit_origin).to eq("default")
    end

    it "doesn't warm up" do
      engine.session = session

      engine.warm_toolkit_suggestion!

      expect(engine.instance_variable_get(:@toolkit_warmup_thread)).to be_nil
    end
  end

  it "stops a still-running warm-up when the first real ask starts, so it never queues behind it (M3)" do
    release = Queue.new
    entered = Queue.new
    answers << -> { (entered << true) && release.pop && nil } << pick("kit:web", 0.9)
    sess = session
    engine.session = sess
    engine.warm_toolkit_suggestion!
    warmup = engine.instance_variable_get(:@toolkit_warmup_thread)
    pop!(entered, "the warm-up ask")

    turn(sess)

    expect(warmup).not_to be_alive
    expect(sess.toolkit_origin).to eq("suggested")
  ensure
    release << true
  end

  it "shows the notice in the TUI as the toolkit's own line" do
    line = Samagotchi::TerminalUI::EventRenderer.hook_notice_line(
      { hook: "toolkit", level: :info, text: Samagotchi::ToolkitBinding.suggestion_notice("web", 0.71, deferred: false) }
    )

    expect(line).to eq("toolkit> toolkit: web (suggested, p=0.71) · /toolkit to change")
  end

  describe "#warm_toolkit_suggestion!" do
    it "asks once with the real question and a stand-in prompt, logging nothing" do
      answers << pick("undecided", 0.9)
      sess = session
      engine.session = sess

      engine.warm_toolkit_suggestion!
      join!(engine.instance_variable_get(:@toolkit_warmup_thread), "the warm-up")

      expect(asked).to eq([{ project: File.basename(sess.project_root.to_s), prompt: Samagotchi::ToolkitSuggest::WARMUP_PROMPT }])
      expect(log_lines).to be_empty
    end

    it "doesn't warm a chosen session, one with a model reply, or one starting on its first prompt" do
      chosen = session(origin: "chosen")
      replied = session.tap { |s| s.messages << { role: "model", content: "ok" } }
      prompted = session.tap { |s| s.last_prompt = "fix it" }

      [chosen, replied, prompted].each do |s|
        engine.session = s
        engine.warm_toolkit_suggestion!
      end

      expect(engine.instance_variable_get(:@toolkit_warmup_thread)).to be_nil
      expect(backend.calls).to eq(0)
    end

    it "doesn't warm in audit mode" do
      allow(Samagotchi::Config).to receive(:get).with("toolkit.suggest.mode").and_return("audit")
      engine.session = session

      engine.warm_toolkit_suggestion!

      expect(engine.instance_variable_get(:@toolkit_warmup_thread)).to be_nil
    end
  end
end
