# frozen_string_literal: true

require "spec_helper"
require "samagotchi/worker_idle_exit"
require "samagotchi/reminder_store"
require "samagotchi/relay_desk"

RSpec.describe Samagotchi::WorkerIdleExit do
  let(:now) { [1000.0] }
  let(:clock) { -> { now.first } }
  let(:reminders) { Samagotchi::ReminderStore.new }
  let(:relays) { Samagotchi::RelayDesk.new }
  let(:engine) do
    double("engine", turn_running?: false, last_activity_at: 1000.0, reminder_store: reminders, pending_question: nil,
                     anytime_running?: false, relay_desk: relays)
  end
  let(:tasks) { [[]] }
  let(:bridge) { double("bridge", open_streams: 0, last_client_activity_at: 1000.0) }
  let(:queued) { [false] }
  let(:offer) { [false] }

  def policy(minutes: 1.0, bridge: self.bridge)
    described_class.new(engine: engine, bridge: bridge, timeout_minutes: minutes,
                        input_pending: -> { queued.first }, awaiting_continue: -> { offer.first },
                        running_tasks: -> { tasks.first }, clock: clock)
  end

  def advance(seconds)
    now[0] += seconds
  end

  it "is due once nothing has happened for the timeout" do
    p = policy
    advance(59)
    expect(p.hold).to eq(:recent_activity)
    advance(1)
    expect(p.hold).to be_nil
    expect(p).to be_due
  end

  it "counts from the worker's start" do
    advance(3600)
    p = policy
    expect(p.hold).to eq(:recent_activity)
    advance(60)
    expect(p).to be_due
  end

  it "counts from the Engine's last activity" do
    p = policy
    allow(engine).to receive(:last_activity_at).and_return(1030.0)
    advance(60)
    expect(p.hold).to eq(:recent_activity)
    advance(30)
    expect(p).to be_due
  end

  it "counts from the last client request or disconnect" do
    p = policy
    allow(bridge).to receive(:last_client_activity_at).and_return(1045.0)
    advance(60)
    expect(p.hold).to eq(:recent_activity)
    advance(45)
    expect(p).to be_due
  end

  describe "keeps the worker up" do
    before { advance(3600) }

    it "while a turn runs" do
      allow(engine).to receive(:turn_running?).and_return(true)
      expect(policy(minutes: 0.001).hold).to eq(:turn_running)
    end

    it "while input is queued" do
      queued[0] = true
      expect(policy(minutes: 0.001).hold).to eq(:input_queued)
    end

    it "while a client holds a stream (an attached TUI or a web tab)" do
      allow(bridge).to receive(:open_streams).and_return(1)
      expect(policy(minutes: 0.001).hold).to eq(:client_connected)
    end

    it "while a reminder is registered" do
      reminders.register(name: "stretch", description: "Remind me to stretch", interval_minutes: 60)
      expect(policy(minutes: 0.001).hold).to eq(:reminders)
    end

    it "while a continue offer waits (only the worker's memory has it)" do
      offer[0] = true
      expect(policy(minutes: 0.001).hold).to eq(:continue_offered)
    end

    it "for good with a timeout of 0" do
      expect(policy(minutes: 0).hold).to eq(:disabled)
      expect(policy(minutes: nil).hold).to eq(:disabled)
    end
  end

  it "does without a Bridge (a worker whose Bridge failed to start)" do
    p = policy(bridge: nil)
    advance(60)
    expect(p).to be_due
  end

  describe "#hold_for_request (a client asks the worker to exit now)" do
    before { allow(bridge).to receive(:open_streams_except).and_return(0) }

    it "lets it go at once, whatever the timeout and recent activity" do
      expect(policy.hold).to eq(:recent_activity)
      expect(policy.hold_for_request(requester: "tui:1")).to be_nil
      expect(policy(minutes: 0).hold_for_request(requester: "tui:1")).to be_nil
      expect(policy(bridge: nil).hold_for_request(requester: "tui:1")).to be_nil
    end

    it "holds while a turn runs" do
      allow(engine).to receive(:turn_running?).and_return(true)
      expect(policy.hold_for_request(requester: "tui:1")).to eq(:turn_running)
    end

    it "holds while input is queued" do
      queued[0] = true
      expect(policy.hold_for_request(requester: "tui:1")).to eq(:input_queued)
    end

    it "holds while a continue offer waits" do
      offer[0] = true
      expect(policy.hold_for_request(requester: "tui:1")).to eq(:continue_offered)
      expect(policy(minutes: 0.001).hold).to eq(:continue_offered)
    end

    it "holds while anyone but the asker holds a stream" do
      allow(bridge).to receive(:open_streams).and_return(1)
      allow(bridge).to receive(:open_streams_except).with("tui:1").and_return(1)
      expect(policy.hold_for_request(requester: "tui:1")).to eq(:client_connected)
      expect(policy.hold_for_request(requester: "tui:1", streams: false)).to be_nil
    end

    it "holds while a reminder is registered" do
      reminders.register(name: "stretch", description: "Remind me to stretch", interval_minutes: 60)
      expect(policy.hold_for_request(requester: "tui:1")).to eq(:reminders)
    end
  end

  it "reports the idle seconds" do
    p = policy
    advance(75)
    expect(p.idle_seconds).to eq(75.0)
  end

  describe "#hold_for_restart (a client asks for a new worker: POST /exit restart: true)" do
    it "lets it go when nothing would be lost, whatever the streams, the timeout and recent activity" do
      allow(bridge).to receive(:open_streams).and_return(2)
      expect(policy.hold_for_restart).to be_nil
      expect(policy(minutes: 0).hold_for_restart).to be_nil
      expect(policy(bridge: nil).hold_for_restart).to be_nil
    end

    it "holds for a turn, queued input, a continue offer, a question and a reminder" do
      allow(engine).to receive(:pending_question).and_return({ id: "q1" })
      expect(policy.hold_for_restart).to eq(:question_pending)
      reminders.register(name: "stretch", description: "Remind me to stretch", interval_minutes: 60)
      allow(engine).to receive(:pending_question).and_return(nil)
      expect(policy.hold_for_restart).to eq(:reminders)
      offer[0] = true
      expect(policy.hold_for_restart).to eq(:continue_offered)
      queued[0] = true
      expect(policy.hold_for_restart).to eq(:input_queued)
      allow(engine).to receive(:turn_running?).and_return(true)
      expect(policy.hold_for_restart).to eq(:turn_running)
    end

    it "holds while an anytime command (/btw) runs" do
      allow(engine).to receive(:anytime_running?).and_return(true)
      expect(policy.hold_for_restart).to eq(:command_running)
    end

    it "holds while a delegate's approval relay is open or recently settled" do
      relays.open(child_id: "c1", child_question_id: "q1")
      expect(policy.hold_for_restart).to eq(:relays_open)
    end

    it "holds while a background task this conversation started runs" do
      tasks[0] = [{ id: "t1", command: "sleep 100" }]
      expect(policy.hold_for_restart).to eq(:background_tasks)
    end
  end
end
