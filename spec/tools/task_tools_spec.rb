# frozen_string_literal: true

require "fileutils"
require "samagotchi/tools/task_create"
require "samagotchi/tools/task_get"
require "samagotchi/tools/task_list"
require "samagotchi/tools/task_runtime"
require "samagotchi/tools/task_stop"
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
