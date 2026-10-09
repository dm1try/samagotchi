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
        expect(answer).to eq(:now)
        expect(detail).to eq(by: "steer", steer: true, source: source.to_s, reason: "a new message")
      end
    end

    it "logs the cut with its source" do
      allow(Samagotchi::Log).to receive(:info).and_call_original
      cut_during("chi_send")
      expect(Samagotchi::Log).to have_received(:info).with(:turn, "steer_cut", source: "chi_send", age: 25.0)
    end

    it "does not cut a younger generation: the message waits for the thinking to pass cut_after" do
      expect(cut_during(nil, thinking_for: 5)).to eq([:waits, nil])
    end

    it "does not cut after visible text or a tool call" do
      expect(cut_during(nil, lanes: { text: "Answer" })).to eq([:waits, nil])
      expect(cut_during(nil, lanes: { tool_call: true })).to eq([:waits, nil])
    end

    it "never cuts for a plugin" do
      expect(cut_during("plugin_send")).to eq([:off, nil])
      expect(cut_during("check-in")).to eq([:off, nil])
    end

    it "never cuts with steer.cut_after 0" do
      with_env("SAMAGOTCHI_STEER_CUT_AFTER" => "0") do
        expect(cut_during(nil, thinking_for: 600)).to eq([:off, nil])
      end
    end

    it "honours steer.cut_after" do
      with_env("SAMAGOTCHI_STEER_CUT_AFTER" => "60") do
        expect(cut_during(nil, thinking_for: 30)).to eq([:waits, nil])
        expect(cut_during(nil, thinking_for: 61).first).to eq(:now)
      end
    end

    it "is off with no turn running, and waits between generations (it cuts in the next one)" do
      expect(engine.cut_for_steer(nil)).to eq(:off)
      expect(cut_during(nil, between: true)).to eq([:waits, nil])
    end
  end

  # A cut-eligible message that came before the generation had thought for
  # steer.cut_after waits (WaitingSteer) and cuts once the thinking passes it.
  describe "a message that came too early to cut" do
    let(:now) { [1000.0] }
    let(:steer_cut) { ->(source) { { by: "steer", steer: true, source: source, reason: "a new message" } } }

    before { allow(engine).to receive(:monotonic_now) { now.first } }

    # Plays +steps+ inside one turn; returns {answers:, cuts:} (each
    # generation's cut detail, nil when it wasn't cut).
    #   [:gen] a generation starts (the previous one ends)
    #   [:think, seconds] time passes, then a thinking chunk
    #   [:chunk, lanes] a chunk with +lanes+ (text:, tool_call:)
    #   [:steer, source] Engine#cut_for_steer(source), its epoch read first
    #   [:steer_stale, source] the same, with a drain between the epoch and it
    #   [:drain] the loop drains input at a boundary
    def play(*steps, pending: -> { ["a line"] })
      answers = []
      cuts = []
      allow(kernel).to receive(:run) do |_messages, on_stream_event:, cancel_controller:, pending_input:, **|
        steps.slice_before([:gen]).each do |generation|
          cancel_controller.generation do |child|
            generation.each do |kind, arg|
              case kind
              when :gen then on_stream_event.call({ type: :generation_started, iteration: cuts.size + 1 })
              when :think
                now[0] += arg
                on_stream_event.call({ type: :generation_chunk, iteration: 1, content: "x", text: "", thinking: "x" })
              when :chunk then on_stream_event.call({ type: :generation_chunk, iteration: 1, content: "", thinking: "" }.merge(arg))
              when :steer then answers << engine.cut_for_steer(arg, epoch: engine.input_epoch)
              when :steer_stale
                epoch = engine.input_epoch
                pending_input.call(at_answer: false)
                answers << engine.cut_for_steer(arg, epoch: epoch)
              when :drain then pending_input.call(at_answer: false)
              end
            end
            cuts << (child.cancelled? ? child.detail : nil)
            on_stream_event.call({ type: :generation_completed, iteration: cuts.size })
          end
        end
        kernel_result
      end
      engine.run_turn(session, "hi", pending_input: pending)
      { answers: answers, cuts: cuts }
    end

    it "cuts once the thinking passes steer.cut_after, with the message's source, and only once" do
      result = play([:gen], [:think, 0], [:think, 5], [:steer, "chi_send"], [:think, 5], [:think, 9], [:think, 2], [:think, 2])
      expect(result).to eq(answers: [:waits], cuts: [steer_cut.call("chi_send")])
    end

    it "logs the deferred cut as one that waited" do
      allow(Samagotchi::Log).to receive(:info).and_call_original
      play([:gen], [:think, 0], [:think, 5], [:steer, nil], [:think, 16])
      expect(Samagotchi::Log).to have_received(:info).with(:turn, "steer_cut", source: "", age: 21.0, waited: true)
    end

    it "waits across a generation that ends with text into the next one, and cuts there" do
      result = play([:gen], [:think, 0], [:steer, nil], [:chunk, { text: "Answer" }], [:think, 30],
                    [:gen], [:think, 0], [:think, 21])
      expect(result[:cuts]).to eq([nil, steer_cut.call("")])
    end

    it "doesn't cut once a drain took the message to the model" do
      result = play([:gen], [:think, 0], [:steer, nil], [:drain], [:gen], [:think, 0], [:think, 30])
      expect(result[:cuts]).to eq([nil, nil])
    end

    it "keeps waiting when a drain finds nothing (the message isn't in yet)" do
      result = play([:gen], [:think, 0], [:steer, nil], [:drain], [:think, 25], pending: -> { [] })
      expect(result[:cuts]).to eq([steer_cut.call("")])
    end

    it "doesn't wait when a drain took input after the message was queued (it may be delivered)" do
      result = play([:gen], [:think, 0], [:steer_stale, nil], [:think, 30])
      expect(result[:cuts]).to eq([nil])
    end

    it "never waits for a plugin's message, nor with steer.cut_after 0" do
      expect(play([:gen], [:think, 0], [:steer, "plugin_send"], [:think, 30])[:cuts]).to eq([nil])
      with_env("SAMAGOTCHI_STEER_CUT_AFTER" => "0") do
        expect(play([:gen], [:think, 0], [:steer, nil], [:think, 30])[:cuts]).to eq([nil])
      end
    end

    it "doesn't cut a generation that streams a tool call or text, however long it thought" do
      expect(play([:gen], [:think, 0], [:steer, nil], [:chunk, { tool_call: true }], [:think, 30])[:cuts]).to eq([nil])
    end

    it "stops waiting when the turn ends" do
      play([:gen], [:think, 0], [:steer, nil])
      expect(play([:gen], [:think, 0], [:think, 30], pending: -> { [] })[:cuts]).to eq([nil])
    end
  end
end
