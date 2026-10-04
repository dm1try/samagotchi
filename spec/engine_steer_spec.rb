# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "support/test_kernel"

# Engine#steer: a plugin's text into the running turn, drained with the
# caller's steering at the loop's boundaries (Steer).
RSpec.describe Samagotchi::Engine, "#steer" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:engine) { described_class.new(client: client, kernel: kernel, profile: "gemma4") }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }

  before { allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("") }

  def kernel_result(output = "done")
    Samagotchi::LLM::ModelResult.new(text: output, conversation: [{ role: "model", content: output }], exhausted: false,
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

  describe "#steer_next_turn" do
    it "queues for the turn that begins next, which drains it at its first boundary (once)" do
      drains = []
      allow(kernel).to receive(:run) do |_messages, pending_input:, **|
        drains << drain_mid(pending_input) << drain_mid(pending_input)
        kernel_result
      end

      expect(engine.steer_next_turn("  also X ", source: "parent_agent")).to be(true)
      expect(engine.steer_next_turn("  ", source: "parent_agent")).to be(false)
      engine.run_turn(session, nil, continue: true)

      expect(drains).to eq([[{ text: "also X", source: "parent_agent" }], []])
    end

    it "reaches the model: the next request carries the steer as a steer message" do
      conversation = nil
      allow(kernel).to receive(:run) do |messages, pending_input:, **|
        merge = Samagotchi::Steer.merge(drain_mid(pending_input))
        conversation = messages + merge.messages
        kernel_result
      end

      engine.steer_next_turn("also X", source: "user")
      engine.run_turn(session, nil, continue: true)

      expect(conversation.last).to include(role: "user", kind: "steer", source: "user", content: "also X")
    end
  end

  describe "#cut_for_steer" do
    let(:now) { [1000.0] }

    before { allow(engine).to receive(:monotonic_now) { now.first } }

    # Runs a turn whose one generation thinks for +thinking_for+ seconds
    # (+lanes+: what else it streamed), then asks for a cut from +source+.
    # Returns [the answer, whether the generation's controller was cut].
    def cut_during(source, thinking_for: 25, lanes: {}, between: false)
      answer = nil
      cut_detail = nil
      allow(kernel).to receive(:run) do |_messages, on_stream_event:, cancel_controller:, **|
        if between
          answer = engine.cut_for_steer(source)
        else
          cancel_controller.generation do |child|
            on_stream_event.call({ type: :generation_started, iteration: 1 })
            on_stream_event.call({ type: :generation_chunk, iteration: 1, content: "hm", text: "", thinking: "hm" })
            now[0] += thinking_for
            on_stream_event.call({ type: :generation_chunk, iteration: 1, content: "x", text: "", thinking: "x" }.merge(lanes))
            answer = engine.cut_for_steer(source)
            cut_detail = child.detail if child.cancelled?
          end
        end
        kernel_result
      end
      engine.run_turn(session, "hi")
      [answer, cut_detail]
    end

    it "cuts a generation thinking only for steer.cut_after seconds, for the user, chi send and a parent agent" do
      [nil, "chi_send", "parent_agent"].each do |source|
        answer, detail = cut_during(source)
        expect(answer).to be(true)
        expect(detail).to eq(by: "steer", steer: true, source: source.to_s, reason: "a new message")
      end
    end

    it "logs the cut with its source" do
      allow(Samagotchi::Log).to receive(:info).and_call_original
      cut_during("chi_send")
      expect(Samagotchi::Log).to have_received(:info).with(:turn, "steer_cut", source: "chi_send", age: 25.0)
    end

    it "does not cut a younger generation" do
      expect(cut_during(nil, thinking_for: 5)).to eq([false, nil])
    end

    it "does not cut after visible text or a tool call" do
      expect(cut_during(nil, lanes: { text: "Answer" })).to eq([false, nil])
      expect(cut_during(nil, lanes: { tool_call: true })).to eq([false, nil])
    end

    it "never cuts for a plugin" do
      expect(cut_during("plugin_send")).to eq([false, nil])
      expect(cut_during("check-in")).to eq([false, nil])
    end

    it "never cuts with steer.cut_after 0" do
      with_env("SAMAGOTCHI_STEER_CUT_AFTER" => "0") do
        expect(cut_during(nil, thinking_for: 600)).to eq([false, nil])
      end
    end

    it "honours steer.cut_after" do
      with_env("SAMAGOTCHI_STEER_CUT_AFTER" => "60") do
        expect(cut_during(nil, thinking_for: 30)).to eq([false, nil])
        expect(cut_during(nil, thinking_for: 61).first).to be(true)
      end
    end

    it "is false with no turn running, and between generations" do
      expect(engine.cut_for_steer(nil)).to be(false)
      expect(cut_during(nil, between: true)).to eq([false, nil])
    end
  end
end
