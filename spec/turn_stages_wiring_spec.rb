# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/system_one/client"
require "samagotchi/system_one/fake_backend"
require "samagotchi/system_one/runs"
require "support/thinking_off"
require "support/test_kernel"

# The turn stages' wiring in a real Engine (docs/internals/engine.md, "Turn
# stages"): when each stage is called, on which thread and for which turn,
# among the turn's own steps, and what System 1's saved runs say. Each stage
# and step is spied with and_wrap_original, so this holds whatever the
# stages' call signatures are: it is the proof that moving their inputs
# from callbacks to values changed nothing a turn does.
RSpec.describe Samagotchi::Engine, "turn stages' wiring" do
  include_context "thinking off"

  let(:dir) { Dir.mktmpdir("turn-stages-wiring") }
  let(:state_dir) { File.join(dir, "sessions").tap { |d| FileUtils.mkdir_p(d) } }
  let(:calls) { [] }
  let(:announced) { Queue.new }
  let(:store) { Samagotchi::SystemOne::Runs::MemoryStore.new }
  let(:runs) { Samagotchi::SystemOne::Runs.new(store: store) }
  let(:answer_text) { "Done: the checkout moved over. #{"It holds. " * 60}" }
  let(:prompt) { "Please also move the coffee order to the new payment provider" }
  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:backend) do
    Samagotchi::SystemOne::FakeBackend.new do |_state, questions|
      Array(questions).to_h do |question|
        answer = case question.id
                 when "toolkit" then Samagotchi::SystemOne::Answer.new(id: "toolkit", type: :choice, choice: "undecided", confidence: 0.9)
                 else Samagotchi::SystemOne::Answer.new(id: question.id, type: :noul, noul: 0.1)
                 end
        [question.id, answer]
      end
    end
  end

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
    allow(Samagotchi::Config).to receive(:get).with("toolkit.suggest.mode").and_return("audit")
    allow(Samagotchi::Config).to receive(:get).with("context.candidates.mode").and_return("audit")
    allow(Samagotchi::Config).to receive(:get).with("objectives.system_one").and_return("audit")
    allow(Samagotchi::SystemOne::Client).to receive(:from_config) do |mode: nil, tag: :system_one, **|
      Samagotchi::SystemOne::Client.new(backend: backend, mode: mode || "audit", host: "judge", model: "jev", tag: tag)
    end
    allow(Samagotchi::PromptWarmup).to receive(:enabled?).and_return(false)
    allow(kernel).to receive(:run) do |messages, **|
      @in_generation&.call
      # The system head off, the objectives note kept.
      Samagotchi::LLM::ModelResult.new(text: answer_text, conversation: messages.drop(1) + [{ role: "model", content: answer_text }],
                                       exhausted: false, pending_tool_calls: false, tool_activity: [])
    end
  end

  after do
    @engine&.shutdown
    FileUtils.rm_rf(dir)
  end

  def engine
    @engine ||= described_class.new(client: client, kernel: kernel, model_name: "Gemma-4B-it").tap do |e|
      e.session_state_dir = state_dir
      allow(e).to receive(:system_one_runs).and_return(runs)
      e.subscribe(observer: ->(event) { announced << [event, Thread.current] if event[:type] == :objectives_updated })
    end
  end

  def objectives_note(text = "move the coffee order", note_id: "n1")
    Samagotchi::ContextNote.message(note_id: note_id, text: "O1 #{text}", source: "objectives",
                                    header: Samagotchi::ContextNote::OBJECTIVES_HEADER,
                                    objectives: { "next" => 2, "items" => [{ "id" => "O1", "text" => text, "status" => "active" }] })
  end

  def new_session
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: dir).tap do |s|
      s.toolkit = Samagotchi::Toolkit.new(name: "full")
      s.toolkit_origin = "default"
      s.continues = "the-session-before"
      s.test_run = true
      s.messages = [objectives_note]
      s.save(state_dir: state_dir)
    end
  end

  def propose(session, name = "pr-412")
    Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir).add_candidate(
      Samagotchi::ContextSources::Candidate.new(name: name, url: nil, cmd: "printf x", title: "##{name} the payment provider move",
                                                describe: nil, mentions: [], proposed_by: "plugin:test", at: "2026-10-31T10:00:00Z")
    )
  end

  # A spy on +object+'s +name+ that logs [label, :turn or :other, turn id]
  # and calls through; +also+ runs first (a Stop at that step).
  def spy(object, name, label, also: nil)
    allow(object).to receive(name).and_wrap_original do |original, *args, **kwargs, &block|
      first = args.first
      turn_id = first.respond_to?(:prepared_settings) ? first.id : nil
      reason = name == :abandon ? "(#{args[1]})" : ""
      calls << ["#{label}#{reason}", Thread.current.equal?(@turn_thread) ? :turn : :other, turn_id]
      also&.call
      original.call(*args, **kwargs, &block)
    end
  end

  def spy_all(stops: {})
    stages = { "verify" => [engine.send(:verify_anchors), %i[verified stamp_opening record_verdict]],
               "toolkit" => [engine.send(:toolkit_suggestion), %i[start settle abandon finish]],
               "judge" => [engine.send(:context_judge), %i[start late_candidates show_cards_after_turn]],
               "objectives" => [engine.send(:objectives_stage), %i[incoming outgoing announce note finally]],
               "warmup" => [engine.send(:turn_warmup), %i[after]] }
    stages.each { |prefix, (stage, names)| names.each { |name| spy(stage, name, "#{prefix}.#{name}") } }
    %i[refresh_profile! announce_guardrail_failures start_init_tasks! apply_staged_tools! apply_toolkit!
       refresh_participants! turn_messages generate replace_session_messages emit_working_set complete_turn
       release_turn].each { |name| spy(engine, name, name.to_s, also: stops[name]) }
    %i[session_start before_turn after_turn session_end].each do |hook|
      engine.register_hook(hook) { |_event| calls << ["hook.#{hook}", Thread.current.equal?(@turn_thread) ? :turn : :other, nil] }
    end
  end

  def run(session, text = prompt, **)
    @turn_thread = Thread.current
    @events = []
    on_event = lambda do |event|
      @events << event
      calls << ["event.#{event[:type]}", :turn, event[:turn_id]] if event[:type].to_s.start_with?("turn_")
    end
    engine.run_turn(session, text, on_event: on_event, **)
  ensure
    settle
  end

  # The side asks a turn started, joined.
  def settle
    return unless @engine

    threads = [engine.send(:toolkit_suggestion).ask_thread, engine.send(:context_judge).asks_thread,
               engine.send(:objectives_stage).audit_thread(:objectives_incoming),
               engine.send(:objectives_stage).audit_thread(:objectives_outgoing)]
    threads.compact.each { |thread| join!(thread, "a side ask") }
  end

  def labels = calls.map(&:first)

  def run_fields(judgment)
    Array(store.lines[judgment]).map { |line| line.slice("judgment", "session_id", "session_model", "mode", "chain_link", "test_run") }
  end

  def expected_run(judgment, session, mode:, model: "Gemma-4B-it")
    { "judgment" => judgment, "session_id" => session.id, "session_model" => model, "mode" => mode,
      "chain_link" => "the-session-before", "test_run" => true }
  end

  PREPARE = %w[verify.verified event.turn_started toolkit.start refresh_profile! announce_guardrail_failures
               start_init_tasks! apply_staged_tools! toolkit.settle judge.start objectives.incoming apply_toolkit!
               refresh_participants!].freeze
  FIRST_HOOKS = %w[hook.session_start hook.before_turn turn_messages toolkit.abandon(failed) toolkit.finish].freeze
  ENDING = ->(type) { %W[verify.stamp_opening replace_session_messages verify.record_verdict emit_working_set objectives.announce event.#{type}] }
  ENSURE = %w[release_turn judge.show_cards_after_turn objectives.finally].freeze

  it "calls each stage in the turn's order, on the turn thread, for the turn; saves the runs as before" do
    session = new_session
    propose(session)
    spy_all

    run(session)

    expect(labels).to eq(PREPARE + FIRST_HOOKS + %w[generate complete_turn] + ENDING.call("turn_completed") +
                         %w[objectives.outgoing hook.after_turn hook.session_end warmup.after] + ENSURE)
    expect(calls.map { |call| call[1] }.uniq).to eq([:turn])
    turn_id = @events.find { |event| event[:type] == :turn_started }[:turn_id]
    expect(calls.filter_map { |call| call[2] }.uniq).to eq([turn_id])
    expect(run_fields("toolkit.suggest")).to eq([expected_run("toolkit.suggest", session, mode: "audit")])
    expect(run_fields("context.candidate")).to eq([expected_run("context.candidate", session, mode: "audit")])
    expect(run_fields("objectives.incoming")).to eq([expected_run("objectives.incoming", session, mode: "audit")])
    expect(run_fields("objectives.outgoing")).to eq([expected_run("objectives.outgoing", session, mode: "audit")])
  end

  it "ends at STOP CHECK A (a Stop during the probes): the suggestion abandoned, nothing past the probes" do
    session = new_session
    controller = Samagotchi::CancellationController.new
    spy_all(stops: { refresh_profile!: -> { controller.cancel!(:user) } })

    run(session, cancel_controller: controller)

    expect(labels).to eq(%w[verify.verified event.turn_started toolkit.start refresh_profile! toolkit.abandon(canceled)
                            toolkit.abandon(failed) toolkit.finish] +
                         (ENDING.call("turn_canceled") - %w[replace_session_messages]) + ENSURE)
    expect(store.lines.keys).to eq(["toolkit.suggest"])
  end

  it "ends at STOP CHECK B (a Stop in the waits): every stage before it called, no hook" do
    session = new_session
    controller = Samagotchi::CancellationController.new
    spy_all(stops: { refresh_participants!: -> { controller.cancel!(:user) } })

    run(session, cancel_controller: controller)

    expect(labels).to eq(PREPARE + %w[toolkit.abandon(failed) toolkit.finish] +
                         (ENDING.call("turn_canceled") - %w[replace_session_messages]) + ENSURE)
  end

  it "ends a failed turn without the outgoing audit or the warm-up" do
    session = new_session
    @in_generation = -> { raise "the model is gone" }
    spy_all

    expect { run(session) }.to raise_error(RuntimeError, "the model is gone")

    expect(labels).to eq(PREPARE + FIRST_HOOKS + %w[generate] + ENDING.call("turn_failed") + ENSURE)
    expect(run_fields("objectives.outgoing")).to eq([])
  end

  it "calls the stages for a participant's turn, which ask nothing" do
    session = new_session
    propose(session)
    spy_all

    run(session, origin: { author: "p:guest" })

    expect(labels).to include("judge.start", "objectives.incoming", "objectives.outgoing", "warmup.after")
    expect(store.lines).to be_empty
  end

  it "records incoming on the model the turn started on and outgoing on the one a before_turn hook switched to" do
    session = new_session
    engine.register_hook(:before_turn) { |_event| allow(engine).to receive(:effective_model_name).and_return("Gemma-12B-it") }

    run(session)

    expect(run_fields("objectives.incoming")).to eq([expected_run("objectives.incoming", session, mode: "audit")])
    expect(run_fields("objectives.outgoing")).to eq([expected_run("objectives.outgoing", session, mode: "audit", model: "Gemma-12B-it")])
  end

  it "makes no audit ask with runs off: no client, no run" do
    session = new_session
    allow(engine).to receive(:system_one_runs).and_return(Samagotchi::SystemOne::Runs.new)

    run(session)

    tags = []
    expect(Samagotchi::SystemOne::Client).to have_received(:from_config).at_least(:once) { |tag: nil, **| tags << tag }
    expect(tags).not_to include(:system_one)
    expect(store.lines).to be_empty
  end

  it "asks with the plain client when the recording can't be set up, saving nothing, and the turn completes" do
    session = new_session
    propose(session)
    allow(Samagotchi::Log).to receive(:warn).and_call_original
    # Only where the recording reads it (the guardrails read it too).
    allow(engine).to receive(:effective_model_name).and_wrap_original do |original|
      raise "no model name" if caller_locations.any? { |at| at.label.to_s.include?("system_one_record") }

      original.call
    end

    result = run(session)

    expect(result.text).to eq(answer_text)
    expect(store.lines).to be_empty
    expect(Samagotchi::Log).to have_received(:warn).with(:system_one, "system_one_recording_failed", anything).at_least(:once)
    # The toolkit's ask and the judge's; no audit ask (Recorder::NONE saves
    # nothing, so the audit builds no client).
    expect(backend.calls).to eq(2)
    tags = []
    expect(Samagotchi::SystemOne::Client).to have_received(:from_config).at_least(:once) { |tag: nil, **| tags << tag }
    expect(tags).not_to include(:system_one)
  end

  it "judges a late candidate from a plugin's thread on the session's owner prompts" do
    session = new_session
    session.messages << { role: "user", turn_id: "t0", content: prompt } << { role: "model", content: "ok" }
    engine.session = session
    propose(session)
    spy_all

    Thread.new { engine.send(:judge_late_candidates) }.join
    settle

    expect(calls).to eq([["judge.late_candidates", :other, nil]])
    expect(run_fields("context.candidate")).to eq([expected_run("context.candidate", session, mode: "audit")])
  end

  it "returns from a late candidate while the plugins load, before anything the Engine has yet to build" do
    seen = []
    allow_any_instance_of(described_class).to receive(:load_plugins) do |loading|
      seen << loading.instance_variable_get(:@session) << loading.instance_variable_get(:@session_observer)
      seen << loading.send(:judge_late_candidates)
    end

    engine

    expect(seen).to eq([nil, nil, nil])
  end

  it "announces the objectives from another thread while a turn runs, under the event lock" do
    session = new_session
    observer = engine.instance_variable_get(:@session_observer)
    reads = []
    allow(engine).to receive(:live_conversation).and_wrap_original do |original|
      reads << [Thread.current.equal?(@turn_thread), observer.instance_variable_get(:@mutex).mon_owned?]
      original.call
    end
    @in_generation = -> { Thread.new { engine.announce_objectives(session) }.join }

    run(session)

    event, thread = pop!(announced, "the objectives announced mid-turn")
    expect(event).to include(type: :objectives_updated, session_id: session.id)
    expect(thread).not_to equal(Thread.current)
    expect(reads.first).to eq([false, true])
  end

  it "announces the objectives between turns from another thread when they changed, once" do
    session = new_session
    run(session)
    pop!(announced, "the turn end's announce")
    session.messages = session.messages + [objectives_note("ship the payment provider", note_id: "n2")]

    Thread.new { 2.times { engine.announce_objectives(session) } }.join

    event, thread = pop!(announced, "the changed view")
    expect(event[:items].map { |item| item[:text] || item["text"] }).to include("ship the payment provider")
    expect(thread).not_to equal(Thread.current)
    expect(announced).to be_empty
  end

  it "logs a failing objectives announce instead of raising, between turns and at a turn's end" do
    session = new_session
    allow(Samagotchi::Log).to receive(:warn).and_call_original
    allow(engine).to receive(:live_conversation).and_raise("no conversation")

    expect { engine.announce_objectives(session) }.not_to raise_error
    result = run(session)

    expect(result.text).to eq(answer_text)
    expect(Samagotchi::Log).to have_received(:warn).with(:turn, "objectives_announce_failed", anything).twice
  end

  it "logs a failing proposal card instead of raising out of the turn's ensure" do
    session = new_session
    allow(Samagotchi::Log).to receive(:warn).and_call_original
    allow(engine).to receive(:show_card).and_raise("no card")
    @in_generation = lambda do
      engine.propose_objective(Samagotchi::Objectives::Proposal.new(change: "done", id: "O1", text: "", note: "it moved"))
    end

    expect(run(session).text).to eq(answer_text)
    expect(Samagotchi::Log).to have_received(:warn).with(:turn, "objectives_proposal_failed", anything)
  end

  describe "the warm-up's late reads" do
    let(:client) { test_client(warm_up: nil) }
    let(:probe) { [] }

    before do
      allow(Samagotchi::PromptWarmup).to receive(:enabled?).and_return(true)
      allow(engine.prompt_warmup).to receive(:start).and_return(false)
      engine.next_turn_waiting = lambda {
        probe << :asked
        false
      }
    end

    def after_turn_reads(&)
      reads = []
      ended = false
      allow(engine).to receive(:complete_turn).and_wrap_original do |original, *args|
        original.call(*args)
        ended = true
        yield if block_given?
      end
      allow(engine).to receive(:system_prompt).and_wrap_original do |original, *args|
        reads << :system_prompt if ended
        original.call(*args)
      end
      allow(engine).to receive(:record_prompt_notes).and_wrap_original do |original, *args|
        reads << :record_prompt_notes if ended
        original.call(*args)
      end
      run(new_session)
      reads + probe
    end

    it "builds the prompt and asks the probe only once it would warm up" do
      expect(after_turn_reads).to include(:system_prompt, :asked)
      expect(engine.prompt_warmup).to have_received(:start)
    end

    it "reads nothing late when the target is off" do
      allow(Samagotchi::PromptWarmup).to receive(:enabled?).and_return(false)

      expect(after_turn_reads).to eq([])
    end

    it "reads nothing late when a reminder is due" do
      queue = engine.instance_variable_get(:@reminder_queue)
      expect(after_turn_reads { allow(queue).to receive(:due?).and_return(true) }).to eq([])
    end

    it "reads nothing late when a steer is carried" do
      turn_state = engine.instance_variable_get(:@turn_state)
      expect(after_turn_reads { allow(turn_state).to receive(:carried_steers?).and_return(true) }).to eq([])
    end
  end
end
