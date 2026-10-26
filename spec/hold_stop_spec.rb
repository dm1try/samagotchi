# frozen_string_literal: true

require "spec_helper"
require "samagotchi/hold_stop"
require "samagotchi/reminder_store"
require "samagotchi/children_status"
require "samagotchi/task_watch"
require "samagotchi/tools/task_runtime"

RSpec.describe Samagotchi::HoldStop do
  let(:reminders) { Samagotchi::ReminderStore.new }
  let(:engine) { double("engine", reminder_store: reminders) }
  let(:child) do
    Samagotchi::ChildrenStatus::Child.new(id: "c1c1c1c1-1111", short_id: "c1c1c1c1", title: "Fix the composer",
                                          state: "running", waiting: nil, live: true, delegate: true, cwd: "/tmp/x",
                                          branch: "main", last_reply: nil, last_reply_at: nil, reported: false,
                                          updated_at: "2026-10-27T10:00:00Z", archived: false)
  end
  let(:watch) { double("watch", running: [Samagotchi::TaskWatch::Running.new(id: "t1", command: "rails s", age_seconds: 10)]) }
  let(:stopper) do
    described_class.new(engine: engine, task_watch: watch, delegates: -> { [child] }, state_dir: "/tmp/state")
  end

  it "clears the reminders and reports their names" do
    reminders.register(name: "api_health", description: "check the API", interval_minutes: 20)
    reminders.register(name: "stretch", description: "stretch", interval_minutes: 5)

    expect(stopper.stop_all.reminders).to eq(%w[api_health stretch])
    expect(reminders.reminders).to be_empty
  end

  it "stops each running task the way task_stop and the web's button do" do
    asked = []
    allow(Samagotchi::Tools::TaskRuntime).to receive(:stop_task) do |id, by:|
      asked << [id, by]
      [{ id: id, status: "stopped" }, nil]
    end

    expect(stopper.stop_all.tasks).to eq(["rails s"])
    expect(asked).to eq([%w[t1 user]])
  end

  it "leaves a task it could not stop out of the report, logged" do
    allow(Samagotchi::Tools::TaskRuntime).to receive(:stop_task).and_return([nil, "Error: task not found: t1"])
    allow(Samagotchi::Log).to receive(:warn)

    expect(stopper.stop_all.tasks).to eq([])
    expect(Samagotchi::Log).to have_received(:warn)
      .with(:worker, "exit_stop_task_failed", task_id: "t1", error: "Error: task not found: t1")
  end

  it "stops each delegate as chi sessions stop does, in this session's state dir" do
    allow(Samagotchi::SessionManager).to receive(:stop_session)

    expect(stopper.stop_all.delegates).to eq(["c1c1c1c1"])
    expect(Samagotchi::SessionManager).to have_received(:stop_session).with("c1c1c1c1-1111", state_dir: "/tmp/state")
  end

  it "reports nothing for a child a terminal owns, and stops the rest" do
    allow(Samagotchi::SessionManager).to receive(:stop_session) { |_id, **| raise Samagotchi::SessionManager::OwnedByTUI, "c1c1c1c1-1111" }
    allow(Samagotchi::Log).to receive(:warn)

    expect(stopper.stop_all.delegates).to eq([])
    expect(Samagotchi::Log).to have_received(:warn)
      .with(:worker, "exit_stop_delegate_failed", child: "c1c1c1c1", error: "Samagotchi::SessionManager::OwnedByTUI",
           msg: "session c1c1c1c1-1111 is open in a chi REPL; close it there first")
  end

  it "says nothing was stopped when there was nothing to stop" do
    stopper = described_class.new(engine: engine, task_watch: nil, delegates: -> { [] }, state_dir: "/tmp/state")

    expect(stopper.stop_all).to eq(described_class::Stopped.new)
    expect(stopper.stop_all).not_to be_any
  end
end
