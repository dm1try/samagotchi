# frozen_string_literal: true

require "spec_helper"
require "samagotchi/task_watch"

# The background tasks a worker's session started and hasn't seen finish
# (docs/internals/background-tasks.md, Finish wake), fed by the Engine's
# :tool_call_completed events.
RSpec.describe Samagotchi::TaskWatch do
  subject(:watch) { described_class.new }

  def completed(tool, output) = { type: :tool_call_completed, tool: tool, output: output }

  def created(id) = completed("task_create", "task_id: #{id}\nstatus: running\noutput_path: tmp/tasks/#{id}/output.log")

  def handed_over(id, limit: 120, lead: "")
    completed("execute", "#{lead}#{Samagotchi::Tools::Execute.handed_over_line(limit)}\ntask_id: #{id}\nstdout_tail:\n")
  end

  def waited(id, status:, wait_result: nil, lead: "")
    lines = ["#{lead}task_id: #{id}", "status: #{status}", "exit_code: 0", "stop_reason: ", "output_path: x"]
    lines << "wait_result: #{wait_result}" if wait_result
    completed("task_wait", (lines + ["output_tail:", "done"]).join("\n"))
  end

  describe "adding" do
    it "watches a task_create's task and an execute handed over at its limit, with that limit" do
      watch.observe(created("aaa"))
      watch.observe(handed_over("bbb", limit: 5))

      expect(watch.ids).to eq(%w[aaa bbb])
      expect(watch.entry("aaa").limit_sec).to be_nil
      expect(watch.entry("bbb").limit_sec).to eq(5)
    end

    it "reads past the [tool] lead and a gate-corrected call's ran-as line" do
      watch.observe(completed("task_create", "ran as: task_create sleep 1\n[task_create]\ntask_id: ccc\nstatus: running"))
      watch.observe(handed_over("ddd", lead: "[execute]\n"))

      expect(watch.ids).to eq(%w[ccc ddd])
    end

    it "doesn't count a task_id: line an execute's command printed" do
      watch.observe(completed("execute", "exit_code: 0\nstdout:\ntask_id: fake\n"))
      watch.observe(completed("execute", "task_id: fake2\nStill running at the 120s limit: x\n"))

      expect(watch.ids).to be_empty
    end

    it "ignores other events and other tools" do
      watch.observe({ type: :tool_call_started, tool: "task_create", output: "task_id: x" })
      watch.observe(completed("read", "task_id: y"))

      expect(watch).not_to be_any
    end
  end

  describe "removing what the model saw" do
    before { %w[t1 t2 t3 t4 t5].each { |id| watch.observe(created(id)) } }

    it "drops a task task_wait saw finish, or saw its done_pattern match (D5)" do
      watch.observe(waited("t1", status: "completed"))
      watch.observe(waited("t2", status: "running", wait_result: "pattern_matched", lead: "[task_wait]\n"))

      expect(watch.ids).to eq(%w[t3 t4 t5])
    end

    it "keeps a task a wait timed out on or a Stop cut short" do
      watch.observe(waited("t1", status: "running", wait_result: "timeout"))
      watch.observe(waited("t2", status: "running", wait_result: "canceled"))

      expect(watch.ids).to eq(%w[t1 t2 t3 t4 t5])
    end

    it "drops a task task_get saw finished, not one it saw running" do
      watch.observe(completed("task_get", "task_id: t1\nstatus: failed\ncommand: x"))
      watch.observe(completed("task_get", "task_id: t2\nstatus: running\ncommand: x"))

      expect(watch.ids).to eq(%w[t2 t3 t4 t5])
    end

    it "drops a task the model stopped" do
      watch.observe(completed("task_stop", "task_id: t3\nstatus: stopped\nexit_code: 143"))

      expect(watch.ids).to eq(%w[t1 t2 t4 t5])
    end

    it "keeps a task only task_list, a read of its log or an error named" do
      watch.observe(completed("task_list", "task_id: t1\nstatus: completed"))
      watch.observe(completed("read", "task_id: t2\nstatus: completed"))
      watch.observe(completed("task_wait", "Error: task not found: t3"))

      expect(watch.ids).to eq(%w[t1 t2 t3 t4 t5])
    end
  end

  describe "a user's Stop of the turn (M5)" do
    it "makes the tasks that turn started or waited on note-only; the earlier ones keep waking" do
      watch.observe(created("old"))
      watch.observe(created("other"))
      watch.turn_started
      watch.observe(created("new"))
      watch.observe(waited("other", status: "running", wait_result: "canceled"))
      watch.turn_canceled(:user)

      expect(watch.entry("new").note_only).to be(true)
      expect(watch.entry("other").note_only).to be(true)
      expect(watch.entry("old").note_only).to be(false)
    end

    it "leaves them waking for a cancel that wasn't the user's (a signal, a hook)" do
      watch.turn_started
      watch.observe(created("new"))
      watch.turn_canceled(:signal)
      watch.turn_canceled(:hook)

      expect(watch.entry("new").note_only).to be(false)
    end
  end

  describe "#take_finished" do
    let(:running) { instance_double(Samagotchi::Tools::TaskRecord, running?: true) }
    let(:done) { instance_double(Samagotchi::Tools::TaskRecord, running?: false, stopped_by_user?: false) }
    let(:user_stopped) { instance_double(Samagotchi::Tools::TaskRecord, running?: false, stopped_by_user?: true) }

    before do
      %w[run done user gone].each { |id| watch.observe(created(id)) }
      records = { "run" => [running, nil], "done" => [done, nil], "user" => [user_stopped, nil],
                  "gone" => [nil, "Error: task not found: gone"] }
      allow(Samagotchi::Tools::TaskRuntime).to receive(:get_record) { |id| records.fetch(id) }
    end

    it "takes the finished ones out with their records; drops a user-stopped or vanished one; keeps a running one" do
      taken = watch.take_finished

      expect(taken.map { |entry, record| [entry.id, record] }).to eq([["done", done]])
      expect(watch.ids).to eq(%w[run])
    end

    it "asks nothing with an empty watch" do
      empty = described_class.new
      expect(empty.take_finished).to eq([])
      expect(Samagotchi::Tools::TaskRuntime).not_to have_received(:get_record)
    end

    it "keeps only the ids +keep+ allows (the conversation may have lost a result: !rollback), logging the drop" do
      allow(Samagotchi::Log).to receive(:debug)
      expect(watch.take_finished(keep: %w[run]).map(&:first)).to eq([])
      expect(watch.ids).to eq(%w[run])
      expect(Samagotchi::Log).to have_received(:debug)
        .with(:worker, "task_watch_dropped", task_id: "done", reason: "not_in_conversation")
    end

    it "doesn't return a task another look removed while it refreshed (a task_wait on another thread)" do
      allow(Samagotchi::Tools::TaskRuntime).to receive(:get_record) do |id|
        watch.remove("done") if id == "done"
        [done, nil]
      end

      expect(watch.take_finished.map { |entry, _| entry.id }).to eq(%w[run user gone])
    end
  end

  it "says which watched tasks still run, for the idle exit" do
    watch.observe(created("a"))
    watch.observe(created("b"))
    allow(Samagotchi::Tools::TaskRuntime).to receive(:get_record) do |id|
      [instance_double(Samagotchi::Tools::TaskRecord, running?: id == "a", command: "sleep 9"), nil]
    end

    expect(watch.running).to eq([{ id: "a", command: "sleep 9" }])
  end
end
