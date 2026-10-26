# frozen_string_literal: true

require "spec_helper"
require "samagotchi/task_watch"
require "samagotchi/worker_idle_exit"
require "samagotchi/reminder_store"
require "samagotchi/relay_desk"
require "samagotchi/children_status"

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
  let(:watched) { [[]] }
  let(:watched_running) { [[]] }
  let(:delegates) { [[]] }
  let(:bridge) { double("bridge", open_streams: 0, last_client_activity_at: 1000.0) }
  let(:queued) { [false] }
  let(:offer) { [false] }

  def policy(minutes: 1.0, bridge: self.bridge)
    described_class.new(engine: engine, bridge: bridge, timeout_minutes: minutes,
                        input_pending: -> { queued.first }, awaiting_continue: -> { offer.first },
                        running_tasks: -> { tasks.first }, watched_tasks: -> { watched.first },
                        watched_running: -> { watched_running.first }, delegates: -> { delegates.first },
                        clock: clock)
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

    it "while a background task it watches for a finish wake runs or waits for its wake (D3)" do
      watched[0] = [Samagotchi::TaskWatch::Entry.new(id: "t1")]
      expect(policy(minutes: 0.001).hold).to eq(:background_tasks)
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

    it "holds while a background task it watches runs, not for one that finished (a note as it leaves)" do
      watched[0] = [Samagotchi::TaskWatch::Entry.new(id: "t1")]
      expect(policy.hold_for_request(requester: "tui:1")).to be_nil
      watched_running[0] = [Samagotchi::TaskWatch::Running.new(id: "t1", command: "rails s", age_seconds: 5)]
      expect(policy.hold_for_request(requester: "tui:1")).to eq(:background_tasks)
    end

    it "as a Hold, names the running tasks from one look (TaskWatch#running runs ps per task)" do
      looks = 0
      running = [Samagotchi::TaskWatch::Running.new(id: "t1", command: "rails s", age_seconds: 42)]
      p = described_class.new(engine: engine, bridge: bridge, timeout_minutes: 1.0, input_pending: -> { false },
                              watched_running: lambda {
                                looks += 1
                                running
                              }, clock: clock)
      expect(p.request_hold(requester: "tui:1", hint: "stop it"))
        .to eq(described_class::Hold.new(reason: :background_tasks,
                                         tasks: [{ id: "t1", command: "rails s", age_seconds: 42 }],
                                         hint: "stop it",
                                         holds: [described_class::StoppableHold.new(
                                           kind: :background_tasks,
                                           items: [described_class::HoldItem.new(id: "t1", label: "rails s", detail: "42s")]
                                         )]))
      expect(looks).to eq(1)
      queued[0] = true
      expect(policy.request_hold(requester: "tui:1")).to eq(described_class::Hold.new(reason: :input_queued))
    end
  end

  describe "the exit ask (what the user can stop)" do
    before { allow(bridge).to receive(:open_streams_except).and_return(0) }

    def child(id, state:, title: "Fix the composer")
      Samagotchi::ChildrenStatus::Child.new(id: id, short_id: id[0, 8], title: title, state: state, waiting: nil,
                                            live: true, delegate: true, cwd: "/tmp/x", branch: "main",
                                            last_reply: nil, last_reply_at: nil, reported: false,
                                            updated_at: "2026-10-27T10:00:00Z", archived: false)
    end

    def task(id, command, age)
      Samagotchi::TaskWatch::Running.new(id: id, command: command, age_seconds: age)
    end

    it "lists the reminders it holds for, each with its schedule" do
      reminders.register(name: "api_health", description: "check the API", interval_minutes: 20)
      reminders.register(name: "stretch", description: "stretch", interval_minutes: 5)

      hold = policy.request_hold(requester: "tui:1")

      expect(hold.reason).to eq(:reminders)
      expect(hold.holds).to eq([
        described_class::StoppableHold.new(kind: :reminders, items: [
          described_class::HoldItem.new(id: "api_health", label: "api_health", detail: "every 20m"),
          described_class::HoldItem.new(id: "stretch", label: "stretch", detail: "every 5m")
        ])
      ])
      expect(hold).to be_ask
    end

    it "lists running tasks, delegates with live workers, and nothing else" do
      reminders.register(name: "api_health", description: "check the API", interval_minutes: 20)
      watched_running[0] = [task("3f9a2c1d-77", "rails s", 125)]
      delegates[0] = [child("c1c1c1c1-1111", state: "running"), child("d2d2d2d2-2222", state: "idle",
                                                                      title: "the dev server")]

      hold = policy.request_hold(requester: "tui:1", hint: "stop them", ask: true)

      expect(hold.holds).to eq([
        described_class::StoppableHold.new(kind: :reminders, items: [
          described_class::HoldItem.new(id: "api_health", label: "api_health", detail: "every 20m")
        ]),
        described_class::StoppableHold.new(kind: :background_tasks, items: [
          described_class::HoldItem.new(id: "3f9a2c1d-77", label: "rails s", detail: "2m")
        ]),
        described_class::StoppableHold.new(kind: :delegates, items: [
          described_class::HoldItem.new(id: "c1c1c1c1-1111", label: "Fix the composer", detail: "running a turn"),
          described_class::HoldItem.new(id: "d2d2d2d2-2222", label: "the dev server", detail: "a live worker")
        ])
      ])
      # Without the ask (an exit that deletes, the worker's own last look),
      # a child is not part of it.
      expect(policy.request_hold(requester: "tui:1").holds.map(&:kind)).to eq(%i[reminders background_tasks])
    end

    it "lists nothing when something the user can't stop holds the worker" do
      reminders.register(name: "api_health", description: "check the API", interval_minutes: 20)
      watched_running[0] = [task("t1", "rails s", 10)]
      delegates[0] = [child("c1c1c1c1-1111", state: "running")]

      allow(engine).to receive(:turn_running?).and_return(true)
      expect(policy.request_hold(requester: "tui:1").holds).to eq([])
      queued[0] = true
      allow(engine).to receive(:turn_running?).and_return(false)
      expect(policy.request_hold(requester: "tui:1").holds).to eq([])
      allow(bridge).to receive(:open_streams_except).with("tui:1").and_return(1)
      queued[0] = false
      hold = policy.request_hold(requester: "tui:1")
      expect(hold.reason).to eq(:client_connected)
      expect(hold.holds).to eq([])
      expect(hold).not_to be_ask
    end

    it "asks for a delegate alone: nothing else runs, and a child never holds the idle exit" do
      delegates[0] = [child("c1c1c1c1-1111", state: "running")]
      p = policy
      advance(3600)

      hold = p.request_hold(requester: "tui:1", ask: true)
      expect(hold.reason).to eq(:delegates)
      expect(hold.holds).to eq([described_class::StoppableHold.new(kind: :delegates, items: [
        described_class::HoldItem.new(id: "c1c1c1c1-1111", label: "Fix the composer", detail: "running a turn")
      ])])
      expect(hold).to be_ask

      # The worker's own leave check and the exit's refusal: a child is not a hold.
      expect(p.request_hold(requester: "tui:1")).to be_nil
      expect(p.hold_for_request(requester: "tui:1")).to be_nil
      expect(p.hold).to be_nil
      expect(p).to be_due
    end

    it "words each reminder's schedule, and only what the store can say" do
      store = double("store", reminders: {
        "a" => { name: "hourly", interval_minutes: 60, next_fire_at: 2000.0 },
        "b" => { name: "ninety", interval_minutes: "90", next_fire_at: 2000.0 },
        "c" => { name: "soon", interval_minutes: 5, next_fire_at: 990.0 },
        "d" => { name: "whenever", description: "no schedule written" }
      })
      allow(engine).to receive(:reminder_store).and_return(store)

      items = policy.request_hold(requester: "tui:1").holds.first.items

      expect(items.map(&:label)).to eq(%w[hourly ninety soon whenever])
      expect(items.map(&:detail)).to eq(["every 1h", "every 90m", "every 5m, due now", nil])
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
