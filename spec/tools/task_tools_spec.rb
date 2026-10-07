# frozen_string_literal: true

require "fileutils"
require "samagotchi/tools/builtins"
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
          Samagotchi::Tools::TaskRuntime.stop_task(record["id"], by: "model")
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
      Samagotchi::Tools::TaskRuntime.stop_task(user_task["id"], by: "user")
      Samagotchi::Tools::TaskRuntime.stop_task(model_task["id"], by: "model")

      expect(described_class.call(user_task["id"])).to end_with("note: the user stopped this task; don't restart it unless they ask.")
      expect(described_class.call(model_task["id"])).not_to include("note:")
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

      stopped, error = described_class.stop_task(record["id"], by: "user")

      expect(error).to be_nil
      expect(stopped).to include("status" => "stopped", "stop_reason" => "stopped_by_user", "stop_requested_by" => "user")
      expect(described_class.get_record(record["id"]).first).to include("status" => "stopped", "stop_reason" => "stopped_by_user")
    end

    it "ends a stop as stopped when the command traps TERM and exits non-zero" do
      record, = described_class.create_task("trap 'exit 7' TERM; while true; do sleep 0.1; done")

      stopped, = described_class.stop_task(record["id"], by: "model")

      expect(stopped).to include("status" => "stopped", "stop_reason" => "stopped_by_model")
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

      stopped, = described_class.stop_task(record["id"], by: "model")

      expect(stopped).to include("status" => "stopped")
      expect(running?("sleep 31.75")).to be(false)
    end

    it "KILLs a task that ignores TERM once the grace is over" do
      stub_const("#{described_class}::STOP_GRACE_SEC", 0.3)
      record, = described_class.create_task("trap '' TERM; sleep 31.76")
      expect(wait_until { system("pgrep", "-f", "sleep 31.76", out: File::NULL) }).to be(true)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      stopped, = described_class.stop_task(record["id"], by: "model")

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be_between(0.3, 2)
      expect(stopped).to include("status" => "stopped", "stop_reason" => "stopped_by_model")
      expect(running?("sleep 31.76")).to be(false)
    end

    it "never shows failed to a reader polling during the stop" do
      record, = described_class.create_task("sleep 30")
      seen = []
      done = false
      reader = Thread.new do
        until done
          seen << described_class.get_record(record["id"]).first&.fetch("status")
          sleep 0.005
        end
      end

      described_class.stop_task(record["id"], by: "user")
      done = true
      reader.join

      expect(seen).not_to include("failed")
      expect(described_class.get_record(record["id"]).first).to include("status" => "stopped", "stop_reason" => "stopped_by_user")
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
        record = { "id" => described_class.generate_task_id, "command" => "sleep 30", "status" => "running",
                   "created_at" => "2026-10-06T00:00:00Z", "exit_code_path" => File.join(Dir.pwd, "no-exit-code") }
        record["pid"] = pid unless pid == :missing
        described_class.write_record(record)
        record
      end

      def signals = kills.reject { |sig, _| sig.zero? }

      [:missing, 0, 1, "abc"].each do |pid|
        it "signals nothing for a pid #{pid.inspect}, and ends the task as failed, saying why" do
          record = running_record(pid)

          stopped, error = described_class.stop_task(record["id"], by: "model")

          expect(error).to be_nil
          expect(stopped).to include("status" => "failed", "stop_reason" => described_class::NOT_CHIS_PROCESS)
          expect(kills.map(&:last)).not_to include(0, 1, -1)
          expect(signals).to be_empty
        end
      end

      it "signals nothing for a live pid that doesn't lead its own group (reused by another process)" do
        other = Process.spawn("sleep", "31.78") # this spec's own child, in rspec's group
        record = running_record(other)

        expect(described_class.get_record(record["id"]).first).to include("status" => "failed",
                                                                          "stop_reason" => described_class::NOT_CHIS_PROCESS)
        stopped, = described_class.stop_task(record["id"], by: "model")

        expect(stopped).to include("status" => "failed")
        expect(signals).to be_empty
        expect(Process.wait2(other, Process::WNOHANG)).to be_nil
      ensure
        if other
          Process.kill("KILL", other)
          Process.wait(other)
        end
      end
    end

    it "keeps a stop that already finished on disk when a stale copy is refreshed" do
      record, = described_class.create_task("sleep 30")
      stale = described_class.load_record(record["id"])
      described_class.stop_task(record["id"], by: "user")

      expect(described_class.refresh_record(stale)).to include("status" => "stopped", "stop_reason" => "stopped_by_user")
      expect(described_class.load_record(record["id"])).to include("status" => "stopped")
    end
  end

  describe Samagotchi::Tools::TaskWait do
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
      expect(Samagotchi::Tools::TaskRuntime.get_record(task_id).first.fetch("status")).to eq("running")
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
      sleep 0.1 until Samagotchi::Tools::TaskRuntime.get_record(task_id).first.fetch("status") != "running"

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
      sleep 0.1 until Samagotchi::Tools::TaskRuntime.get_record(done).first.fetch("status") != "running"
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
