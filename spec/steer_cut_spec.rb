# frozen_string_literal: true

require "samagotchi/steer_cut"
require "samagotchi/cancellation_controller"

RSpec.describe Samagotchi::SteerCut do
  let(:now) { [1000.0] }
  let(:turn) { Samagotchi::CancellationController.new }
  let(:running) { [turn] }
  let(:steer_cut) { described_class.new(clock: -> { now.first }, controller: -> { running.first }) }

  def thinking(seconds)
    steer_cut.observe({ type: :generation_chunk, thinking: "hm" }, { thinking: "hm", text: "" })
    now[0] += seconds
    steer_cut.observe({ type: :generation_chunk, thinking: "x" }, { thinking: "x", text: "" })
  end

  # Yields inside one generation of the turn; returns its cut detail (nil
  # when it wasn't cut).
  def in_generation
    turn.generation do |child|
      steer_cut.observe({ type: :generation_started })
      yield
      child.cancelled? ? child.detail : nil
    end
  end

  def steer_detail(source) = { by: "steer", steer: true, source: source, reason: "a new message" }

  it "cuts a generation thinking for steer.cut_after (25 s by default), reading the clock it was given" do
    answer = nil
    detail = in_generation do
      thinking(25)
      answer = steer_cut.cut_for_steer("chi_send")
    end

    expect(answer).to eq(:now)
    expect(detail).to eq(steer_detail("chi_send"))
  end

  it "reads the controller only when a cut is due" do
    reads = 0
    lazy = described_class.new(clock: -> { now.first }, controller: -> { (reads += 1) && turn })
    turn.generation do
      lazy.observe({ type: :generation_started })
      lazy.observe({ type: :generation_chunk, thinking: "hm" }, { thinking: "hm", text: "" })
      expect(lazy.cut_for_steer("plugin_send")).to eq(:off)
      expect(reads).to eq(0)
    end
  end

  it "is :off with no turn running, and for a plugin" do
    running.replace([nil])
    expect(steer_cut.cut_for_steer(nil)).to eq(:off)
    running.replace([turn])
    detail = in_generation do
      thinking(30)
      expect(steer_cut.cut_for_steer("check-in")).to eq(:off)
    end
    expect(detail).to be_nil
  end

  it "lets a message that came too early wait (:waits), and cuts on the thinking chunk that passes steer.cut_after" do
    detail = in_generation do
      thinking(5)
      expect(steer_cut.cut_for_steer(nil, epoch: steer_cut.input_epoch)).to eq(:waits)
      thinking(25)
    end

    expect(detail).to eq(steer_detail(""))
  end

  it "drops a waiting message once its input was delivered, or the turn ended" do
    [-> { steer_cut.delivered! }, -> { steer_cut.finished! }].each do |ending|
      detail = in_generation do
        thinking(5)
        steer_cut.cut_for_steer(nil, epoch: steer_cut.input_epoch)
        ending.call
        steer_cut.observe({ type: :generation_started })
        thinking(30)
      end
      expect(detail).to be_nil
    end
  end

  it "doesn't wait when a drain took input since the epoch was read" do
    epoch = steer_cut.input_epoch
    steer_cut.delivered!

    detail = in_generation do
      thinking(5)
      expect(steer_cut.cut_for_steer(nil, epoch: epoch)).to eq(:off)
      thinking(30)
    end
    expect(detail).to be_nil
  end

  it "reads a chunk's lanes when they aren't given: no lanes is text" do
    expect(described_class.lanes({ content: "A" })).to eq(thinking: "", text: "A")

    detail = in_generation do
      steer_cut.observe({ type: :generation_chunk, content: "hm", text: "", thinking: "hm" })
      now[0] += 30
      steer_cut.observe({ type: :generation_chunk, content: "x", text: "", thinking: "x" })
      expect(steer_cut.cut_for_steer(nil)).to eq(:now)
    end
    expect(detail).to eq(steer_detail(""))

    steer_cut.finished!
    detail = in_generation do
      thinking(30)
      steer_cut.observe({ type: :generation_chunk, content: "Answer" })
      steer_cut.cut_for_steer(nil)
    end
    expect(detail).to be_nil
  end

  it "doesn't cut a generation that finished, nor one past visible text" do
    in_generation do
      thinking(30)
      steer_cut.observe({ type: :generation_completed })
      # Its message waits for the next generation: the turn ends instead.
      expect(steer_cut.cut_for_steer(nil)).to eq(:waits)
    end
    steer_cut.finished!
    detail = in_generation do
      thinking(30)
      steer_cut.observe({ type: :generation_chunk, text: "A" }, { thinking: "", text: "A" })
      steer_cut.cut_for_steer(nil)
    end
    expect(detail).to be_nil
  end

  it "is :off when cutting is off (steer.cut_after 0): nothing waits either" do
    with_env("SAMAGOTCHI_STEER_CUT_AFTER" => "0") do
      detail = in_generation do
        thinking(30)
        expect(steer_cut.cut_for_steer(nil, epoch: steer_cut.input_epoch)).to eq(:off)
        thinking(30)
      end
      expect(detail).to be_nil
    end
  end

  it "is :waits when the generation isn't cuttable, and :off once a drain took the message" do
    detail = in_generation do
      thinking(30)
      steer_cut.observe({ type: :generation_chunk, text: "A" }, { thinking: "", text: "A" })
      expect(steer_cut.cut_for_steer(nil, epoch: steer_cut.input_epoch)).to eq(:waits)
    end
    expect(detail).to be_nil

    epoch = steer_cut.input_epoch
    steer_cut.delivered!
    detail = in_generation do
      thinking(5)
      # The drain took the message after the epoch was read: it doesn't wait.
      expect(steer_cut.cut_for_steer(nil, epoch: epoch)).to eq(:off)
      thinking(30)
    end
    expect(detail).to be_nil
  end
end
