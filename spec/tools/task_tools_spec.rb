# frozen_string_literal: true

require "fileutils"
require "samagotchi/kernel_loop"
require "samagotchi/process_group"
require "samagotchi/reminder_store"
require "samagotchi/tools/builtins"
require "samagotchi/tools/execute"
require "samagotchi/tools/task_create"
require "samagotchi/tools/task_get"
require "samagotchi/tools/task_list"
require "samagotchi/tools/task_runtime"
require "samagotchi/tools/task_stop"
require "samagotchi/tools/task_wait"
require "tmpdir"

RSpec.describe "task tools" do
  around do |example|
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        example.run
      ensure
        # A task still running writes its exit_code into dir as it ends:
        # stop it before mktmpdir removes dir (ENOTEMPTY otherwise).
        Samagotchi::Tools::TaskRuntime.list_records.each do |record|
          Samagotchi::Tools::TaskRuntime.stop_task(record.id, by: "model")
        end
      end
    end
  end

  describe Samagotchi::Tools::TaskCreate do
    it "creates a running task and returns metadata with output path" do
      result = described_class.call("ruby -e 'puts \"hello\"'")

      expect(result).to include("task_id:")
      expect(result).to include("status: running")
      expect(result).to include("output_path: tmp/tasks/")
    end

    it "returns an error for an empty command" do
      result = described_class.call("  ")

      expect(result).to include("Error: command is required")
    end

    it "passes validated environment overrides to the task process" do
      create_result = described_class.call(
        "ruby -e 'puts ENV.fetch(\"SAMAGOTCHI_TASK_TEST\")'",
        env: { "SAMAGOTCHI_TASK_TEST" => "present" }
      )
      task_id = extract_field(create_result, "task_id")

      result = wait_for_task(task_id)
      output_path = extract_field(result, "output_path")

      expect(File.read(output_path)).to include("present")
    end

    it "accepts JSON environment overrides from model tool calls" do
      create_result = described_class.call(
        "ruby -e 'puts ENV.fetch(\"SAMAGOTCHI_TASK_JSON_TEST\")'",
        env: '{"SAMAGOTCHI_TASK_JSON_TEST":"present"}'
      )
      task_id = extract_field(create_result, "task_id")

      result = wait_for_task(task_id)
      output_path = extract_field(result, "output_path")

      expect(File.read(output_path)).to include("present")
    end

    it "treats an omitted model environment as no override" do
      create_result = described_class.call("ruby -e 'puts \"no override\"'", env: "")
      task_id = extract_field(create_result, "task_id")

      result = wait_for_task(task_id)
      output_path = extract_field(result, "output_path")

      expect(File.read(output_path)).to include("no override")
    end

    it "does not allow overrides of sanitized Bundler environment keys" do
      result = described_class.call("echo blocked", env: { "RUBYOPT" => "-rbundler/setup" })

      expect(result).to eq("Error: env key is reserved: RUBYOPT")
    end

    it "doesn't start a task once the turn is stopped" do
      kctx = Struct.new(:peers).new(Struct.new(:cancelled?).new(true))

      result = Samagotchi::Tools::Builtins::HANDLERS.fetch("task_create").call({ content: "true" }, kctx)

      expect(result).to eq("Error: not run, the user stopped the turn")
      expect(Samagotchi::Tools::TaskList.call).to eq("No tasks found.")
    end

    # A chi run by the task answers as a parent agent (ParentApprovals).
    it "exports SAMAGOTCHI_PARENT_SESSION from the builtin handler, which the model's env can't set" do
      kctx = Struct.new(:peers).new(Struct.new(:cancelled?, :session_id).new(false, "sess-1"))
      created = Samagotchi::Tools::Builtins::HANDLERS.fetch("task_create")
                                                     .call({ content: "printenv SAMAGOTCHI_PARENT_SESSION" }, kctx)
      result = wait_for_task(extract_field(created, "task_id"))
      expect(File.read(extract_field(result, "output_path"))).to eq("sess-1\n")

      expect(described_class.call("true", env: { "SAMAGOTCHI_PARENT_SESSION" => "" }))
        .to eq("Error: env key is reserved: SAMAGOTCHI_PARENT_SESSION")
    end

    it "exports SAMAGOTCHI_SESSION_MODEL from the builtin handler, which the model's env can't set" do
      peers = Samagotchi::Tools::Peers.new(session_id: "sess-1", model_ref: "main:ornith", cancelled: false)
      created = Samagotchi::Tools::Builtins::HANDLERS.fetch("task_create")
                                                     .call({ content: "printenv SAMAGOTCHI_SESSION_MODEL" },
                                                           Struct.new(:peers).new(peers))
      result = wait_for_task(extract_field(created, "task_id"))
      expect(File.read(extract_field(result, "output_path"))).to eq("main:ornith\n")

      expect(described_class.call("true", env: { "SAMAGOTCHI_SESSION_MODEL" => "x" }))
        .to eq("Error: env key is reserved: SAMAGOTCHI_SESSION_MODEL")
      expect(described_class.call("true", env: { "SAMAGOTCHI_SESSION_THINKING" => "low" }))
        .to eq("Error: env key is reserved: SAMAGOTCHI_SESSION_THINKING")
    end

    # A worker started by `chi --model X` has SAMAGOTCHI_DEFAULT_MODEL=X for
    # its own run (SessionManager.spawn_options); a chi its commands run
    # must not take X for the default.
    describe "a --model the worker was spawned with" do
      let(:kctx) { Struct.new(:peers).new(Samagotchi::Tools::Peers.new(session_id: "sess-1", model_ref: "main:x", cancelled: false)) }
      let(:execute) { ->(cmd) { Samagotchi::Tools::Builtins::HANDLERS.fetch("execute").call({ content: cmd }, kctx) } }

      it "is not passed on to execute or task_create commands" do
        with_env("SAMAGOTCHI_DEFAULT_MODEL" => "x", "SAMAGOTCHI_DEFAULT_MODEL_FROM_CLI" => "1") do
          output = execute.call('echo "[${SAMAGOTCHI_DEFAULT_MODEL-unset}|${SAMAGOTCHI_DEFAULT_MODEL_FROM_CLI-unset}]"')
          expect(output).to include("[unset|unset]")

          created = Samagotchi::Tools::Builtins::HANDLERS.fetch("task_create")
                                                         .call({ content: 'echo "${SAMAGOTCHI_DEFAULT_MODEL-unset}"' }, kctx)
          result = wait_for_task(extract_field(created, "task_id"))
          expect(File.read(extract_field(result, "output_path"))).to eq("unset\n")

          created = Samagotchi::Tools::Builtins::HANDLERS.fetch("task_create")
                                                         .call({ content: 'echo "$SAMAGOTCHI_DEFAULT_MODEL"',
                                                                 env: { "SAMAGOTCHI_DEFAULT_MODEL" => "asked" } }, kctx)
          result = wait_for_task(extract_field(created, "task_id"))
          expect(File.read(extract_field(result, "output_path"))).to eq("asked\n")
        end
      end

      it "leaves a SAMAGOTCHI_DEFAULT_MODEL the user exported alone" do
        with_env("SAMAGOTCHI_DEFAULT_MODEL" => "mine", "SAMAGOTCHI_DEFAULT_MODEL_FROM_CLI" => nil) do
          expect(execute.call('echo "[$SAMAGOTCHI_DEFAULT_MODEL]"')).to include("[mine]")
        end
      end
    end

    it "spawns a non-login shell (Shell, as execute) so profile files can't clobber inherited PATH" do
      expect(Process).to receive(:spawn) do |*args, **_kwargs|
        expect(args[1..-2]).to eq([*Samagotchi::Tools::Shell.program, "-c"])
        fork { exit! }
      end

      described_class.call("true")
    end
  end

  describe Samagotchi::Tools::TaskWait, "the log a cut names" do
    # ToolRunner's cut of a long result names the log (ToolOutputCut's
    # :head_tail_ref).
    it "gives a result with an output tail as a RefText of the task's log" do
      create_result = Samagotchi::Tools::TaskCreate.call("ruby -e 'puts \"ready\"; STDOUT.flush; sleep 20'")
      task_id = extract_field(create_result, "task_id")

      result = described_class.call(task_id, timeout: 10, done_pattern: "ready")

      expect(result).to include("wait_result: pattern_matched")
      expect(result.ref_path).to eq(extract_field(result, "output_path"))
    end
  end

  describe Samagotchi::Tools::TaskGet do
    it "returns full metadata for an existing task" do
      create_result = Samagotchi::Tools::TaskCreate.call("ruby -e 'puts \"get\"'")
      task_id = extract_field(create_result, "task_id")

      result = wait_for_task(task_id)

      expect(result).to include("task_id: #{task_id}")
      expect(result).to include("status:")
      expect(result).to include("command: ruby -e 'puts \"get\"'")
      expect(result).to include("output_path: tmp/tasks/")
    end

    it "returns an error for an unknown id" do
      result = described_class.call("does-not-exist")

      expect(result).to include("Error: task not found")
    end

    it "never reads outside tmp/tasks for an id that isn't a task id's shape" do
      FileUtils.mkdir_p("tmp/x")
      File.write("tmp/x/task.json", JSON.generate("id" => "../x", "status" => "completed"))
      FileUtils.mkdir_p("tmp/tasks")

      expect(described_class.call("../x")).to eq("Error: task not found: ../x")
      expect(Samagotchi::Tools::TaskStop.call("../x")).to eq("Error: task not found: ../x")
      expect(Samagotchi::Tools::TaskWait.call("../x")).to eq("Error: task not found: ../x")
    end

    it "notes a user stop, and not a model stop" do
      user_task, = Samagotchi::Tools::TaskRuntime.create_task("sleep 30")
      model_task, = Samagotchi::Tools::TaskRuntime.create_task("sleep 30")
      Samagotchi::Tools::TaskRuntime.stop_task(user_task.id, by: "user")
      Samagotchi::Tools::TaskRuntime.stop_task(model_task.id, by: "model")

      expect(described_class.call(user_task.id)).to end_with("note: the user stopped this task; don't restart it unless they ask.")
      expect(described_class.call(model_task.id)).not_to include("note:")
    end
  end

  describe Samagotchi::Tools::TaskList do
    it "lists existing tasks with compact entries" do
      Samagotchi::Tools::TaskCreate.call("ruby -e 'puts \"one\"'")
      Samagotchi::Tools::TaskCreate.call("ruby -e 'puts \"two\"'")

      result = described_class.call

      expect(result).to include("task_id:")
      expect(result).to include("status:")
      expect(result).to include("output_path: tmp/tasks/")
    end

    it "returns a friendly message when there are no tasks" do
      expect(described_class.call).to eq("No tasks found.")
    end
  end

  describe Samagotchi::Tools::TaskStop do
    it "stops a long-running task and marks stop_reason" do
      create_result = Samagotchi::Tools::TaskCreate.call("ruby -e 'puts \"start\"; STDOUT.flush; sleep 20'")
      task_id = extract_field(create_result, "task_id")

      result = described_class.call(task_id)

      expect(result).to include("task_id: #{task_id}")
      expect(result).to include("status: stopped")
      expect(result).to include("stop_reason: stopped_by_model")

      get_result = Samagotchi::Tools::TaskGet.call(task_id)
      expect(get_result).to include("status: stopped")
    end

    it "returns an error for an unknown task id" do
      result = described_class.call("does-not-exist")

      expect(result).to include("Error: task not found")
    end

    it "says a session id is not a task id, and where task ids come from" do
      result = described_class.call("0f8c2a4e-5b1d-4c3e-9a7f-1234567890ab")

      expect(result).to eq("Error: task not found: 0f8c2a4e-5b1d-4c3e-9a7f-1234567890ab " \
                            "(that is a session id; task ids come from task_create, and task_list lists them)")
      expect(Samagotchi::Tools::TaskGet.call("0f8c2a4e-5b1d-4c3e-9a7f-1234567890ab")).to include("that is a session id")
    end
  end

  describe Samagotchi::Tools::TaskRuntime do
    it "ends a user stop as stopped, recording who stopped it" do
      record, = described_class.create_task("sleep 30")

      stopped, error = described_class.stop_task(record.id, by: "user")

      expect(error).to be_nil
      expect(stopped).to have_attributes(status: "stopped", stop_reason: "stopped_by_user", stop_requested_by: "user")
      expect(described_class.get_record(record.id).first).to have_attributes(status: "stopped", stop_reason: "stopped_by_user")
    end

    it "ends a stop as stopped when the command traps TERM and exits non-zero" do
      record, = described_class.create_task("trap 'exit 7' TERM; while true; do sleep 0.1; done")

      stopped, = described_class.stop_task(record.id, by: "model")

      expect(stopped).to have_attributes(status: "stopped", stop_reason: "stopped_by_model")
    end

    def running?(pattern)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
      while (alive = system("pgrep", "-f", pattern, out: File::NULL)) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.05
      end
      alive
    end

    it "stops the task's whole group, a grandchild the shell waits on too" do
      record, = described_class.create_task("sleep 31.75 & wait")
      expect(wait_until { system("pgrep", "-f", "sleep 31.75", out: File::NULL) }).to be(true)

      stopped, = described_class.stop_task(record.id, by: "model")

      expect(stopped).to have_attributes(status: "stopped")
      expect(running?("sleep 31.75")).to be(false)
    end

    it "KILLs a task that ignores TERM once the grace is over" do
      stub_const("#{described_class}::STOP_GRACE_SEC", 0.3)
      record, = described_class.create_task("trap '' TERM; sleep 31.76")
      expect(wait_until { system("pgrep", "-f", "sleep 31.76", out: File::NULL) }).to be(true)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      stopped, = described_class.stop_task(record.id, by: "model")

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be_between(0.3, 2)
      expect(stopped).to have_attributes(status: "stopped", stop_reason: "stopped_by_model")
      expect(running?("sleep 31.76")).to be(false)
    end

    it "never shows failed to a reader polling during the stop" do
      record, = described_class.create_task("sleep 30")
      seen = []
      done = false
      reader = Thread.new do
        until done
          seen << described_class.get_record(record.id).first&.status
          sleep 0.005
        end
      end

      described_class.stop_task(record.id, by: "user")
      done = true
      reader.join

      expect(seen).not_to include("failed")
      expect(described_class.get_record(record.id).first).to have_attributes(status: "stopped", stop_reason: "stopped_by_user")
    end

    describe "a record whose pid isn't a process group chi started" do
      # Every Process.kill is recorded; one aimed at pid 0 or 1 (chi's own
      # group, every process of the user) never reaches the kernel.
      let(:kills) { [] }

      before do
        stub_const("#{described_class}::STOP_GRACE_SEC", 0.2)
        allow(Process).to receive(:kill).and_wrap_original do |original, sig, pid|
          kills << [sig, pid]
          [0, 1, -1].include?(pid) ? 1 : original.call(sig, pid)
        end
      end

      def running_record(pid)
        data = { "id" => described_class.generate_task_id, "command" => "sleep 30", "status" => "running",
                 "created_at" => "2026-10-06T00:00:00Z", "exit_code_path" => File.join(Dir.pwd, "no-exit-code") }
        data["pid"] = pid unless pid == :missing
        record = Samagotchi::Tools::TaskRecord.from_file(data)
        described_class.write_record(record)
        record
      end

      def signals = kills.reject { |sig, _| sig.zero? }

      [:missing, 0, 1, "abc"].each do |pid|
        it "signals nothing for a pid #{pid.inspect}, and ends the task as failed, saying why" do
          record = running_record(pid)

          stopped, error = described_class.stop_task(record.id, by: "model")

          expect(error).to be_nil
          expect(stopped).to have_attributes(status: "failed", stop_reason: described_class::NOT_CHIS_PROCESS)
          expect(kills.map(&:last)).not_to include(0, 1, -1)
          expect(signals).to be_empty
        end
      end

      it "signals nothing for a live pid that doesn't lead its own group (reused by another process)" do
        other = Process.spawn("sleep", "31.78") # this spec's own child, in rspec's group
        record = running_record(other)

        expect(described_class.get_record(record.id).first).to have_attributes(status: "failed",
                                                                               stop_reason: described_class::NOT_CHIS_PROCESS)
        stopped, = described_class.stop_task(record.id, by: "model")

        expect(stopped).to have_attributes(status: "failed")
        expect(signals).to be_empty
        expect(Process.wait2(other, Process::WNOHANG)).to be_nil
      ensure
        if other
          Process.kill("KILL", other)
          Process.wait(other)
        end
      end
    end

    it "keeps a running task running when its start time can't be read" do
      record, = described_class.create_task("sleep 30")
      allow(Samagotchi::ProcessGroup).to receive(:start_time).and_return(nil)

      3.times { expect(described_class.get_record(record.id).first).to have_attributes(status: "running") }
      expect(described_class.list_records.first).to have_attributes(status: "running")

      stopped, error = described_class.stop_task(record.id, by: "model")
      expect(error).to be_nil
      expect(stopped).to have_attributes(status: "stopped", stop_reason: "stopped_by_model")
    end

    it "records the task's start time, and signals nothing for a group leader whose pid was reused since" do
      record, = described_class.create_task("sleep 30")
      expect(record.pid_started).to eq(Samagotchi::ProcessGroup.start_time(record.pid))

      other = Samagotchi::ProcessGroup.spawn({}, "sleep", "31.79", in: File::NULL, out: File::NULL, err: File::NULL)
      reused = described_class.load_record(record.id).with(pid: other)
      described_class.write_record(reused)
      # ps reads start times to the second: the reused pid's process starts later.
      allow(Samagotchi::ProcessGroup).to receive(:start_time).and_wrap_original do |original, pid|
        pid == other ? "a later start" : original.call(pid)
      end
      allow(Process).to receive(:kill).and_call_original

      stopped, error = described_class.stop_task(record.id, by: "model")

      expect(error).to be_nil
      expect(stopped).to have_attributes(status: "failed", stop_reason: described_class::NOT_CHIS_PROCESS)
      expect(Process).not_to have_received(:kill).with(satisfy { |sig| sig.to_s != "0" }, anything)
      expect(Process.wait2(other, Process::WNOHANG)).to be_nil
    ensure
      if other
        Process.kill("KILL", other)
        Process.wait(other)
      end
      Process.kill("KILL", -record.pid) if record && Samagotchi::ProcessGroup.leader?(record.pid)
    end

    it "lists and reads a task whose pid a later group leader reused as exited, before any task_stop" do
      record, = described_class.create_task("sleep 30")
      other = Samagotchi::ProcessGroup.spawn({}, "sleep", "31.81", in: File::NULL, out: File::NULL, err: File::NULL)
      described_class.write_record(described_class.load_record(record.id).with(pid: other))
      allow(Samagotchi::ProcessGroup).to receive(:start_time).and_wrap_original do |original, pid|
        pid == other ? "a later start" : original.call(pid)
      end

      expect(described_class.list_records.find { |r| r.id == record.id }).to have_attributes(status: "failed")
      expect(described_class.get_record(record.id).first)
        .to have_attributes(status: "failed", stop_reason: described_class::NOT_CHIS_PROCESS)
      expect(Process.wait2(other, Process::WNOHANG)).to be_nil
    ensure
      if other
        Process.kill("KILL", other)
        Process.wait(other)
      end
      Process.kill("KILL", -record.pid) if record && Samagotchi::ProcessGroup.leader?(record.pid)
    end

    it "keeps a stop that already finished on disk when a stale copy is refreshed" do
      record, = described_class.create_task("sleep 30")
      stale = described_class.load_record(record.id)
      described_class.stop_task(record.id, by: "user")

      expect(described_class.refresh_record(stale)).to have_attributes(status: "stopped", stop_reason: "stopped_by_user")
      expect(described_class.load_record(record.id)).to have_attributes(status: "stopped")
    end
  end

  describe Samagotchi::Tools::TaskWait do
    # It looks at the task every POLL_INTERVAL (0.5 s): every 0.05 s here,
    # so a wait ends soon after the task's change, as it would at 0.5 s.
    before { stub_const("Samagotchi::Tools::TaskWait::POLL_INTERVAL", 0.05) }

    it "follows a timeout's output tail with a short stderr tail when the record has a stderr log" do
      dir = File.expand_path("logs")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "out.log"), "o1\no2\n")
      File.write(File.join(dir, "err.log"), (1..20).map { |n| "e#{n}\n" }.join)
      record, = Samagotchi::Tools::TaskRuntime.create_task("sleep 31.83")
      Samagotchi::Tools::TaskRuntime.write_record(record.with(output_path: File.join(dir, "out.log"),
                                                              stderr_path: File.join(dir, "err.log")))

      result = described_class.call(record.id, timeout: 0, tail_lines: 50)

      expect(result).to end_with("output_tail:\no1\no2\nstderr_tail:\n#{(11..20).map { |n| "e#{n}" }.join("\n")}")
      expect(result).to include("stderr_path: #{File.join(dir, "err.log")}")
      expect(result).to have_attributes(ref_path: File.join(dir, "out.log"), stderr_path: File.join(dir, "err.log"))
      dispatched = Samagotchi::KernelLoop.new(client: nil, reminder_store: Samagotchi::ReminderStore.new)
                                         .dispatch_tool_call(name: "task_wait", content: record.id, timeout: "0")
      expect(dispatched).to include(ref_path: File.join(dir, "out.log"), ref_stderr_path: File.join(dir, "err.log"))
      File.write(File.join(dir, "err.log"), "")
      expect(described_class.call(record.id, timeout: 0)).to end_with("output_tail:\no1\no2")
    end

    it "uses a multi-minute default timeout" do
      expect(described_class::TIMEOUT_DEFAULT).to eq(600)
    end

    it "uses defaults when optional model parameters are omitted" do
      expect(described_class.call("does-not-exist", timeout: "", tail_lines: "")).to include("Error: task not found")
    end

    it "waits for a task to complete and returns status with output path" do
      create_result = Samagotchi::Tools::TaskCreate.call("ruby -e 'puts \"hello\"'")
      task_id = extract_field(create_result, "task_id")
      result = described_class.call(task_id)
      expect(result).to include("task_id: #{task_id}")
      expect(result).to include("status: completed")
      expect(result).to include("exit_code: 0")
      expect(result).to include("output_path:")
      expect(result).to end_with("output_tail:\nhello")
      expect(result.ref_path).to eq(extract_field(result, "output_path"))
    end

    it "gives a finished task's last log lines, tail_lines of them" do
      create_result = Samagotchi::Tools::TaskCreate.call("for i in $(seq 0 14); do echo l$i; done; exit 3")
      task_id = extract_field(create_result, "task_id")

      result = described_class.call(task_id, timeout: 10)

      expect(result).to include("status: failed", "exit_code: 3")
      expect(result).to end_with("output_tail:\n#{(5..14).map { |i| "l#{i}" }.join("\n")}")
      expect(described_class.call(task_id, tail_lines: 2)).to end_with("output_tail:\nl13\nl14")
    end

    it "returns a bounded output tail when task is still in progress" do
      create_result = Samagotchi::Tools::TaskCreate.call("ruby -e '$stdout.sync = true; puts " + '"first"; puts "second"; sleep 10' + "'")
      task_id = extract_field(create_result, "task_id")
      # Both lines out first: under load the child may take over the 1 s wait to print.
      output_path = extract_field(create_result, "output_path")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      sleep 0.05 until File.read(output_path).include?("second") || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      result = described_class.call(task_id, timeout: 1, tail_lines: 1)
      expect(result).to include("task_id: #{task_id}")
      expect(result).to include("status: running")
      expect(result).to include("wait_result: timeout")
      expect(result).to include("output_tail:\nsecond")
      expect(result).not_to include("first")
    end

    it "uses the default timeout when an omitted model timeout is empty" do
      create_result = Samagotchi::Tools::TaskCreate.call("ruby -e '$stdout.sync = true; puts \"ready\"; sleep 1'")
      task_id = extract_field(create_result, "task_id")

      result = described_class.call(task_id, timeout: "", tail_lines: 1, done_pattern: "ready")

      expect(result).to include("wait_result: pattern_matched")
      expect(result).to include("output_tail:\nready")
    end

    it "returns when the output matches a completion pattern" do
      create_result = Samagotchi::Tools::TaskCreate.call(
        "ruby -e '$stdout.sync = true; puts " + '"phase one"; puts "Done!"; sleep 10' + "'"
      )
      task_id = extract_field(create_result, "task_id")

      # The match returns at once; the timeout only leaves a loaded machine time to start ruby.
      result = described_class.call(task_id, timeout: 10, done_pattern: "Done!")

      expect(result).to include("status: running")
      expect(result).to include("wait_result: pattern_matched")
      expect(result).to include("output_tail:\nphase one\nDone!")
    end

    it "returns an error for an invalid completion pattern" do
      expect(described_class.call("task", done_pattern: "[")).to start_with("Error: invalid done_pattern:")
    end

    it "rejects an invalid output-tail size" do
      expect(described_class.call("task", tail_lines: 0)).to eq("Error: tail_lines must be a positive integer")
    end

    it "returns stopped status when task is stopped via task_stop" do
      create_result = Samagotchi::Tools::TaskCreate.call("sleep 30")
      task_id = extract_field(create_result, "task_id")
      Samagotchi::Tools::TaskStop.call(task_id)
      result = described_class.call(task_id)
      expect(result).to include("task_id: #{task_id}")
      expect(result).to include("status: stopped")
      expect(result).to include("stop_reason: stopped_by_model")
      expect(result).to include("output_tail:")
      expect(result).not_to include(Samagotchi::Tools::TaskRuntime::USER_STOP_NOTE)
    end

    it "returns with a note and the output tail when the user stops the task" do
      create_result = Samagotchi::Tools::TaskCreate.call("echo one; echo two; echo three; sleep 30")
      task_id = extract_field(create_result, "task_id")
      output_path = extract_field(create_result, "output_path")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      sleep 0.05 until File.read(output_path).include?("three") || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      stopper = Thread.new do
        sleep 0.3
        Samagotchi::Tools::TaskRuntime.stop_task(task_id, by: "user")
      end

      result = described_class.call(task_id, tail_lines: 2)
      stopper.join

      expect(result).to include("status: stopped").and include("stop_reason: stopped_by_user")
      expect(result).to include("note: the user stopped this task; don't restart it unless they ask.")
      expect(result).to end_with("output_tail:\ntwo\nthree")
    end

    it "returns on Stop and leaves a running task running" do
      create_result = Samagotchi::Tools::TaskCreate.call("echo before; sleep 30")
      task_id = extract_field(create_result, "task_id")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cancelled = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > 0.2 }

      result = described_class.call(task_id, cancelled: cancelled)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5 # not the task's 30 s
      expect(result).to include("status: running")
      expect(result).to include("wait_result: canceled")
      expect(result).to include("STILL RUNNING")
      expect(result).to include("task_wait #{task_id}").and include("task_stop #{task_id}")
      expect(result).to match(/^waited: \d+s$/)
      expect(result).to include("output_tail:\nbefore")
      expect(Samagotchi::Tools::TaskRuntime.get_record(task_id).first.status).to eq("running")
    ensure
      Samagotchi::Tools::TaskStop.call(task_id) if task_id
    end

    it "sees Stop through the kernel's peers in the built-in handler" do
      create_result = Samagotchi::Tools::TaskCreate.call("sleep 30")
      task_id = extract_field(create_result, "task_id")
      peers = Struct.new(:cancelled?).new(true)
      kctx = Struct.new(:peers).new(peers)

      result = Samagotchi::Tools::Builtins::HANDLERS.fetch("task_wait").call({ content: task_id }, kctx)

      expect(result).to include("wait_result: canceled")
    ensure
      Samagotchi::Tools::TaskStop.call(task_id) if task_id
    end

    it "gives the finished result when the task ended before the Stop was seen" do
      create_result = Samagotchi::Tools::TaskCreate.call("true")
      task_id = extract_field(create_result, "task_id")
      sleep 0.1 until Samagotchi::Tools::TaskRuntime.get_record(task_id).first.status != "running"

      result = described_class.call(task_id, cancelled: -> { true })

      expect(result).to include("status: completed")
      expect(result).not_to include("wait_result")
    end

    it "returns an error for an unknown task id" do
      result = described_class.call("does-not-exist")
      expect(result).to include("Error: task not found")
    end

    it "returns an error for an empty task_id" do
      result = described_class.call("  ")
      expect(result).to include("Error: task_id is required")
    end
  end

  describe "TaskRuntime.running_created_in" do
    def tool_response(*outputs, string_keys: false)
      message = { role: "tool_response", content: outputs.join("\n\n---\n\n") }
      string_keys ? message.transform_keys(&:to_s) : message
    end

    it "finds the running tasks this conversation's task_create calls started" do
      live = extract_field(Samagotchi::Tools::TaskCreate.call("sleep 30"), "task_id")
      done = extract_field(Samagotchi::Tools::TaskCreate.call("true"), "task_id")
      other = extract_field(Samagotchi::Tools::TaskCreate.call("sleep 30"), "task_id")
      sleep 0.1 until Samagotchi::Tools::TaskRuntime.get_record(done).first.status != "running"
      messages = [
        { role: "user", content: "task_id: #{other}" },
        tool_response("[execute]\nexit: 0", "[task_create]\ntask_id: #{live}\nstatus: running",
                      "[task_create]\ntask_id: #{done}\nstatus: running"),
        tool_response("[task_list]\ntask_id: #{other}", "[task_wait]\ntask_id: #{other}", string_keys: true),
        tool_response("[task_create]\ntask_id: #{live}\nstatus: running", string_keys: true)
      ]

      expect(Samagotchi::Tools::TaskRuntime.running_created_in(messages)).to eq([{ id: live, command: "sleep 30" }])
      expect(Samagotchi::Tools::TaskRuntime.created_ids_in(messages)).to eq([live, done])
    ensure
      [live, other].compact.each { |id| Samagotchi::Tools::TaskStop.call(id) }
    end
  end

  describe "TaskRuntime.created_ids_in and created_id: tasks other tools started" do
    let(:runtime) { Samagotchi::Tools::TaskRuntime }
    let(:id) { "20261010120000-1a2b3c4d" }
    let(:handed_over) do
      "#{Samagotchi::Tools::Execute.handed_over_line(120)}\ntask_id: #{id}\n" \
        "Wait for it with task_wait (it may take minutes); task_stop stops it."
    end

    it "counts an execute's hand-over, anchored on its first line, and a gate-corrected task_create" do
      messages = [
        { role: "tool_response", content: ["[execute]\n#{handed_over}",
                                           "ran as: task_create command=npm test\n[task_create]\ntask_id: t-ran-as",
                                           "ran as: execute command=sleep 200\n[execute]\n#{handed_over.sub(id, "e-ran-as")}"]
                                            .join("\n\n---\n\n") }
      ]

      expect(runtime.created_ids_in(messages)).to eq([id, "t-ran-as", "e-ran-as"])
    end

    it "never counts a task_id line the command printed" do
      faked = ["[execute]\ntask_id: #{id}\nexit: 0",
               "[execute]\nstdout:\n#{handed_over}\nexit: 0",
               "[task_wait]\n#{handed_over}"]
      messages = [{ role: "tool_response", content: faked.join("\n\n---\n\n") }]

      expect(runtime.created_ids_in(messages)).to eq([])
      expect(runtime.created_id("execute", "task_id: #{id}")).to be_nil
      expect(runtime.created_id("execute", "stdout:\n#{handed_over}")).to be_nil
    end

    it "has a JS twin in the web's task_stop.js that spells the same first line" do
      js = File.read(File.expand_path("../../lib/samagotchi/web/public/task_stop.js", __dir__))
      twin = js[%r{^const HANDED_OVER = /(.+)/;$}, 1]

      expect(twin).to include("#{Samagotchi::Tools::Execute::HANDED_OVER} \\d+s limit:")
      expect(Samagotchi::Tools::Execute.handed_over_line(120.0)).to start_with("Still running at the 120s limit:")
      # JS's leading ^ (no m flag) is Ruby's \A.
      ruby_twin = Regexp.new("\\A#{twin.delete_prefix("^")}")
      expect(ruby_twin.match("ran as: execute command=x\n[execute]\n#{handed_over}")&.[](1)).to eq(id)
      expect(ruby_twin.match("[execute]\nstdout:\n#{handed_over}")).to be_nil
    end

    it "reads a UI row's output with or without the lead, per tool" do
      expect(runtime.created_id("execute", handed_over)).to eq(id)
      expect(runtime.created_id("execute", "[execute]\n#{handed_over}")).to eq(id)
      expect(runtime.handed_over_id("ran as: execute command=x\n[execute]\n#{handed_over}")).to eq(id)
      expect(runtime.created_id("task_create", "task_id: t1\nstatus: running")).to eq("t1")
      expect(runtime.created_id("task_create", "ran as: task_create command=x\n[task_create]\ntask_id: t2")).to eq("t2")
      expect(runtime.created_id("task_wait", "task_id: t3")).to be_nil
      expect(runtime.created_id("task_create", handed_over)).to be_nil
    end
  end

  describe "TaskRuntime.adopt: a command execute handed over at its limit" do
    let(:runtime) { Samagotchi::Tools::TaskRuntime }

    # What execute does before a hand-over: the command in its own group,
    # stdout and stderr in two logs outside tmp/tasks, an exit_code file.
    def spawn_like_execute(command)
      dir = File.expand_path("state/execute")
      FileUtils.mkdir_p(dir)
      paths = { output_path: File.join(dir, "stdout.log"), stderr_path: File.join(dir, "stderr.log"),
                exit_code_path: File.join(dir, "exit_code") }
      started_at = Time.now - 5
      pid = Samagotchi::ProcessGroup.spawn(*Samagotchi::Tools::Shell.argv(runtime.wrapped_shell_command(command, paths[:exit_code_path])),
                                           in: File::NULL, out: paths[:output_path], err: paths[:stderr_path])
      @spawned << [pid, Process.detach(pid)]
      [pid, started_at, paths]
    end

    before { @spawned = [] }

    # As execute hands one over: a TaskRecord.running with the spawn's time.
    def adopt(started_at:, **fields)
      runtime.adopt(Samagotchi::Tools::TaskRecord.running(started_at: started_at.utc.iso8601, **fields))
    end

    # Stopped even when the example failed before adopt wrote a record, but
    # only while its waiter runs: a reaped pid (stopped by stop_task, or
    # ended) may lead another group by now.
    after do
      @spawned.each do |pid, waiter|
        next unless waiter.alive?

        Samagotchi::ProcessGroup.stop(pid, grace: 0.5, poll: 0.05, quiet: [Errno::ESRCH, Errno::EPERM])
      end
    end

    it "writes a running record with the spawn time, the pid's start time read now, and absolute paths" do
      pid, started_at, paths = spawn_like_execute("sleep 31.81")
      id = runtime.generate_task_id

      record, error = adopt(id: id, command: " sleep 31.81 ", cwd: Dir.pwd, pid: pid, started_at: started_at, **paths)

      expect(error).to be_nil
      expect(record).to have_attributes(id: id, command: "sleep 31.81", status: "running", pid: pid,
                                        cwd: Dir.pwd, workspace_root: Dir.pwd, handed_over_by: "execute",
                                        created_at: started_at.utc.iso8601, started_at: started_at.utc.iso8601,
                                        output_path: paths[:output_path], stderr_path: paths[:stderr_path],
                                        exit_code_path: paths[:exit_code_path])
      expect(record.pid_started).to eq(Samagotchi::ProcessGroup.start_time(pid))
      expect(runtime.get_record(id).first).to have_attributes(status: "running")
      expect(runtime.command_of(id)).to eq("sleep 31.81")

      stopped, = runtime.stop_task(id, by: "user")
      expect(stopped).to have_attributes(status: "stopped", stop_reason: "stopped_by_user")
      expect(Samagotchi::ProcessGroup.alive?(pid)).to be(false)
    end

    it "ends as the command did, from its exit_code file" do
      pid, started_at, paths = spawn_like_execute("sleep 0.3; echo out; echo err >&2; (exit 3)")
      id = runtime.generate_task_id
      adopt(id: id, command: "x", cwd: nil, pid: pid, started_at: started_at, **paths)

      result = Samagotchi::Tools::TaskWait.call(id, timeout: 10)

      expect(result).to include("status: failed", "exit_code: 3", "output_path: #{paths[:output_path]}",
                                "stderr_path: #{paths[:stderr_path]}")
      expect(Samagotchi::Tools::TaskGet.call(id)).to include("stderr_path: #{paths[:stderr_path]}")
      expect(result).to include("output_tail:\nout", "stderr_tail:\nerr")
    end

    it "refuses a bad id, an existing task, a relative path or a pid chi can't stop, and writes nothing" do
      pid, started_at, paths = spawn_like_execute("sleep 31.82")
      taken, = runtime.create_task("true")
      args = { command: "x", cwd: nil, pid: pid, started_at: started_at, **paths }

      expect(adopt(id: "../x", **args)).to eq([nil, "Error: invalid task id: ../x"])
      expect(adopt(id: taken.id, **args)).to eq([nil, "Error: task already exists: #{taken.id}"])
      id = runtime.generate_task_id
      expect(adopt(id: id, **args, stderr_path: "stderr.log").last).to eq("Error: stderr_path must be absolute: stderr.log")
      expect(adopt(id: id, **args, pid: 1).last).to start_with("Error: not a process chi can stop")
      expect(runtime.load_record(id)).to be_nil
    end
  end

  describe "the exit_code wrapper (an EXIT trap set before the command)" do
    {
      "echo a \\" => [0, "a\n"],
      "echo x; exit 3" => [3, "x\n"],
      "set -e; false; echo no" => [1, ""]
    }.each do |command, (code, output)|
      it "records #{code} for #{command.inspect}, with its output as typed" do
        record, = Samagotchi::Tools::TaskRuntime.create_task(command)
        result = Samagotchi::Tools::TaskWait.call(record.id, timeout: 10)

        expect(result).to include("exit_code: #{code}")
        expect(File.read(record.output_path)).to eq(output)
      end
    end

    it "fails a command with a trailing pipe (a parse error), never as a success" do
      record, = Samagotchi::Tools::TaskRuntime.create_task("echo a |")

      expect(Samagotchi::Tools::TaskWait.call(record.id, timeout: 10)).to include("status: failed")
    end
  end

  it "writes command output that can be read from output_path" do
    create_result = Samagotchi::Tools::TaskCreate.call("ruby -e 'puts \"from-output\"'")
    task_id = extract_field(create_result, "task_id")

    get_result = wait_for_task(task_id)
    output_path = extract_field(get_result, "output_path")

    expect(File.exist?(output_path)).to be(true)
    expect(File.read(output_path)).to include("from-output")
  end

  def wait_for_task(task_id, timeout: 10.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

    loop do
      result = Samagotchi::Tools::TaskGet.call(task_id)
      return result unless result.include?("status: running")

      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep(0.05)
    end

    Samagotchi::Tools::TaskGet.call(task_id)
  end

  def extract_field(text, key)
    line = text.lines.find { |candidate| candidate.start_with?("#{key}:") }
    line.to_s.split(":", 2).last.to_s.strip
  end
end
