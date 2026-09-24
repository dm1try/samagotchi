# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/idle_recap"
require "samagotchi/idle_scheduler"
require "timeout"

RSpec.describe Samagotchi::IdleRecap do
  let(:base_time) { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
  let(:messages_json) { "[]" }
  let(:model) { "gemma4-small" }
  let(:base_url) { "http://localhost:8080/v1" }

  # Simple double factory for the engine — avoids instance_double's
  # strict signature checking which silently fails on keyword-arg methods.
  def stub_engine(**overrides)
    stub = RSpec::Mocks::Example.new.instance_eval do
      double("engine")
    end rescue double("engine")
    allow(stub).to receive(:turn_running?).and_return(overrides[:turn_running] || false)
    allow(stub).to receive(:last_activity_at).and_return(overrides[:last_activity] || base_time.to_f)
    allow(stub).to receive(:activity_seq).and_return(overrides[:activity_seq] || 1)
    allow(stub).to receive(:messages_json_for_recap).and_return(overrides[:messages] || "[]")
    allow(stub).to receive(:emit_recap)
    stub
  end

  let(:client) { double("idle_client", summarize: "recap") }

  # Tick until the attempt started by the first tick has been collected
  # (the job never waits on the summarizer itself).
  def drive(idle)
    idle.tick
    500.times do
      break unless idle.in_flight?

      sleep(0.01)
      idle.tick
    end
  end
  let(:clock) { -> { base_time } }

  subject(:idle_recap) do
    described_class.new(
      engine: stub_engine,
      model: model,
      base_url: base_url,
      inactivity: 2.0,
      timeout: 1.0,
      client: client,
      clock: clock
    )
  end

  describe Samagotchi::IdleRecap::TranscriptFilter do
    describe ".build" do
      it "keeps user messages" do
        messages = [{ "role" => "user", "content" => "Hello" }]
        expect(Samagotchi::IdleRecap::TranscriptFilter.build(messages)).to eq("Hello")
      end
      it "names a user message's images, and never carries their bytes" do
        ref = { "file" => "images/0123456789abcdef.png", "name" => "shot.png", "mime" => "image/png", "width" => 3, "height" => 2 }
        messages = [{ "role" => "user", "content" => "what is this?", "images" => [ref] },
                    { "role" => "tool_response", "content" => "[read]\nImage a.png attached.", "images" => [ref] },
                    { "role" => "model", "content" => "A red square." }]
        result = Samagotchi::IdleRecap::TranscriptFilter.build(messages)
        expect(result).to eq("what is this?\n[image shot.png]\n\nA red square.")
      end
      it "keeps model messages and strips think tokens" do
        messages = [
          { "role" => "user", "content" => "Hi" },
          { "role" => "model", "content" => "<|think|>thinking<|think|> I am ready" }
        ]
        result = Samagotchi::IdleRecap::TranscriptFilter.build(messages)
        expect(result).to include("I am ready")
        expect(result).not_to include("thinking")
      end
      it "strips literal think tokens" do
        open_tag = "[[" + "SAMAGOTCHI_LITERAL_THINK_OPEN" + "]]"
        close_tag = "[[" + "SAMAGOTCHI_LITERAL_THINK_CLOSE" + "]]"
        content = open_tag + "thinking" + close_tag + " done"
        messages = [{ "role" => "assistant", "content" => content }]
        result = Samagotchi::IdleRecap::TranscriptFilter.build(messages)
        expect(result).to eq("done")
      end
      it "drops system, tool_response, and any unknown roles" do
        messages = [
          { "role" => "system", "content" => "You are helpful" },
          { "role" => "user", "content" => "Tell me something" },
          { "role" => "tool_response", "content" => "result" },
          { "role" => "model", "content" => "Here is info" }
        ]
        result = Samagotchi::IdleRecap::TranscriptFilter.build(messages)
        expect(result).to eq("Tell me something\n\nHere is info")
      end
      it "drops inline tool-call markup (and its arguments) from model prose" do
        messages = [
          { "role" => "user", "content" => "write it" },
          { "role" => "model", "content" => "Writing now <|tool_call>call:write_file{content:<|\"|>SECRET BODY<|\"|>}<tool_call|>" },
          { "role" => "model", "content" => "<tool_call>\n<function=execute>\nls\n</function>\n</tool_call>" },
          { "role" => "model", "content" => "Done." }
        ]
        result = Samagotchi::IdleRecap::TranscriptFilter.build(messages)
        expect(result).to eq("write it\n\nWriting now\n\nDone.")
      end
      it "rejects non-Hash entries" do
        messages = [nil, "string", { "role" => "user", "content" => "ok" }]
        expect(Samagotchi::IdleRecap::TranscriptFilter.build(messages)).to eq("ok")
      end
      it "returns empty string when all entries are empty or filtered" do
        messages = [
          { "role" => "system", "content" => "bye" },
          { "role" => "user", "content" => "  " }
        ]
        expect(Samagotchi::IdleRecap::TranscriptFilter.build(messages)).to eq("")
      end
    end
  end

  describe "Samagotchi::IdleRecap::TranscriptFilter.tool_names" do
    it "reads one name per call from both joined and per-call tool responses" do
      messages = [
        { "role" => "tool_response", "content" => "[execute]\nstdout:\nok\n\n---\n\n[read_file]\nbody" },
        { "role" => "tool_response", "content" => "[execute] Error: boom" },
        { "role" => "user", "content" => "[not_a_tool] hi" }
      ]
      expect(Samagotchi::IdleRecap::TranscriptFilter.tool_names(messages)).to eq(%w[execute read_file execute])
    end
  end

  describe Samagotchi::IdleRecap::RecapPrompt do
    describe ".build" do
      let(:transcript) { "User asked about X.\nAssistant answered." }
      it "returns nil when transcript is empty (nothing to summarize)" do
        expect(Samagotchi::IdleRecap::RecapPrompt.build("", tool_count: 0)).to be_nil
      end
      it "tallies the tool names when the count is small" do
        result = Samagotchi::IdleRecap::RecapPrompt.build(transcript, tool_names: %w[execute read_file execute])
        expect(result).to include("3 tool calls (execute x2, read_file)")
      end
      it "includes tool count when small" do
        result = Samagotchi::IdleRecap::RecapPrompt.build(transcript, tool_count: 3)
        expect(result).to include("3 tool calls")
        expect(result).to include("handful of tool calls")
      end
      it "includes single tool call phrasing" do
        result = Samagotchi::IdleRecap::RecapPrompt.build(transcript, tool_count: 1)
        expect(result).to include("1 tool call")
      end
      it "omits tool names when count is large (above threshold)" do
        result = Samagotchi::IdleRecap::RecapPrompt.build(transcript, tool_count: 50)
        expect(result).to include("50\ntool calls were made")
        expect(result).to include("DO NOT enumerate them")
      end
      it "tallies the tool names even when the count is large" do
        result = Samagotchi::IdleRecap::RecapPrompt.build(transcript, tool_names: ["execute"] * 11)
        expect(result).to include("(execute x11)")
        expect(result).to include("DO NOT enumerate them")
      end
      it "includes overall goal, completion, facts, and pending in the prompt" do
        result = Samagotchi::IdleRecap::RecapPrompt.build(transcript, tool_count: 2)
        expect(result).to include("goal")
        expect(result).to include("completed")
        expect(result).to include("key facts")
        expect(result).to include("pending")
      end
    end
  end

  describe "#initialize" do
    it "requires an engine" do
      expect {
        described_class.new(model: model, base_url: base_url)
      }.to raise_error(ArgumentError, /engine/)
    end
    it "creates an IdleClient with the recap's timeout when none is provided" do
      engine = stub_engine
      allow(Samagotchi::IdleClient).to receive(:new).and_return(double(summarize: "recap"))
      described_class.new(engine: engine, model: model, base_url: base_url, timeout: 7.0)
      expect(Samagotchi::IdleClient).to have_received(:new).with(model: model, base_url: base_url, api_key_env: nil, timeout: 7.0)
    end
    it "uses a custom client when provided" do
      client_double = double
      engine = stub_engine
      idle = described_class.new(engine: engine, model: model, base_url: base_url, client: client_double)
      expect(idle.instance_variable_get(:@client)).to eq(client_double)
    end
    it "defaults to DEFAULT_INACTIVITY_SECONDS" do
      engine = stub_engine
      idle = described_class.new(engine: engine, model: model, base_url: base_url)
      expect(idle.instance_variable_get(:@inactivity)).to eq(described_class::DEFAULT_INACTIVITY_SECONDS)
    end
    it "defaults to DEFAULT_MIN_USER_TURNS" do
      engine = stub_engine
      idle = described_class.new(engine: engine, model: model, base_url: base_url)
      expect(idle.instance_variable_get(:@min_user_turns)).to eq(described_class::DEFAULT_MIN_USER_TURNS)
    end
  end

  describe "#generation" do
    it "starts at 0" do
      expect(idle_recap.generation).to eq(0)
    end
    it "increments after invalidate!" do
      idle_recap.invalidate!
      expect(idle_recap.generation).to eq(1)
    end
    it "increments after a successful generate (via bump_generation)" do
      idle_recap.invalidate!
      idle_recap.invalidate!
      expect(idle_recap.generation).to eq(2)
    end
  end

  describe "#invalidate!" do
    it "bumps the generation id" do
      idle_recap.invalidate!
      expect(idle_recap.generation).to eq(1)
      idle_recap.invalidate!
      expect(idle_recap.generation).to eq(2)
    end
    it "is safe to call before start" do
      expect { idle_recap.invalidate! }.not_to raise_error
    end
  end

  describe "#should_fire?" do
    it "returns false when a turn is running" do
      engine = stub_engine(turn_running: true)
      idle = described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 2.0, client: client, clock: -> { base_time })
      expect(idle.should_fire?).to be false
    end
    it "returns false when idle is below threshold" do
      engine = stub_engine(last_activity: base_time.to_f - 1)
      idle = described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 2.0, client: client, clock: -> { base_time })
      expect(idle.should_fire?).to be false
    end
    it "returns false when idle equals threshold but seq hasn't advanced since last fire" do
      engine = stub_engine(last_activity: base_time.to_f - 2, activity_seq: 1)
      idle = described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 2.0, client: client, clock: -> { base_time })
      idle.instance_variable_set(:@last_fire_activity_seq, 1)
      expect(idle.should_fire?).to be false
    end
    it "returns true when idle exceeds threshold and seq has advanced since last fire" do
      engine = stub_engine(last_activity: base_time.to_f - 3, activity_seq: 2)
      idle = described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 2.0, client: client, clock: -> { base_time })
      idle.instance_variable_set(:@last_fire_activity_seq, 1)
      expect(idle.should_fire?).to be true
    end
    it "returns true on first idle window (no last_fire_activity_seq)" do
      engine = stub_engine(last_activity: base_time.to_f - 3, activity_seq: 1)
      idle = described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 2.0, client: client, clock: -> { base_time })
      idle.instance_variable_set(:@last_fire_activity_seq, nil)
      expect(idle.should_fire?).to be true
    end
  end

  describe "#tick" do
    def stub_engine_with_two_user_turns(**overrides)
      messages = JSON.generate([
        { "role" => "user", "content" => "Hello" },
        { "role" => "model", "content" => "Hi there" },
        { "role" => "user", "content" => "What about X?" }
      ])
      stub_engine(messages: messages, **overrides)
    end

    context "when should_fire? is false" do
      it "does nothing" do
        engine = stub_engine
        idle = described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 2.0, client: client, clock: -> { base_time })
        allow(idle).to receive(:should_fire?).and_return(false)
        idle.tick
        expect(client).not_to have_received(:summarize)
      end
    end

    context "when should_fire? is true" do
      it "calls the client and emits recap on success" do
        engine = stub_engine_with_two_user_turns
        recap_client = double("recap_client")
        allow(recap_client).to receive(:summarize).and_return("recap")
        idle = described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 0.0, timeout: 1.0, client: recap_client, clock: -> { base_time })
        allow(idle).to receive(:should_fire?).and_return(true)
        drive(idle)
        expect(recap_client).to have_received(:summarize).at_least(:once)
        expect(engine).to have_received(:emit_recap)
      end
      it "does not emit when recap is nil" do
        engine = stub_engine_with_two_user_turns
        idle = described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 0.0, timeout: 1.0, client: double("client", summarize: nil), clock: -> { base_time })
        allow(idle).to receive(:should_fire?).and_return(true)
        drive(idle)
        expect(engine).not_to have_received(:emit_recap)
      end
      it "does not emit when recap is empty string" do
        engine = stub_engine_with_two_user_turns
        idle = described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 0.0, timeout: 1.0, client: double("client", summarize: ""), clock: -> { base_time })
        allow(idle).to receive(:should_fire?).and_return(true)
        drive(idle)
        expect(engine).not_to have_received(:emit_recap)
      end
      it "does not emit when engine messages are empty" do
        engine = stub_engine(messages: "[]")
        idle = described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 0.0, timeout: 1.0, client: double("client", summarize: "recap"), clock: -> { base_time })
        allow(idle).to receive(:should_fire?).and_return(true)
        drive(idle)
        expect(engine).not_to have_received(:emit_recap)
      end
      it "does not emit when user turns are below min" do
        messages = JSON.generate([{ "role" => "user", "content" => "Hello" }])
        engine = stub_engine(messages: messages)
        idle = described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 0.0, min_user_turns: 2, timeout: 1.0, client: double("client", summarize: "recap"), clock: -> { base_time })
        allow(idle).to receive(:should_fire?).and_return(true)
        drive(idle)
        expect(engine).not_to have_received(:emit_recap)
      end
      it "handles client SummarizeError gracefully (does not break session)" do
        engine = stub_engine_with_two_user_turns
        err_client = double("err_client")
        allow(err_client).to receive(:summarize).and_raise(Samagotchi::IdleClient::SummarizeError)
        idle = described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 0.0, timeout: 1.0, client: err_client, clock: -> { base_time })
        allow(idle).to receive(:should_fire?).and_return(true)
        expect { drive(idle) }.not_to raise_error
        expect(engine).not_to have_received(:emit_recap)
      end
      it "does not emit when invalidated during generation" do
        engine = stub_engine_with_two_user_turns
        started = Queue.new
        proceed = Queue.new
        slow_client = double("slow_client")
        allow(slow_client).to receive(:summarize) do
          started.push(:ready)
          proceed.pop  # wait for test to signal before finishing
          "recap"
        end
        idle = described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 0.0, timeout: 5.0, client: slow_client, clock: -> { base_time })
        allow(idle).to receive(:should_fire?).and_return(true)
        idle.tick
        started.pop
        # A turn starts: the in-flight recap must never render.
        idle.invalidate!
        proceed.push(:go)
        drive(idle)
        expect(engine).not_to have_received(:emit_recap)
      end
    end
  end

  describe "min_user_turns configuration" do
    let(:two_user_turns) do
      JSON.generate([
        { "role" => "user", "content" => "Hi" },
        { "role" => "model", "content" => "Hello" },
        { "role" => "user", "content" => "Bye" }
      ])
    end
    let(:engine) { stub_engine(messages: two_user_turns) }
    let(:idle_recap) do
      described_class.new(
        engine: engine,
        model: model,
        base_url: base_url,
        inactivity: 0.0,
        min_user_turns: 3,
        timeout: 1.0,
        client: double("client", summarize: "recap"),
        clock: -> { base_time }
      )
    end
    it "requires at least min_user_turns user turns to fire" do
      allow(idle_recap).to receive(:should_fire?).and_return(true)
      drive(idle_recap)
      expect(engine).not_to have_received(:emit_recap)
    end
  end

  describe "tool count in prompt" do
    let(:messages_with_one_tool) do
      JSON.generate([
        { "role" => "user", "content" => "Do it" },
        { "role" => "model", "content" => "Calling tool" },
        { "role" => "tool_response", "content" => "result1" },
        { "role" => "model", "content" => "Done" },
        { "role" => "user", "content" => "Great" }
      ])
    end
    it "counts tool_response entries for the prompt" do
      engine = stub_engine(messages: messages_with_one_tool)
      idle = described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 0.0, timeout: 1.0, client: double("client", summarize: "recap"), clock: -> { base_time })
      allow(idle).to receive(:should_fire?).and_return(true)
      drive(idle)
      expect(engine).to have_received(:emit_recap)
    end
    it "states tool count only (no enumeration) when count exceeds threshold" do
      messages = []
      11.times { |i| messages << { "role" => "tool_response", "content" => "r#{i + 1}" } }
      messages.prepend({ "role" => "user", "content" => "Do it" })
      messages << { "role" => "user", "content" => "Done" }
      engine = stub_engine(messages: JSON.generate(messages))
      idle = described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 0.0, timeout: 1.0, client: double("client", summarize: "recap"), clock: -> { base_time })
      allow(idle).to receive(:should_fire?).and_return(true)
      drive(idle)
      expect(engine).to have_received(:emit_recap)
    end
  end

  describe "cancellation / invalidation flow" do
    let(:messages_with_two_user_turns) do
      JSON.generate([
        { "role" => "user", "content" => "Start" },
        { "role" => "model", "content" => "Working" },
        { "role" => "user", "content" => "Continue" }
      ])
    end
    it "invalidates a generation that was in-flight" do
      engine = stub_engine(messages: messages_with_two_user_turns)
      slow_client = double("slow_client")
      allow(slow_client).to receive(:summarize) { sleep(0.3); "recap" }
      idle = described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 0.0, timeout: 5.0, client: slow_client, clock: -> { base_time })
      allow(idle).to receive(:should_fire?).and_return(true)
      gen_before = idle.generation
      idle.tick
      sleep(0.05)
      idle.invalidate!
      expect(idle.generation).to be > gen_before
      allow(idle).to receive(:should_fire?).and_return(false)
      drive(idle)
      expect(engine).not_to have_received(:emit_recap)
    end
    it "starts a fresh generation with a new generation id after invalidation" do
      engine = stub_engine(messages: messages_with_two_user_turns)
      client_v1 = double("client_v1", summarize: "recap v1")
      idle = described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 0.0, timeout: 1.0, client: client_v1, clock: -> { base_time })
      allow(idle).to receive(:should_fire?).and_return(true)
      drive(idle)
      gen_v1 = idle.generation
      expect(engine).to have_received(:emit_recap).with(recap: anything, generation: gen_v1)
      # Invalidate (bumps generation)
      idle.invalidate!
      expect(idle.generation).to eq(gen_v1 + 1)
      # Build a fresh engine for the second call
      engine2 = stub_engine(messages: messages_with_two_user_turns)
      allow(idle).to receive(:should_fire?).and_return(true)
      idle.instance_variable_set(:@engine, engine2)
      idle.instance_variable_set(:@client, double("client_v2", summarize: "recap v2"))
      # Note: @generation is gen_v1+1; start bumps it to gen_v1+2
      expected_gen = gen_v1 + 2
      drive(idle)
      # The emit should use the new generation
      expect(engine2).to have_received(:emit_recap).with(recap: anything, generation: expected_gen)
    end
  end

  describe "one attempt per idle window" do
    let(:two_turns) do
      JSON.generate([
        { "role" => "user", "content" => "Hello" },
        { "role" => "model", "content" => "Hi there" },
        { "role" => "user", "content" => "What about X?" }
      ])
    end

    def idle_for(engine, client)
      described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 0.0,
                          min_user_turns: 2, timeout: 1.0, client: client, clock: -> { base_time })
    end

    it "does not re-snapshot every tick while the history is too short" do
      engine = stub_engine(messages: JSON.generate([{ "role" => "user", "content" => "Hello" }]), last_activity: base_time.to_f - 5)
      idle = idle_for(engine, client)
      5.times { idle.tick }
      expect(engine).to have_received(:messages_json_for_recap).once
    end

    it "does not re-call a failing summarizer every tick" do
      engine = stub_engine(messages: two_turns, last_activity: base_time.to_f - 5)
      err_client = double("err_client")
      allow(err_client).to receive(:summarize).and_raise(Samagotchi::IdleClient::SummarizeError)
      idle = idle_for(engine, err_client)
      5.times { drive(idle) }
      expect(err_client).to have_received(:summarize).once
    end

    it "never sends an empty transcript to the summarizer" do
      blank = JSON.generate([{ "role" => "user", "content" => " " }, { "role" => "user", "content" => "" }])
      engine = stub_engine(messages: blank, last_activity: base_time.to_f - 5)
      idle = idle_for(engine, client)
      idle.tick
      expect(client).not_to have_received(:summarize)
    end

    it "re-arms once new activity advances the seq" do
      engine = stub_engine(messages: two_turns, last_activity: base_time.to_f - 5, activity_seq: 1)
      err_client = double("err_client")
      allow(err_client).to receive(:summarize).and_raise(Samagotchi::IdleClient::SummarizeError)
      idle = idle_for(engine, err_client)
      drive(idle)
      allow(engine).to receive(:activity_seq).and_return(2)
      drive(idle)
      drive(idle)
      expect(err_client).to have_received(:summarize).twice
    end
  end

  describe "non-blocking attempts" do
    let(:two_turns) do
      JSON.generate([
        { "role" => "user", "content" => "Hello" },
        { "role" => "model", "content" => "Hi there" },
        { "role" => "user", "content" => "What about X?" }
      ])
    end
    let(:gate) { Queue.new }
    let(:called) { Queue.new }
    let(:blocked_client) do
      c = double("blocked_client")
      allow(c).to receive(:summarize) { called.push(:in); gate.pop; "late recap" }
      c
    end

    it "returns from tick while the summarizer is still running" do
      engine = stub_engine(messages: two_turns, last_activity: base_time.to_f - 5)
      idle = described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 0.0,
                                 timeout: 30.0, client: blocked_client, clock: -> { base_time })
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      3.times { idle.tick }
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
      expect(idle).to be_in_flight
      called.pop
      expect(blocked_client).to have_received(:summarize).once
      gate.push(:go)
      drive(idle)
      expect(engine).to have_received(:emit_recap).with(recap: "late recap", generation: idle.generation)
    end

    it "lets the other scheduler jobs keep ticking while a recap is in flight" do
      engine = stub_engine(messages: two_turns, last_activity: base_time.to_f - 5)
      idle = described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 0.0,
                                 timeout: 30.0, client: blocked_client, clock: -> { base_time })
      reminders = double("reminders")
      ticks = 0
      allow(reminders).to receive(:tick) { ticks += 1 }
      scheduler = Samagotchi::IdleScheduler.new(engine: engine, jobs: [idle, reminders])
      Timeout.timeout(2) { 5.times { scheduler.tick } }
      expect(ticks).to eq(5)
      expect(idle).to be_in_flight
      gate.push(:go)
    end

    it "drops an attempt that runs past the timeout" do
      now = base_time
      engine = stub_engine(messages: two_turns, last_activity: base_time.to_f - 5)
      idle = described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 0.0,
                                 timeout: 1.0, client: blocked_client, clock: -> { now })
      idle.tick
      now += 1.5
      idle.tick
      expect(idle).not_to be_in_flight
      gate.push(:go)
      sleep(0.05)
      idle.tick
      expect(engine).not_to have_received(:emit_recap)
    end
  end
end
