# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"

# The turn's cross-thread state as other threads see it: the turn flag,
# the cancel controller, the turn's sink, the steers and the activity
# clock. engine_steer_spec.rb pins the steers dropped after a completed
# and a failed turn; this adds the Interrupt ending.
RSpec.describe Samagotchi::Engine, "turn state" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { instance_double(Samagotchi::Client) }
  let(:kernel) { instance_double(Samagotchi::KernelLoop) }
  let(:engine) { described_class.new(client: client, kernel: kernel, profile: "gemma4") }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(Samagotchi::Log).to receive(:info).and_call_original
  end

  def kernel_result(output = "done")
    Samagotchi::LLM::ModelResult.new(text: output, conversation: [{ role: "model", content: output }], exhausted: false,
                                     pending_tool_calls: false, tool_activity: [], canceled: false)
  end

  def expect_idle
    expect(engine.turn_running?).to be(false)
    expect(engine.active_cancel_controller).to be_nil
    expect(engine.cancel_current_turn!).to be(false)
  end

  describe "the turn flag and the cancel controller" do
    it "are set while the kernel runs and cleared after a completed turn" do
      seen = nil
      allow(kernel).to receive(:run) do |_messages, cancel_controller:, **|
        seen = [engine.turn_running?, engine.active_cancel_controller]
        expect(seen.last).to equal(cancel_controller)
        kernel_result
      end

      engine.run_turn(session, "hi")

      expect(seen.first).to be(true)
      expect(seen.last).to be_a(Samagotchi::CancellationController)
      expect_idle
    end

    it "are cleared after a failed turn" do
      allow(kernel).to receive(:run) { raise "boom" }

      expect { engine.run_turn(session, "hi") }.to raise_error(RuntimeError, "boom")

      expect_idle
    end

    it "are cleared after an Interrupt, and a steer left is logged as dropped" do
      allow(kernel).to receive(:run) do
        engine.steer("too late", source: "check-in")
        raise Interrupt
      end

      expect { engine.run_turn(session, "hi") }.to raise_error(Interrupt)

      expect_idle
      expect(Samagotchi::Log).to have_received(:info).with(:turn, "steer_dropped", source: "check-in", why: "turn_ended", chars: 8)
    end

    it "cancel_current_turn! is false when idle" do
      expect(engine.cancel_current_turn!).to be(false)
    end
  end

  it "record_activity advances activity_seq at the turn's release" do
    allow(kernel).to receive(:run) { kernel_result }
    before_seq = engine.activity_seq
    before_at = engine.last_activity_at

    engine.run_turn(session, "hi")

    expect(engine.activity_seq).to be > before_seq
    expect(engine.last_activity_at).to be >= before_at
  end

  it "a card and a hook notice shown in the turn reach the turn's sink" do
    sunk = []
    allow(kernel).to receive(:run) do
      engine.show_card(source: "spec", title: "Card")
      engine.send(:hook_notify, "heads up", :info, "spec-hook")
      kernel_result
    end

    engine.run_turn(session, "hi", on_event: ->(event) { sunk << event })

    card = sunk.find { |e| e[:type] == :card }
    notice = sunk.find { |e| e[:type] == :hook_notice }
    expect(card).to include(title: "Card", in_turn: true)
    expect(notice).to include(text: "heads up", hook: "spec-hook")
  end

  it "drains or logs every accepted steer exactly once under 4 steering threads" do
    accepted = Queue.new
    drained = []
    dropped = []
    allow(Samagotchi::Log).to receive(:info).and_wrap_original do |original, *args, **fields|
      dropped << fields[:source] if args == [:turn, "steer_dropped"]
      original.call(*args, **fields)
    end
    allow(kernel).to receive(:run) do |_messages, pending_input:, **|
      threads = Array.new(4) do |t|
        Thread.new do
          50.times do |i|
            source = "t#{t}-#{i}"
            accepted << source if engine.steer("s", source: source)
          end
        end
      end
      drained.concat(pending_input.call(at_answer: false)) while threads.any?(&:alive?)
      threads.each(&:join)
      # Half drained now, the rest left for the turn's end.
      drained.concat(pending_input.call(at_answer: false))
      4.times { |t| engine.steer("s", source: "late-#{t}") && accepted << "late-#{t}" }
      kernel_result
    end

    engine.run_turn(session, "hi")

    accepted_sources = []
    accepted_sources << accepted.pop until accepted.empty?
    taken = drained.map { |s| s[:source] }
    expect(accepted_sources.size).to eq(204)
    expect((taken + dropped).sort).to eq(accepted_sources.sort)
    expect(dropped).to match_array(%w[late-0 late-1 late-2 late-3])
  end

  describe "the begin window (cell A)" do
    it "today: during the profile probe the flag is set but there is no controller, so a Stop is lost" do
      entered = Queue.new
      release = Queue.new
      allow(engine).to receive(:refresh_profile!) do
        entered << true
        release.pop
      end
      allow(kernel).to receive(:run) { kernel_result }

      turn = Thread.new { engine.run_turn(session, "hi") }
      entered.pop
      observed = [engine.turn_running?, engine.active_cancel_controller, engine.cancel_current_turn!(:manual)]
      release << true
      result = turn.value

      expect(observed).to eq([true, nil, false])
      expect(result.canceled?).to be(false)
    end
  end

  describe "a raise in the profile refresh (cell A2)" do
    it "today: leaves the turn flag set" do
      allow(engine).to receive(:refresh_profile!).and_raise(RuntimeError, "probe failed")

      expect { engine.run_turn(session, "hi") }.to raise_error(RuntimeError, "probe failed")

      expect(engine.turn_running?).to be(true)
    end
  end
end
