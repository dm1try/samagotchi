# frozen_string_literal: true

require "spec_helper"
require "support/worker_loop_rounds"
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
  include WorkerLoopRounds

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
    @finished_turns = 0
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
      @finished_turns += 1
      turns_done << prompt
      raise Samagotchi::LLM::ServerError.new("main: HTTP 500: boom", host: "main", status: 500) if failing

      results.shift || result
    end
    engine.subscribe(observer: ->(event) { events << event })
  end

  after do
    @thread&.kill
    join!(@thread, "the worker thread") if @thread
    FileUtils.rm_rf(tmpdir)
  end

  def emit(event) = engine.instance_variable_get(:@session_observer).notify(event)

  def start_worker(poll_interval: 0.05, idle_exit_minutes: 0)
    worker = described_class.new(session_id: session.id, state_dir: state_dir, session_dir: session_dir,
                                 idle_exit_minutes: idle_exit_minutes, poll_interval: poll_interval)
    count_loop_rounds(worker)
    @thread = Thread.new { worker.run }
    @thread.report_on_exception = false
    wait_for("the worker's sidecar") { File.exist?(File.join(session_dir, Samagotchi::WorkerSidecar::FILE)) }
    worker
  end

  # A queue that gets an entry each time +worker+'s loop goes to sleep
  # (Waker#wait), the number of turns finished by then: with a long poll
  # interval, nothing runs after that until it is woken, so a spec can
  # change a task's record with no pass racing it.
  def parks(worker)
    Queue.new.tap do |parked|
      # In place of count_loop_rounds' wrap, so it counts the rounds too.
      allow(worker.instance_variable_get(:@waker)).to receive(:wait).and_wrap_original do |original, *args|
        @rounds[0] += 1
        parked << @finished_turns
        original.call(*args)
      end
    end
  end

  # Runs +prompt+'s turn on a worker with a long poll interval and returns
  # once its loop sleeps after it. A park from before the turn (counted
  # with fewer turns finished) is skipped: clearing the queue instead raced
  # the park after a fast turn away (CI run 39501273953). The waits only end
  # a hang (each returns as soon as its step is there).
  def run_prompt_to_sleep(worker, prompt)
    parked = parks(worker)
    after = @finished_turns + 1
    send_turn(prompt)
    worker.instance_variable_get(:@waker).wake
    expect(pop!(turns, "#{prompt}'s turn to start", timeout: 15).first).to eq(prompt)
    expect(pop!(turns_done, "#{prompt}'s turn to finish", timeout: 15)).to eq(prompt)
    what = "the worker's loop to sleep after #{prompt}'s turn"
    nil until pop!(parked, what, timeout: 15) >= after
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
    expect(pop!(turns, "#{prompt}'s turn to start", timeout: 15).first).to eq(prompt)
    expect(pop!(turns_done, "#{prompt}'s turn to finish", timeout: 15)).to eq(prompt)
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
    prompt, kwargs, last = pop!(turns, "the wake turn", timeout: 15)
    expect(prompt).to be_nil
    expect(kwargs).to include(continue: true, origin: Samagotchi::TurnOrigin.new(client_id: "task:t1"))
    expect(last).to include(role: "system", kind: "note", note_id: "task-t1", turn_start: true, turn_id: kwargs[:id])
    expect(last[:content]).to start_with("[TASK FINISHED from task t1, ").and include("Background task t1 finished: exit 0")
    expect(last[:content]).to include("command: sleep 20; echo done", "output_tail:\nbuilding\ndone",
                                      Samagotchi::TaskFinishNote::WAKE_TEXT)
    wait_for("the task's note to be saved") { saved_task_notes.size == 1 }
    loop_rounds
    expect(turns).to be_empty
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
    _, kwargs, last = pop!(turns, "the wake turn", timeout: 15)
    expect(kwargs[:origin]).to eq(Samagotchi::TurnOrigin.new(client_id: "task:t2"))
    expect(last[:content]).to include("(handed over by execute at its 5s limit).")
  end

  it "doesn't wake for a task the model waited on to its end" do
    scripts["build"] = [task_create("t1"), ->(_) { finish("t1") }, task_wait("t1")]
    start_worker
    run_prompt("build")

    loop_rounds
    expect(turns).to be_empty
    expect(saved_task_notes).to be_empty
  end

  it "only notes a task whose turn the user stopped: no wake turn undoes the Stop (M5)" do
    scripts["build"] = [task_create("t1"), task_wait("t1", wait_result: "canceled"), stopped_by_user]
    start_worker
    run_prompt("build")

    finish("t1")
    wait_for("the stopped turn's task note to be saved") { saved_task_notes.size == 1 }
    expect(saved_task_notes.first).not_to include(:turn_start)
    expect(saved_task_notes.first[:content]).not_to include("chi started this turn")
    loop_rounds
    expect(turns).to be_empty
  end

  it "drops a task the user stopped with the stop-task button" do
    scripts["build"] = [task_create("t1")]
    start_worker
    run_prompt("build")

    records["t1"] = record("t1", status: "stopped").with(stop_reason: "stopped_by_user")
    loop_rounds
    expect(saved_task_notes).to be_empty
    expect(turns).to be_empty
  end

  it "forgets a task whose result left the conversation (a !rollback, a restored turn)" do
    scripts["build"] = [task_create("t1", saved: false)]
    start_worker
    run_prompt("build")

    finish("t1")
    loop_rounds
    expect(saved_task_notes).to be_empty
    expect(turns).to be_empty
  end

  it "writes a plain note for the next turn with session.task_wakes: queue" do
    config["session.task_wakes"] = "queue"
    scripts["build"] = [task_create("t1")]
    start_worker
    run_prompt("build")

    finish("t1")
    wait_for("the queued task note to be saved") { saved_task_notes.size == 1 }
    expect(saved_task_notes.first).not_to include(:turn_start)
    loop_rounds
    expect(turns).to be_empty
  end

  it "watches nothing with session.task_wakes: off" do
    config["session.task_wakes"] = "off"
    scripts["build"] = [task_create("t1")]
    start_worker
    expect(Samagotchi::Engine).to have_received(:new).with(hash_including(task_finish_notes: false))
    run_prompt("build")

    finish("t1")
    loop_rounds
    expect(saved_task_notes).to be_empty
    expect(turns).to be_empty
  end

  it "shares session.max_wakes: past it a finish is a plain note, and the UIs hear it once" do
    config["session.max_wakes"] = 1
    scripts["build"] = [task_create("t1"), task_create("t2"), task_create("t3")]
    start_worker
    run_prompt("build")

    finish("t1")
    expect(pop!(turns, "the wake turn", timeout: 15).dig(1, :origin)).to eq(Samagotchi::TurnOrigin.new(client_id: "task:t1"))
    finish("t2")
    wait_for("t2's note to be saved") { saved_task_notes.size == 2 }
    finish("t3")
    wait_for("t3's note to be saved") { saved_task_notes.size == 3 }
    expect(saved_task_notes.last(2)).to all(satisfy { |m| !m.key?(:turn_start) })
    loop_rounds
    expect(turns).to be_empty
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
    expect(pop!(turns, "the wake turn", timeout: 15).dig(1, :origin)).to eq(Samagotchi::TurnOrigin.new(client_id: "task:t1"))
    wait_for("the failed wake turn's turn note") { Samagotchi::Session.load(session.id, state_dir: state_dir).messages.last[:kind] == "turn_note" }
    expect(Samagotchi::Session.load(session.id, state_dir: state_dir).messages.last[:content])
      .to include("The wake turn for a finished background task (t1) was not answered")
    expect(saved_task_notes.first).not_to include(:turn_start, :turn_id)
    expect(saved_task_notes.first[:content]).not_to include("chi started this turn")

    finish("t2")
    wait_for("t2's plain note to be saved") { saved_task_notes.size == 2 }
    loop_rounds
    expect(turns).to be_empty
  end

  it "writes a plain note while a continue offer waits, and the offer's /continue still resumes" do
    resumable = instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: false, resumable?: true, run_start: 3,
                                                              conversation: nil, tool_activity: [])
    allow_any_instance_of(Samagotchi::TurnFlow).to receive(:interrupted_turn_context).and_return({})
    results << resumable
    scripts["build"] = [task_create("t1")]
    start_worker
    run_prompt("build")
    wait_for("the continue offer") { events.any? { |e| e[:type] == :continue_offered } }

    finish("t1")
    wait_for("the task note to be saved while the offer waits") { saved_task_notes.size == 1 }
    expect(saved_task_notes.first).not_to include(:turn_start)
    loop_rounds
    expect(turns).to be_empty

    send_turn("/continue")
    prompt, kwargs, = pop!(turns, "the /continue turn", timeout: 15)
    expect(prompt).to be_nil
    expect(kwargs).to include(continue: true)
    expect(kwargs[:origin]&.client_id).not_to start_with("task:")
  end

  it "writes a plain note, no wake turn, for a task that finishes as an exit is asked for" do
    scripts["build"] = [task_create("t1")]
    worker = start_worker(poll_interval: 30)
    # Asleep: no idle pass can see the end before the exit request.
    run_prompt_to_sleep(worker, "build")

    finish("t1")
    expect(worker.send(:exit_request, "web:tab")).to be_nil
    expect(join!(@thread, "the worker").value).to eq(:exit_requested)
    expect(saved_task_notes.size).to eq(1)
    expect(saved_task_notes.first).not_to include(:turn_start)
    expect(turns).to be_empty
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
    _, kwargs, last = pop!(turns, "the wake turn", timeout: 15)
    expect(kwargs[:origin]).to eq(Samagotchi::TurnOrigin.new(client_id: "task:t1"))
    expect(last).to include(note_id: "task-t1", turn_start: true)
  end

  it "gives a finished task to a prompt's turn as a plain note when the prompt comes first" do
    scripts["build"] = [task_create("t1")]
    worker = start_worker(poll_interval: 30)
    # Asleep: no idle pass can see the end before the prompt is there.
    run_prompt_to_sleep(worker, "build")

    finish("t1")
    send_turn("next")
    worker.instance_variable_get(:@waker).wake
    prompt, _, last = pop!(turns, "the next prompt's turn", timeout: 15)
    expect(prompt).to eq("next")
    expect(last).to include(note_id: "task-t1")
    expect(last).not_to include(:turn_start)
    loop_rounds
    expect(turns).to be_empty
  end

  it "keeps an idle worker up while a task it watches runs, and lets it go after the task's wake turn" do
    scripts["build"] = [task_create("t1")]
    worker = start_worker(idle_exit_minutes: 0.002)
    run_prompt("build")

    idle_exit = worker.instance_variable_get(:@idle_exit)
    # Past the idle timeout (0.12 s), the task holds the exit.
    wait_for("the idle timeout to pass") { idle_exit.idle_seconds > 0.2 }
    loop_rounds
    expect(@thread).to be_alive
    expect(idle_exit.hold).to eq(:background_tasks)
    finish("t1")
    expect(pop!(turns, "the wake turn", timeout: 15).dig(1, :origin)).to eq(Samagotchi::TurnOrigin.new(client_id: "task:t1"))
    expect(join!(@thread, "the worker").value).to eq(:idle_exit)
  end

  # The pass's look found it running and it ended right after, before the
  # idle exit's check: still watched, so it holds the exit until the next
  # pass wakes for it.
  it "wakes for a task that finishes between the pass's look and the idle exit's check" do
    scripts["build"] = [task_create("t1")]
    worker = start_worker(idle_exit_minutes: 0.002)
    allow_any_instance_of(Samagotchi::TaskWatch).to receive(:take_finished).and_wrap_original do |original, **kwargs|
      taken = original.call(**kwargs)
      idle_exit = worker.instance_variable_get(:@idle_exit)
      # Only the task holds now: the idle timeout has passed.
      if taken.empty? && records["t1"].running? && idle_exit.hold == :background_tasks && idle_exit.idle_seconds > 0.2
        finish("t1")
      end
      taken
    end
    run_prompt("build")

    expect(pop!(turns, "the wake turn", timeout: 15).dig(1, :origin)).to eq(Samagotchi::TurnOrigin.new(client_id: "task:t1"))
    expect(join!(@thread, "the worker").value).to eq(:idle_exit)
  end

  it "lets the idle exit go once the look for finished tasks kept failing (the hold has a bound)" do
    scripts["build"] = [task_create("t1")]
    start_worker(idle_exit_minutes: 0.002)
    run_prompt("build")
    allow(Samagotchi::Log).to receive(:warn).and_call_original
    allow(Samagotchi::Tools::TaskRuntime).to receive(:created_ids_in).and_raise(IOError, "unreadable")
    finish("t1")

    expect(join!(@thread, "the worker").value).to eq(:idle_exit)
    expect(Samagotchi::Log).to have_received(:warn).with(:worker, "task_watch_failed", error: "IOError", msg: "unreadable")
      .at_least(Samagotchi::TaskWatch::MAX_FAILURES).times
    expect(turns).to be_empty
  end

  context "with a note-only task (its turn stopped by the user)" do
    before { scripts["build"] = [task_create("t1"), task_wait("t1", wait_result: "canceled"), stopped_by_user] }

    it "doesn't hold the idle exit" do
      start_worker(idle_exit_minutes: 0.002)
      run_prompt("build")

      expect(join!(@thread, "the worker").value).to eq(:idle_exit)
    end

    it "doesn't hold /exit" do
      worker = start_worker
      run_prompt("build")

      expect(worker.send(:exit_request, "web:tab")).to be_nil
      expect(join!(@thread, "the worker").value).to eq(:exit_requested)
    end
  end

  # Nothing holds the exit for it (queue), but it ended before the worker
  # left: its note goes in as the worker leaves, not lost with the watch.
  it "notes a task that finished unseen as the worker leaves with session.task_wakes: queue" do
    config["session.task_wakes"] = "queue"
    scripts["build"] = [task_create("t1")]
    start_worker(idle_exit_minutes: 0.002)
    # It ends as the exit comes due, after the pass's look (which found it
    # running): the look can't tell when the timeout will pass.
    allow_any_instance_of(Samagotchi::WorkerIdleExit).to receive(:due?).and_wrap_original do |original|
      due = original.call
      finish("t1") if due && records["t1"]&.running?
      due
    end
    run_prompt("build")

    expect(join!(@thread, "the worker").value).to eq(:idle_exit)
    expect(saved_task_notes.size).to eq(1)
    expect(saved_task_notes.first).not_to include(:turn_start)
  end

  # A note-only task (it doesn't hold /exit): the pass before leaving found
  # it running and it ended right after. The session is deleted next, so
  # no note is written into it (or saved).
  it "writes no note as the worker leaves for /exit --delete" do
    scripts["build"] = [task_create("t1"), task_wait("t1", wait_result: "canceled"), stopped_by_user]
    finish_after_look = Queue.new
    finished_after_look = Queue.new
    allow_any_instance_of(Samagotchi::TaskWatch).to receive(:take_finished).and_wrap_original do |original, **kwargs|
      taken = original.call(**kwargs)
      if taken.empty? && records["t1"]&.running? && !finish_after_look.empty?
        finish_after_look.pop
        finish("t1")
        finished_after_look << true
      end
      taken
    end
    worker = start_worker(poll_interval: 30)
    run_prompt_to_sleep(worker, "build")
    finish_after_look << true

    expect(worker.send(:exit_request, "tui:1", delete: true)).to be_nil
    expect(pop!(finished_after_look, "the task to finish after the worker's last look")).to be(true)
    expect(join!(@thread, "the worker").value).to eq(:exit_requested)
    expect(saved_task_notes).to be_empty
  end

  it "doesn't hold the idle exit with session.task_wakes: queue (nothing would wake for the task)" do
    config["session.task_wakes"] = "queue"
    scripts["build"] = [task_create("t1")]
    start_worker(idle_exit_minutes: 0.002)
    run_prompt("build")

    expect(join!(@thread, "the worker").value).to eq(:idle_exit)
  end

  it "holds /exit while a watched task runs, saying how to stop it; not with session.task_wakes: queue" do
    scripts["build"] = [task_create("t1")]
    worker = start_worker
    run_prompt("build")
    records["t1"] = records["t1"].with(started_at: (Time.now - 125).iso8601)
    item = Samagotchi::WorkerIdleExit::HoldItem.new(id: "t1", label: "sleep 20; echo done", detail: "2m")

    hold = worker.send(:exit_request, "web:tab")
    expect(hold.reason).to eq(:background_tasks)
    expect(hold.hint).to eq(Samagotchi::Worker::TASK_STOP_HINT)
    expect(hold.tasks.first[:id]).to eq("t1")
    expect(hold.tasks.first[:command]).to eq("sleep 20; echo done")
    expect(hold.tasks.first[:age_seconds]).to be_between(124, 126)
    expect(hold.holds).to eq([Samagotchi::WorkerIdleExit::StoppableHold.new(kind: :background_tasks,
                                                                            items: [item])])
    config["session.task_wakes"] = "queue"
    expect(worker.send(:exit_request, "web:tab")).to be_nil
  end

  it "stops the watched task on the ask's stop-all and leaves, saying what it stopped" do
    scripts["build"] = [task_create("t1")]
    allow(Samagotchi::Tools::TaskRuntime).to receive(:stop_task) do |id, by:|
      records[id] = records[id].with(status: "stopped", stop_reason: "stopped_by_user", stop_requested_by: by)
    end
    worker = start_worker
    run_prompt("build")

    expect(worker.send(:exit_request, "tui:1", stop: true)).to be_nil
    expect(worker.stopped_holds.tasks).to eq(["sleep 20; echo done"])
    expect(records["t1"].running?).to be(false)
    expect(join!(@thread, "the worker").value).to eq(:exit_requested)
  end
end
