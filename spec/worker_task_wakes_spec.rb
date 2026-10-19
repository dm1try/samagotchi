# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "support/test_kernel"

require "samagotchi/engine"
require "samagotchi/bridge"
require "samagotchi/worker"

# A background task this session started that finishes unseen wakes an idle
# worker for a short turn (session.task_wakes: wake), or leaves a plain note
# for the next turn (docs/internals/background-tasks.md, Finish wake).
RSpec.describe Samagotchi::Worker, "task finish wakes" do
  around do |example|
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    WebMock.allow_net_connect! if defined?(WebMock)
    example.run
  ensure
    WebMock.disable_net_connect! if defined?(WebMock)
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
  end

  let(:tmpdir) { Dir.mktmpdir("worker-task-wakes-spec") }
  let(:state_dir) { File.join(tmpdir, "samagotchi", "sessions").tap { |d| FileUtils.mkdir_p(d) } }
  let(:history) { [{ role: "system", content: "sys" }, { role: "user", content: "a" }, { role: "model", content: "b" }] }
  let!(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir).tap do |s|
      s.messages = history
      s.save(state_dir: state_dir)
    end
  end
  let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: state_dir) }
  let!(:engine) { Samagotchi::Engine.new(client: test_client, kernel: test_kernel) }
  let(:turns) { Queue.new }
  # Each turn's prompt, once its tools ran and it decided whether to fail.
  let(:turns_done) { Queue.new }
  let(:events) { [] }
  let(:result) { instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: false, resumable?: false) }
  # Results for the next turns, in order; then +result+.
  let(:results) { [] }
  let(:config) { { "session.max_wakes" => 10, "session.task_wakes" => "wake" } }
  # The tasks' records, by id (TaskRuntime.get_record's answer).
  let(:records) { {} }
  # What each prompt's turn does: its tools' results (TaskWatch's input).
  let(:scripts) { {} }

  before do
    stub_const("Samagotchi::Worker::WAKE_START_GRACE", 0)
    FileUtils.mkdir_p(File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR))
    allow(Samagotchi::Config).to receive(:get).and_call_original
    config.each_key { |key| allow(Samagotchi::Config).to receive(:get).with(key) { config[key] } }
    allow(Samagotchi::Tools::TaskRuntime).to receive(:get_record) do |id|
      records.key?(id) ? [records[id], nil] : [nil, "Error: task not found: #{id}"]
    end
    allow(Samagotchi::Engine).to receive(:new).and_return(engine)
    allow(engine).to receive(:start_idle)
    allow(engine).to receive(:stop_idle)
    allow(engine).to receive(:run_turn) do |turn_session, prompt, **kwargs|
      turns << [prompt, kwargs, turn_session.messages.last]
      emit(type: :turn_started, turn_id: kwargs[:id] || "turn-#{turns.size}")
      scripts.fetch(prompt, []).each { |step| step.call(turn_session) }
      failing = @fail_next
      @fail_next = false
      turns_done << prompt
      raise Samagotchi::LLM::ServerError.new("main: HTTP 500: boom", host: "main", status: 500) if failing

      results.shift || result
    end
    engine.subscribe(observer: ->(event) { events << event })
  end

  after do
    @thread&.kill
    @thread&.join(2)
    FileUtils.rm_rf(tmpdir)
  end

  def emit(event) = engine.instance_variable_get(:@session_observer).notify(event)

  def start_worker(poll_interval: 0.05, idle_exit_minutes: 0)
    worker = described_class.new(session_id: session.id, state_dir: state_dir, session_dir: session_dir,
                                 idle_exit_minutes: idle_exit_minutes, poll_interval: poll_interval)
    @thread = Thread.new { worker.run }
    @thread.report_on_exception = false
    expect(wait_until { File.exist?(File.join(session_dir, Samagotchi::WorkerSidecar::FILE)) }).to be(true)
    worker
  end

  def record(id, status: "running", exit_code: nil)
    output = File.join(tmpdir, "#{id}.log").tap { |p| File.write(p, "building\ndone\n") }
    Samagotchi::Tools::TaskRecord.running(id: id, command: "sleep 20; echo done", cwd: tmpdir, pid: 1,
                                          started_at: Time.now.iso8601, output_path: output,
                                          exit_code_path: File.join(tmpdir, "#{id}.exit"))
                                 .with(status: status, exit_code: exit_code)
  end

  def finish(id, exit_code: 0) = records[id] = record(id, status: "completed", exit_code: exit_code)

  # A step: a tool's result, in the conversation (+saved+) and as its event.
  # A block gives the output as the step runs.
  def tool(name, output = nil, saved: true)
    lambda do |turn_session|
      output = yield if block_given?
      if saved
        turn_session.messages = turn_session.messages + [{ role: "tool_response", content: "[#{name}]\n#{output}" }]
      end
      emit(type: :tool_call_completed, tool: name, output: output)
    end
  end

  def task_create(id, saved: true)
    records[id] = record(id)
    tool("task_create", "task_id: #{id}\nstatus: running\noutput_path: tmp/tasks/#{id}/output.log", saved: saved)
  end

  def task_wait(id, wait_result: nil)
    tool("task_wait") do
      ["task_id: #{id}", "status: #{records[id].status}", ("wait_result: #{wait_result}" if wait_result),
       "output_tail:", "done"].compact.join("\n")
    end
  end

  def stopped_by_user = ->(_) { emit(type: :turn_canceled, cancellation_reason: :user) }

  def send_turn(prompt, client_id: "web:tab1")
    Samagotchi::SessionManager.write_turn_input(session.id, prompt: prompt, client_id: client_id, state_dir: state_dir)
  end

  def run_prompt(prompt)
    send_turn(prompt)
    expect(turns.pop(timeout: 3)&.first).to eq(prompt)
    expect(turns_done.pop(timeout: 3)).to eq(prompt)
  end

  def saved_task_notes
    Samagotchi::Session.load(session.id, state_dir: state_dir).messages.select { |m| m[:note_id].to_s.start_with?("task-") }
  end

  def task_notices = events.select { |e| e[:type] == :hook_notice && e[:hook] == "task" }

  it "runs a wake turn from task:<id> once a task the model never looked at finishes, opened by its note" do
    scripts["build"] = [task_create("t1")]
    start_worker
    run_prompt("build")

    finish("t1")
    prompt, kwargs, last = turns.pop(timeout: 3)
    expect(prompt).to be_nil
    expect(kwargs).to include(continue: true, origin: { client_id: "task:t1" })
    expect(last).to include(role: "system", kind: "note", note_id: "task-t1", turn_start: true, turn_id: kwargs[:id])
    expect(last[:content]).to start_with("[TASK FINISHED from task t1, ").and include("Background task t1 finished: exit 0")
    expect(last[:content]).to include("command: sleep 20; echo done", "output_tail:\nbuilding\ndone",
                                      Samagotchi::TaskFinishNote::WAKE_TEXT)
    expect(wait_until { saved_task_notes.size == 1 }).to be(true)
    expect(turns.pop(timeout: 0.3)).to be_nil
  end

  it "builds the Engine with the tool descriptions' finish line, but not with session.task_wakes: off" do
    start_worker
    expect(Samagotchi::Engine).to have_received(:new).with(hash_including(task_finish_notes: true))
  end

  it "keeps the hand-over's limit for the note of an execute handed over as a task" do
    records["t2"] = record("t2")
    scripts["build"] = [tool("execute", "#{Samagotchi::Tools::Execute.handed_over_line(5)}\ntask_id: t2\nstdout_tail:\n")]
    start_worker
    run_prompt("build")

    finish("t2")
    _, kwargs, last = turns.pop(timeout: 3)
    expect(kwargs[:origin]).to eq({ client_id: "task:t2" })
    expect(last[:content]).to include("(handed over by execute at its 5s limit).")
  end

  it "doesn't wake for a task the model waited on to its end" do
    scripts["build"] = [task_create("t1"), ->(_) { finish("t1") }, task_wait("t1")]
    start_worker
    run_prompt("build")

    expect(turns.pop(timeout: 0.5)).to be_nil
    expect(saved_task_notes).to be_empty
  end

  it "only notes a task whose turn the user stopped: no wake turn undoes the Stop (M5)" do
    scripts["build"] = [task_create("t1"), task_wait("t1", wait_result: "canceled"), stopped_by_user]
    start_worker
    run_prompt("build")

    finish("t1")
    expect(wait_until { saved_task_notes.size == 1 }).to be(true)
    expect(saved_task_notes.first).not_to include(:turn_start)
    expect(saved_task_notes.first[:content]).not_to include("chi started this turn")
    expect(turns.pop(timeout: 0.3)).to be_nil
  end

  it "drops a task the user stopped with the stop-task button" do
    scripts["build"] = [task_create("t1")]
    start_worker
    run_prompt("build")

    records["t1"] = record("t1", status: "stopped").with(stop_reason: "stopped_by_user")
    sleep(0.3)
    expect(saved_task_notes).to be_empty
    expect(turns.pop(timeout: 0.2)).to be_nil
  end

  it "forgets a task whose result left the conversation (a !rollback, a restored turn)" do
    scripts["build"] = [task_create("t1", saved: false)]
    start_worker
    run_prompt("build")

    finish("t1")
    sleep(0.3)
    expect(saved_task_notes).to be_empty
    expect(turns.pop(timeout: 0.2)).to be_nil
  end

  it "writes a plain note for the next turn with session.task_wakes: queue" do
    config["session.task_wakes"] = "queue"
    scripts["build"] = [task_create("t1")]
    start_worker
    run_prompt("build")

    finish("t1")
    expect(wait_until { saved_task_notes.size == 1 }).to be(true)
    expect(saved_task_notes.first).not_to include(:turn_start)
    expect(turns.pop(timeout: 0.3)).to be_nil
  end

  it "watches nothing with session.task_wakes: off" do
    config["session.task_wakes"] = "off"
    scripts["build"] = [task_create("t1")]
    start_worker
    expect(Samagotchi::Engine).to have_received(:new).with(hash_including(task_finish_notes: false))
    run_prompt("build")

    finish("t1")
    sleep(0.3)
    expect(saved_task_notes).to be_empty
    expect(turns.pop(timeout: 0.2)).to be_nil
  end

  it "shares session.max_wakes: past it a finish is a plain note, and the UIs hear it once" do
    config["session.max_wakes"] = 1
    scripts["build"] = [task_create("t1"), task_create("t2"), task_create("t3")]
    start_worker
    run_prompt("build")

    finish("t1")
    expect(turns.pop(timeout: 3)&.dig(1, :origin)).to eq({ client_id: "task:t1" })
    finish("t2")
    expect(wait_until { saved_task_notes.size == 2 }).to be(true)
    finish("t3")
    expect(wait_until { saved_task_notes.size == 3 }).to be(true)
    expect(saved_task_notes.last(2)).to all(satisfy { |m| !m.key?(:turn_start) })
    expect(turns.pop(timeout: 0.3)).to be_nil
    expect(task_notices.map { |e| e[:text] })
      .to eq(["1 finished background task noted; the model reads it with your next message " \
              "(1 wake turn in a row, session.max_wakes)"])
  end

  it "pauses wakes after a failed wake turn, its note left as a plain one" do
    scripts["build"] = [task_create("t1"), task_create("t2")]
    start_worker
    run_prompt("build")

    @fail_next = true
    finish("t1")
    expect(turns.pop(timeout: 3)&.dig(1, :origin)).to eq({ client_id: "task:t1" })
    expect(wait_until { Samagotchi::Session.load(session.id, state_dir: state_dir).messages.last[:kind] == "turn_note" })
      .to be(true)
    expect(Samagotchi::Session.load(session.id, state_dir: state_dir).messages.last[:content])
      .to include("The wake turn for a finished background task (t1) was not answered")
    expect(saved_task_notes.first).not_to include(:turn_start, :turn_id)
    expect(saved_task_notes.first[:content]).not_to include("chi started this turn")

    finish("t2")
    expect(wait_until { saved_task_notes.size == 2 }).to be(true)
    expect(turns.pop(timeout: 0.3)).to be_nil
  end

  it "writes a plain note while a continue offer waits, and the offer's /continue still resumes" do
    resumable = instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: false, resumable?: true, run_start: 3,
                                                              conversation: nil, tool_activity: [])
    allow_any_instance_of(Samagotchi::TurnFlow).to receive(:interrupted_turn_context).and_return({})
    results << resumable
    scripts["build"] = [task_create("t1")]
    start_worker
    run_prompt("build")
    expect(wait_until { events.any? { |e| e[:type] == :continue_offered } }).to be(true)

    finish("t1")
    expect(wait_until { saved_task_notes.size == 1 }).to be(true)
    expect(saved_task_notes.first).not_to include(:turn_start)
    expect(turns.pop(timeout: 0.3)).to be_nil

    send_turn("/continue")
    prompt, kwargs, = turns.pop(timeout: 3)
    expect(prompt).to be_nil
    expect(kwargs).to include(continue: true)
    expect(kwargs.dig(:origin, :client_id)).not_to start_with("task:")
  end

  it "writes a plain note, no wake turn, for a task that finishes as an exit is asked for" do
    scripts["build"] = [task_create("t1")]
    worker = start_worker(poll_interval: 30)
    send_turn("build")
    worker.instance_variable_get(:@waker).wake
    expect(turns.pop(timeout: 3)&.first).to eq("build")
    expect(turns_done.pop(timeout: 3)).to eq("build")

    finish("t1")
    expect(worker.send(:exit_request, "web:tab")).to be_nil
    expect(@thread.join(5)&.value).to eq(:exit_requested)
    expect(saved_task_notes.size).to eq(1)
    expect(saved_task_notes.first).not_to include(:turn_start)
    expect(turns.pop(timeout: 0.2)).to be_nil
  end

  it "puts a task back when its note can't be written, and notes it on a later pass" do
    failures = [1]
    allow(engine).to receive(:add_context_note).and_wrap_original do |original, *args|
      raise IOError, "boom" if (failures[0] -= 1) >= 0

      original.call(*args)
    end
    scripts["build"] = [task_create("t1")]
    start_worker
    run_prompt("build")

    finish("t1")
    _, kwargs, last = turns.pop(timeout: 3)
    expect(kwargs[:origin]).to eq({ client_id: "task:t1" })
    expect(last).to include(note_id: "task-t1", turn_start: true)
  end

  it "gives a finished task to a prompt's turn as a plain note when the prompt comes first" do
    scripts["build"] = [task_create("t1")]
    worker = start_worker(poll_interval: 30)
    send_turn("build")
    worker.instance_variable_get(:@waker).wake
    expect(turns.pop(timeout: 3)&.first).to eq("build")

    finish("t1")
    send_turn("next")
    worker.instance_variable_get(:@waker).wake
    prompt, _, last = turns.pop(timeout: 3)
    expect(prompt).to eq("next")
    expect(last).to include(note_id: "task-t1")
    expect(last).not_to include(:turn_start)
    expect(turns.pop(timeout: 0.3)).to be_nil
  end

  it "keeps an idle worker up while a task it watches runs, and lets it go after the task's wake turn" do
    scripts["build"] = [task_create("t1")]
    start_worker(idle_exit_minutes: 0.002)
    run_prompt("build")

    expect(@thread.join(0.5)).to be_nil
    finish("t1")
    expect(turns.pop(timeout: 3)&.dig(1, :origin)).to eq({ client_id: "task:t1" })
    expect(@thread.join(5)&.value).to eq(:idle_exit)
  end

  it "doesn't hold the idle exit with session.task_wakes: queue (nothing would wake for the task)" do
    config["session.task_wakes"] = "queue"
    scripts["build"] = [task_create("t1")]
    start_worker(idle_exit_minutes: 0.002)
    run_prompt("build")

    expect(@thread.join(5)&.value).to eq(:idle_exit)
  end

  it "holds /exit while a watched task runs, saying how to stop it; not with session.task_wakes: queue" do
    scripts["build"] = [task_create("t1")]
    worker = start_worker
    run_prompt("build")

    expect(worker.send(:exit_request, "web:tab"))
      .to eq({ reason: :background_tasks, tasks: [{ id: "t1", command: "sleep 20; echo done" }],
               hint: Samagotchi::Worker::TASK_STOP_HINT })
    config["session.task_wakes"] = "queue"
    expect(worker.send(:exit_request, "web:tab")).to be_nil
  end
end
