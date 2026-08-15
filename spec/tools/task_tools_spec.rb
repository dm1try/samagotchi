# frozen_string_literal: true

require "fileutils"
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
      expect(result).to include("stop_reason: stopped_by_user")

      get_result = Samagotchi::Tools::TaskGet.call(task_id)
      expect(get_result).not_to include("status: running")
    end

    it "returns an error for an unknown task id" do
      result = described_class.call("does-not-exist")

      expect(result).to include("Error: task not found")
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

      result = described_class.call(task_id, timeout: 1, done_pattern: "Done!")

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

    it "returns failed status when task is stopped via task_stop" do
      create_result = Samagotchi::Tools::TaskCreate.call("sleep 30")
      task_id = extract_field(create_result, "task_id")
      Samagotchi::Tools::TaskStop.call(task_id)
      result = described_class.call(task_id)
      expect(result).to include("task_id: #{task_id}")
      expect(result).to include("status: failed")
      expect(result).to include("stop_reason: stopped_by_user")
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

  it "writes command output that can be read from output_path" do
    create_result = Samagotchi::Tools::TaskCreate.call("ruby -e 'puts \"from-output\"'")
    task_id = extract_field(create_result, "task_id")

    get_result = wait_for_task(task_id)
    output_path = extract_field(get_result, "output_path")

    expect(File.exist?(output_path)).to be(true)
    expect(File.read(output_path)).to include("from-output")
  end

  def wait_for_task(task_id, timeout: 4.0)
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
