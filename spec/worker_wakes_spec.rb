# frozen_string_literal: true

require "spec_helper"
require "samagotchi/worker_wakes"

RSpec.describe Samagotchi::WorkerWakes do
  let(:now) { [100.0] }
  let(:budget) { [3] }
  let!(:wakes) { described_class.new(grace: 2.0, clock: -> { now[0] }, max: -> { budget[0] }) }

  def pass(seconds) = now[0] += seconds

  describe "the start grace" do
    it "counts down from the start" do
      expect(wakes.grace_left).to eq(2.0)
      expect(wakes.in_grace?).to be(true)
      pass(2.0)
      expect(wakes.in_grace?).to be(false)
    end

    it "shortens the idle sleep only while a wake is due within it" do
      pass(1.5)
      expect(wakes.idle_wait(5) { true }).to eq(0.5)
      expect(wakes.idle_wait(5) { false }).to eq(5)
      expect(wakes.idle_wait(0.1) { true }).to eq(0.1)
      pass(1.0)
      expect(wakes.idle_wait(5) { true }).to eq(5)
    end
  end

  describe "#delegate_state" do
    it "is :due while reports wait and the budget lasts, :budget once it is spent" do
      expect(wakes.delegate_state(awaiting_continue: false) { true }).to eq(:due)
      3.times { wakes.count! }
      expect(wakes.delegate_state(awaiting_continue: false) { true }).to eq(:budget)
    end

    it "is nil with no reports waiting, with a continue offer or while paused, and asks for reports last" do
      asked = 0
      expect(wakes.delegate_state(awaiting_continue: false) { false }).to be_nil
      expect(wakes.delegate_state(awaiting_continue: true) { asked += 1 }).to be_nil
      wakes.pause!
      expect(wakes.delegate_state(awaiting_continue: false) { asked += 1 }).to be_nil
      expect(asked).to eq(0)
    end

    it "ignores the start grace (the idle sleep waits it out)" do
      expect(wakes.in_grace?).to be(true)
      expect(wakes.delegate_state(awaiting_continue: false) { true }).to eq(:due)
    end
  end

  describe "#context_open?" do
    before { pass(2.0) }

    it "opens past the grace, with no offer, unpaused and under the budget" do
      expect(wakes.context_open?(awaiting_continue: false, names: ["ci"])).to be(true)
      expect(wakes.context_open?(awaiting_continue: true, names: ["ci"])).to be(false)
      wakes.pause!
      expect(wakes.context_open?(awaiting_continue: false, names: ["ci"])).to be(false)
    end

    it "stays shut within the start grace" do
      fresh = described_class.new(grace: 2.0, clock: -> { now[0] }, max: -> { 3 })
      expect(fresh.context_open?(awaiting_continue: false, names: ["ci"])).to be(false)
    end

    it "logs the sources the spent budget holds" do
      3.times { wakes.count! }
      expect(Samagotchi::Log).to receive(:info).with(:worker, "context_wake_held", reason: "max_wakes", names: "ci,docs")
      expect(wakes.context_open?(awaiting_continue: false, names: %w[ci docs])).to be(false)
    end
  end

  # The one answer the context and peer gates read: why a wake is held now,
  # apart from the start grace (the callers' own, so a wake can wait it out).
  # Each row is a state of the budgets; the hold is the same within the
  # grace and past it, and it says what today's gates answer.
  describe "#wake_hold" do
    let(:peers) { [2] }
    let!(:wakes) { described_class.new(grace: 2.0, clock: -> { now[0] }, max: -> { budget[0] }, peer_max: -> { peers[0] }) }

    # state => [hold without a continue offer, peer: false / peer: true]
    states = {
      "open" => [[nil, nil], -> {}],
      "paused" => [%i[paused paused], -> { wakes.pause! }],
      "session.max_wakes spent" => [%i[max_wakes max_wakes], -> { 3.times { wakes.count! } }],
      "the peer budget spent" => [[nil, :peer_turns], -> { 2.times { wakes.count!(peer: true) } }],
      "both budgets spent" => [%i[max_wakes max_wakes], lambda {
        2.times { wakes.count!(peer: true) }
        wakes.count!
      }],
      "paused with session.max_wakes spent" => [%i[paused paused], lambda {
        wakes.pause!
        3.times { wakes.count! }
      }],
      "the peer policy off (peer_turns 0)" => [[nil, :peer_turns], -> { peers[0] = 0 }]
    }

    before { allow(Samagotchi::Log).to receive(:info) }

    states.each do |state, (holds, setup)|
      [false, true].each do |grace|
        [false, true].each do |awaiting|
          plain, peer = holds
          plain, peer = [plain, peer].map { |hold| hold == :paused ? :paused : :continue } if awaiting

          it "is #{plain.inspect} / peer #{peer.inspect}: #{state}, #{grace ? "within" : "past"} the grace, " \
             "#{awaiting ? "a continue offer waiting" : "no continue offer"}" do
            instance_exec(&setup)
            pass(2.0) unless grace
            expect(wakes.in_grace?).to be(grace)

            expect(wakes.wake_hold(awaiting_continue: awaiting, peer: false)).to eq(plain)
            expect(wakes.wake_hold(awaiting_continue: awaiting, peer: true)).to eq(peer)

            ready = wakes.context_ready?(awaiting_continue: awaiting, names: ["ci"])
            expect(ready).to eq(plain.nil?)
            expect(wakes.context_open?(awaiting_continue: awaiting, names: ["ci"])).to eq(!grace && plain.nil?)
            # The peer gate as WorkerInbound asks it today: the context gate,
            # then the peer budget.
            expect(ready && wakes.peer_in_a_row < wakes.peer_turns).to eq(peer.nil?)
          end
        end
      end
    end

    it "logs nothing, whatever holds (its callers write the lines)" do
      2.times { wakes.count!(peer: true) }
      pass(2.0)
      expect(wakes.wake_hold(awaiting_continue: false, peer: true)).to eq(:peer_turns)
      wakes.count!
      expect(wakes.wake_hold(awaiting_continue: false, peer: false)).to eq(:max_wakes)
      expect(Samagotchi::Log).not_to have_received(:info)
    end
  end

  # Today's log lines of the context gates, word for word. A peer's line
  # (reason peer_turns) is pinned where WorkerInbound asks the peer gate
  # (worker_inbound_spec, "the wake gates' log lines").
  describe "the context gates' log lines" do
    let(:held) { [] }
    let(:max_wakes_line) { [:worker, "context_wake_held", { reason: "max_wakes", names: "ci,docs" }] }

    before do
      allow(Samagotchi::Log).to receive(:info) { |tag, event, **fields| held << [tag, event, fields] if event == "context_wake_held" }
    end

    it "context_open? logs the sources the spent budget holds past the grace, nothing within it" do
      3.times { wakes.count! }
      expect(wakes.context_open?(awaiting_continue: false, names: %w[ci docs])).to be(false)
      expect(held).to eq([])
      pass(2.0)
      expect(wakes.context_open?(awaiting_continue: false, names: %w[ci docs])).to be(false)
      expect(held).to eq([max_wakes_line])
    end

    it "context_ready? logs the spent budget within the grace too" do
      3.times { wakes.count! }
      expect(wakes.context_ready?(awaiting_continue: false, names: %w[ci docs])).to be(false)
      expect(held).to eq([max_wakes_line])
    end

    it "logs nothing while a continue offer or a pause holds, the budget spent" do
      pass(2.0)
      3.times { wakes.count! }
      expect(wakes.context_open?(awaiting_continue: true, names: %w[ci docs])).to be(false)
      expect(wakes.context_ready?(awaiting_continue: true, names: %w[ci docs])).to be(false)
      wakes.pause!
      expect(wakes.context_open?(awaiting_continue: false, names: %w[ci docs])).to be(false)
      expect(wakes.context_ready?(awaiting_continue: false, names: %w[ci docs])).to be(false)
      expect(held).to eq([])
    end

    it "logs nothing when the gate is open" do
      pass(2.0)
      expect(wakes.context_open?(awaiting_continue: false, names: %w[ci docs])).to be(true)
      expect(held).to eq([])
    end
  end

  describe "#task_open?" do
    it "opens past the grace, with no offer, unpaused and under the budget" do
      expect(wakes.task_open?(awaiting_continue: false)).to be(false)
      pass(2.0)
      expect(wakes.task_open?(awaiting_continue: false)).to be(true)
      expect(wakes.task_open?(awaiting_continue: true)).to be(false)
      3.times { wakes.count! }
      expect(wakes.task_open?(awaiting_continue: false)).to be(false)
      wakes.human_input!
      expect(wakes.task_open?(awaiting_continue: false)).to be(true)
      wakes.pause!
      expect(wakes.task_open?(awaiting_continue: false)).to be(false)
    end
  end

  it "counts wake turns, and a human's input resets the count, the pause and the budget notice" do
    expect(wakes.count!).to eq(1)
    expect(wakes.count!).to eq(2)
    wakes.pause!
    expect(wakes.notice_budget!).to be(true)
    expect(wakes.notice_budget!).to be(false)

    expect(wakes.delegate_state(awaiting_continue: false) { true }).to be_nil
    wakes.human_input!
    expect(wakes.in_a_row).to eq(0)
    expect(wakes.delegate_state(awaiting_continue: false) { true }).to eq(:due)
    expect(wakes.notice_budget!).to be(true)
  end

  it "hands a wake turn's reports over once" do
    wakes.hand_over([:report])
    expect(wakes.take_handed).to eq([:report])
    expect(wakes.take_handed).to be_nil
    wakes.hand_over([:report])
    wakes.drop_handed
    expect(wakes.take_handed).to be_nil
  end

  describe "#max" do
    let(:wakes) { described_class.new(grace: 0) }

    it "reads session.max_wakes, falling back to the default for a value that isn't a positive integer" do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("session.max_wakes").and_return("4", "0", "lots", nil)
      expect([wakes.max, wakes.max, wakes.max, wakes.max])
        .to eq([4, *[Samagotchi::ChildRing::MAX_WAKES_DEFAULT] * 3])
    end
  end

  describe "the peer budget (context.peer_turns)" do
    let(:peers) { [2] }
    let!(:wakes) { described_class.new(grace: 0, max: -> { budget[0] }, peer_max: -> { peers[0] }) }

    it "opens for peer_turns peer wakes in a row, each counting toward both budgets, then holds" do
      budget[0] = 4
      expect(wakes.wake_hold(awaiting_continue: false, peer: true)).to be_nil
      expect(wakes.count!(peer: true)).to eq(1)
      wakes.count!
      expect(wakes.wake_hold(awaiting_continue: false, peer: true)).to be_nil
      wakes.count!(peer: true)

      expect([wakes.in_a_row, wakes.peer_in_a_row]).to eq([3, 2])
      expect(wakes.wake_hold(awaiting_continue: false, peer: true)).to eq(:peer_turns)
    end

    it "is never more than session.max_wakes, and 0 with peer_turns 0" do
      peers[0] = 5
      expect(wakes.peer_turns).to eq(3)
      peers[0] = 0
      expect(wakes.peer_turns).to eq(0)
      expect(wakes.wake_hold(awaiting_continue: false, peer: true)).to eq(:peer_turns)
    end

    it "is reset with its notice by interactive input only; chi send resets session.max_wakes alone" do
      2.times { wakes.count!(peer: true) }
      expect(wakes.notice_peer_budget!).to be(true)
      expect(wakes.notice_peer_budget!).to be(false)

      wakes.human_input!(interactive: false)
      expect([wakes.in_a_row, wakes.peer_in_a_row]).to eq([0, 2])
      expect(wakes.notice_peer_budget!).to be(false)

      wakes.human_input!(interactive: true)
      expect([wakes.in_a_row, wakes.peer_in_a_row]).to eq([0, 0])
      expect(wakes.notice_peer_budget!).to be(true)
    end

    it "reads context.peer_turns: 0 or less is off, a non-integer the default" do
      plain = described_class.new(grace: 0)
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("context.peer_turns").and_return("4", "0", "-2", "lots", nil)
      expect(Array.new(5) { plain.peer_max }).to eq([4, 0, 0, 3, 3])
    end
  end
end
