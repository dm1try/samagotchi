# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"

# Engine#steer: a plugin's text into the running turn, drained with the
# caller's steering at the loop's boundaries (Steer).
RSpec.describe Samagotchi::Engine, "#steer" do
  around do |example|
    original = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    example.run
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original
  end

  let(:client) { instance_double(Samagotchi::Client) }
  let(:kernel) { instance_double(Samagotchi::KernelLoop) }
  let(:engine) { described_class.new(client: client, kernel: kernel, profile: "gemma4") }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }

  before { allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("") }

  def kernel_result(output = "done")
    Samagotchi::KernelLoop::Result.new(output: output, conversation: [{ role: "model", content: output }], exhausted: false,
                                       pending_tool_calls: false, tool_activity: [], canceled: false)
  end

  # The loop's two drain sites, as the kernel calls them.
  def drain_mid(drain) = drain.call(at_answer: false)
  def drain_at_answer(drain) = drain.call(at_answer: true)

  it "is false with no turn running and queues nothing for the next one" do
    expect(engine.steer("hello", source: "check-in")).to be(false)
    drained = nil
    allow(kernel).to receive(:run) do |_messages, pending_input:, **|
      drained = drain_mid(pending_input)
      kernel_result
    end

    engine.run_turn(session, "hi")

    expect(drained).to eq([])
  end

  it "queues during a turn and comes out of the drain as a steer item, after the caller's lines" do
    drained = nil
    queued = nil
    allow(kernel).to receive(:run) do |_messages, pending_input:, **|
      queued = engine.steer("  how's it going?  ", source: "check-in")
      drained = drain_mid(pending_input)
      kernel_result
    end

    engine.run_turn(session, "hi", pending_input: -> { ["user line"] })

    expect(queued).to be(true)
    expect(drained).to eq(["user line", { text: "how's it going?", source: "check-in" }])
  end

  it "passes a drain even when the caller has none (--non-interactive), so steers still merge" do
    drained = nil
    allow(kernel).to receive(:run) do |_messages, pending_input:, **|
      engine.steer("nudge", source: "check-in")
      drained = drain_mid(pending_input)
      kernel_result
    end

    engine.run_turn(session, "hi", pending_input: nil)

    expect(drained).to eq([{ text: "nudge", source: "check-in" }])
  end

  it "drops steers at the after-answer site (logged) but keeps the user's lines" do
    drained = nil
    allow(kernel).to receive(:run) do |_messages, pending_input:, **|
      engine.steer("nudge", source: "check-in")
      drained = drain_at_answer(pending_input)
      kernel_result
    end
    allow(Samagotchi::Log).to receive(:info).and_call_original

    engine.run_turn(session, "hi", pending_input: -> { ["user line"] })

    expect(drained).to eq(["user line"])
    expect(Samagotchi::Log).to have_received(:info).with(:turn, "steer_dropped", source: "check-in", why: "answered", chars: 5)
  end

  it "drops what is left when the turn ends, so the next turn starts clean" do
    allow(kernel).to receive(:run) do |_messages, **|
      engine.steer("too late", source: "check-in")
      kernel_result
    end
    allow(Samagotchi::Log).to receive(:info).and_call_original
    engine.run_turn(session, "hi")
    expect(Samagotchi::Log).to have_received(:info).with(:turn, "steer_dropped", source: "check-in", why: "turn_ended", chars: 8)

    drained = nil
    allow(kernel).to receive(:run) do |_messages, pending_input:, **|
      drained = drain_mid(pending_input)
      kernel_result
    end
    engine.run_turn(session, "again")

    expect(drained).to eq([])
    expect(engine.steer("after", source: "check-in")).to be(false)
  end

  it "clears the queue after a failed turn too" do
    allow(kernel).to receive(:run) do |_messages, **|
      engine.steer("lost", source: "check-in")
      raise "boom"
    end
    expect { engine.run_turn(session, "hi") }.to raise_error(RuntimeError, "boom")

    drained = nil
    allow(kernel).to receive(:run) do |_messages, pending_input:, **|
      drained = drain_mid(pending_input)
      kernel_result
    end
    engine.run_turn(session, "again")

    expect(drained).to eq([])
  end

  it "a caller drain that raises still fails the drain (the loop rescues it), leaving the steer queued" do
    drained = []
    allow(kernel).to receive(:run) do |_messages, pending_input:, **|
      engine.steer("nudge", source: "check-in")
      drained << Samagotchi::Steer.drain(pending_input, at_answer: false)
      drained << Samagotchi::Steer.drain(pending_input, at_answer: false)
      kernel_result
    end
    calls = 0
    flaky = lambda do
      calls += 1
      raise "boom" if calls == 1

      []
    end

    engine.run_turn(session, "hi", pending_input: flaky)

    expect(drained).to eq([nil, [{ text: "nudge", source: "check-in" }]])
  end

  it "ignores blank text" do
    result = nil
    allow(kernel).to receive(:run) do |_messages, **|
      result = engine.steer("  ", source: "check-in")
      kernel_result
    end

    engine.run_turn(session, "hi")

    expect(result).to be(false)
  end
end
