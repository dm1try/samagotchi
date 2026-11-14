# frozen_string_literal: true

require "fileutils"
require "open3"
require "samagotchi/process_group"
require "samagotchi/task_finish_note"
require "samagotchi/tools/execute"
require "samagotchi/tools/leftovers"
require "samagotchi/tools/shell"
require "samagotchi/tools/task_get"
require "samagotchi/tools/task_list"
require "samagotchi/tools/task_runtime"
require "samagotchi/tools/task_wait"
require "support/task_dirs"

# A task_create task (or a handed-over execute) whose shell exits while a
# process it started still holds the task's log: the rule execute applies
# (Tools::Leftovers), one settler per task.
RSpec.describe "a background task's leftover processes" do
  include TaskDirs

  let(:runtime) { Samagotchi::Tools::TaskRuntime }
  let(:leftovers) { Samagotchi::Tools::Leftovers }
  let(:task_hint) { leftovers.task_hint(:stopped) }

  around { |example| with_task_dir { example.run } }

  # Short graces: these examples test what happens once one is over.
  before do
    stub_const("#{runtime}::LEFTOVER_GRACE_SEC", 0.3)
    stub_const("#{runtime}::LEFTOVER_STOP_GRACE_SEC", 0.3)
    stub_const("#{runtime}::REFRESH_STOP_GRACE_SEC", 0.3)
    stub_const("#{runtime}::REFRESH_KILL_WAIT_SEC", 0.3)
    stub_const("Samagotchi::ProcessGroup::KILL_WAIT_SEC", 0.3)
    stub_const("Samagotchi::Tools::TaskWait::POLL_INTERVAL", 0.05)
    @pids = []
  end

  # Every process an example started is killed by the pid it recorded.
  after do
    @pids.each do |pid|
      Process.kill("KILL", pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end

  # The pid a command printed as "pid=N", recorded for the cleanup.
  def child_pid(path)
    pid = nil
    wait_for("the command to print its child's pid", timeout: 10) { pid = File.read(path)[/^pid=(\d+)$/, 1] if File.file?(path) }
    Integer(pid).tap { |found| @pids << found }
  end

  # Gone or a zombie not yet reaped by init.
  def running?(pid)
    Process.kill(0, pid)
    state, = Open3.capture2("ps", "-o", "stat=", "-p", pid.to_s)
    !state.strip.empty? && !state.strip.start_with?("Z")
  rescue Errno::ESRCH
    false
  end

  def gone?(pid) = wait_until(timeout: 5, interval: 0.05) { !running?(pid) }

  def finished(id, timeout: 10)
    record = nil
    wait_for("task #{id} to finish", timeout: timeout, interval: 0.05, seen: -> { record&.status }) do
      record, = runtime.get_record(id)
      !record.running?
    end
    record
  end

  def shell_gone(record)
    wait_for("the task's shell to exit", timeout: 10) { !Samagotchi::ProcessGroup.alive?(record.pid) }
  end

  it "stops a child left holding the log after the grace, keeps the shell's exit code, and every result says so" do
    record, = runtime.create_task("sleep 30.91 & echo pid=$!")
    pid = child_pid(record.output_path)

    # A wait running across the grace gets the settled record, key and hint.
    waited = Samagotchi::Tools::TaskWait.call(record.id, timeout: 10)

    expect(waited).to include("status: completed", "exit_code: 0", task_hint)
    expect(gone?(pid)).to be(true)
    settled = runtime.load_record(record.id)
    expect(settled).to have_attributes(status: "completed", exit_code: 0, stop_reason: nil, leftovers: "stopped")
    expect(Samagotchi::Tools::TaskGet.call(record.id)).to include(task_hint)
    expect(Samagotchi::Tools::TaskList.call).to include(task_hint)
    expect(Samagotchi::TaskFinishNote.text(settled, limit_sec: nil, wake: true, cap: 10_000)).to include(task_hint)
  end

  it "keeps the task running while the grace runs, so no reader finishes it before the key is written" do
    stub_const("#{runtime}::LEFTOVER_GRACE_SEC", 1.0)
    record, = runtime.create_task("sleep 30.97 & echo pid=$!")
    child_pid(record.output_path)
    shell_gone(record)

    seen = []
    current = nil
    wait_for("the task to finish", timeout: 10, interval: 0.02) do
      current, = runtime.get_record(record.id)
      seen << current.leftovers if current.running?
      !current.running?
    end

    # Several reads across the grace, each of a running record.
    expect(seen.size).to be > 1
    expect(seen).to all(be_nil)
    expect(current).to have_attributes(status: "completed", leftovers: "stopped")
  end

  it "leaves a child that holds no log (nohup … >file 2>&1 &) running, with no note" do
    record, = runtime.create_task("nohup sleep 30.92 >/dev/null 2>&1 </dev/null & echo pid=$!")
    pid = child_pid(record.output_path)

    done = finished(record.id)

    expect(done).to have_attributes(status: "completed", exit_code: 0, leftovers: nil)
    expect(runtime.load_record(record.id).to_file).not_to have_key("leftovers")
    expect(running?(pid)).to be(true)
    expect(Samagotchi::Tools::TaskGet.call(record.id)).not_to include("background process")
  end

  it "says a holder that left the group (setsid) was left running, and signals nothing" do
    allow(Samagotchi::ProcessGroup).to receive(:signal).and_call_original
    ready = File.expand_path("ready")
    record, = runtime.create_task("perl -MPOSIX -e 'POSIX::setsid(); open(F, q(>#{ready})); sleep 30.93' & echo pid=$!; " \
                                  "i=0; until [ -e #{ready} ] || [ $i -ge 250 ]; do sleep 0.02; i=$((i+1)); done")
    pid = child_pid(record.output_path)

    done = finished(record.id)

    expect(done).to have_attributes(status: "completed", exit_code: 0, leftovers: "detached")
    expect(running?(pid)).to be(true)
    expect(Samagotchi::ProcessGroup).not_to have_received(:signal)
    expect(Samagotchi::Tools::TaskGet.call(record.id))
      .to include(leftovers.task_hint(:detached))
  end

  it "stops the group on task_stop during the grace, and the record ends stopped" do
    stub_const("#{runtime}::LEFTOVER_GRACE_SEC", 30)
    record, = runtime.create_task("sleep 30.94 & echo pid=$!")
    pid = child_pid(record.output_path)
    shell_gone(record)
    expect(runtime.get_record(record.id).first).to be_running

    stopped, error = runtime.stop_task(record.id, by: "model")

    expect(error).to be_nil
    expect(stopped).to have_attributes(status: "stopped", stop_reason: "stopped_by_model")
    expect(gone?(pid)).to be(true)
    expect(runtime.quiesce!(timeout: 5)).to eq([])
    expect(runtime.load_record(record.id)).to have_attributes(status: "stopped", leftovers: nil)
  end

  it "is settled by the next refresh when the waiter is gone mid-grace (a worker that exited)" do
    stub_const("#{runtime}::LEFTOVER_GRACE_SEC", 30)
    record, = runtime.create_task("sleep 30.95 & echo pid=$!")
    pid = child_pid(record.output_path)
    shell_gone(record)
    waiter = runtime.waiter_for(record.id)
    wait_for("the waiter to start its grace", timeout: 5) { waiter[runtime::SETTLING] }
    waiter.kill
    join!(waiter, "the killed waiter")

    expect(runtime.load_record(record.id)).to be_running
    expect(runtime.get_record(record.id).first).to have_attributes(status: "completed", exit_code: 0, leftovers: "stopped")
    expect(gone?(pid)).to be(true)
  end

  describe "a record no waiter of this process watches (the chi that started it is gone)" do
    # The command spawned as task_create spawns it, its log flock'd or not
    # (an older chi), and a running record for it; no record_exit_status.
    def spawn_task(command, flock: true)
      id = runtime.generate_task_id
      dir = runtime.task_dir_for(id)
      FileUtils.mkdir_p(dir)
      output_path = File.join(dir, "output.log")
      exit_code_path = File.expand_path(File.join(dir, "exit_code"))
      pid = File.open(output_path, "a") do |io|
        io.flock(File::LOCK_SH) if flock
        Samagotchi::ProcessGroup.spawn(*Samagotchi::Tools::Shell.argv(runtime.wrapped_shell_command(command, exit_code_path)),
                                       in: File::NULL, out: io, err: io)
      end
      reaper = Process.detach(pid)
      record = Samagotchi::Tools::TaskRecord.running(id: id, command: command, cwd: Dir.pwd, pid: pid,
                                                     started_at: Time.now.utc.iso8601, output_path: output_path,
                                                     exit_code_path: exit_code_path)
      runtime.write_record(record)
      join!(reaper, "the task's shell")
      record
    end

    it "stops a child still holding the log and records it" do
      record = spawn_task("sleep 30.96 & echo pid=$!")
      pid = child_pid(record.output_path)

      expect(runtime.get_record(record.id).first).to have_attributes(status: "completed", exit_code: 0, leftovers: "stopped")
      expect(gone?(pid)).to be(true)
    end

    # Two held? probes at once read each other's lock as a holder: a group
    # gone by the stop with nothing holding the log records nothing.
    it "records no leftovers when the group is empty at the stop and nothing holds the log" do
      record = spawn_task("true")
      allow(leftovers).to receive(:held?).and_return(true, true, false)
      allow(Samagotchi::ProcessGroup).to receive(:group_alive?).and_return(true, false)
      allow(Samagotchi::ProcessGroup).to receive(:signal).and_call_original

      expect(runtime.get_record(record.id).first).to have_attributes(status: "completed", exit_code: 0, leftovers: nil)
      expect(Samagotchi::ProcessGroup).not_to have_received(:signal)
    end

    it "signals nothing when the group is already empty at the first look, and says detached while the log is held" do
      record = spawn_task("true")
      allow(leftovers).to receive(:held?).and_return(true)
      allow(Samagotchi::ProcessGroup).to receive(:group_alive?).and_return(false)
      allow(Samagotchi::ProcessGroup).to receive(:signal).and_call_original

      expect(runtime.get_record(record.id).first).to have_attributes(status: "completed", leftovers: "detached")
      expect(Samagotchi::ProcessGroup).not_to have_received(:signal)
    end

    it "settles a record from an older chi (its log never flock'd) as before, leaving the child alone" do
      record = spawn_task("sleep 30.98 & echo pid=$!", flock: false)
      pid = child_pid(record.output_path)

      expect(runtime.get_record(record.id).first).to have_attributes(status: "completed", exit_code: 0, leftovers: nil)
      expect(running?(pid)).to be(true)
    end
  end

  it "stops what a handed-over execute's shell leaves behind when it ends" do
    allow(Samagotchi::Tools::Execute).to receive(:timeout_seconds).and_return(0.5)
    go = File.expand_path("go")
    pid_file = File.expand_path("pid")
    result = Samagotchi::Tools::Execute.call("until [ -e #{go} ]; do sleep 0.02; done; sleep 30.99 & echo pid=$! > #{pid_file}")
    id = result[/^task_id: (\S+)$/, 1]
    expect(id).not_to be_nil

    FileUtils.touch(go)
    pid = child_pid(pid_file)

    expect(finished(id)).to have_attributes(status: "completed", exit_code: 0, leftovers: "stopped")
    expect(gone?(pid)).to be(true)
  end

  describe "the hints" do
    it "tells the model what to do instead, never to use task_create, on the task side" do
      expect(task_hint).to eq("(a background process kept the task's log open and was stopped; to keep one running, " \
                              "run it in the foreground or end the command with `wait`)")
    end

    it "tells the model a holder left running is still running and how to end it, on the task side" do
      expect(leftovers.task_hint(:detached))
        .to eq("(a background process kept the task's log open and was left running; it left the task's process group, " \
               "so task_stop can't reach it: kill it if it shouldn't run; next time, run it in the foreground or end " \
               "the command with `wait`)")
    end

    it "tells execute's model to run a long job with task_create in the foreground" do
      expect(Samagotchi::Tools::Execute::BACKGROUND_HINT)
        .to eq("(a background process kept the output open and was stopped; to keep a server or long job running, " \
               "start it with task_create in the foreground (no `&`))")
    end
  end
end
