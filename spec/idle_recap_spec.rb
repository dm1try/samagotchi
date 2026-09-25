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
    describe ".sentences_range" do
      def range(value) = Samagotchi::IdleRecap::RecapPrompt.sentences_range(value)

      it "defaults to 2-4 when unset" do
        expect(range(nil)).to eq([2, 4])
        expect(range("  ")).to eq([2, 4])
      end
      it "takes a range, a single number or a YAML integer" do
        expect(range("2-3")).to eq([2, 3])
        expect(range("3")).to eq([3, 3])
        expect(range(3)).to eq([3, 3])
      end
      it "allows spaces and an en dash" do
        expect(range(" 5 - 7 ")).to eq([5, 7])
        expect(range("5–7")).to eq([5, 7])
      end
      it "rejects values outside 1-10, a reversed range and non-numbers" do
        %w[0 12 7-3 0-2 3-11 lots 2-3-4 -2].each { |bad| expect(range(bad)).to be_nil, bad }
      end
    end

    describe ".build" do
      let(:transcript) { "User asked about X.\nAssistant answered." }
      def text(messages) = messages.map { |m| m[:content] }.join("\n")

      it "returns nil when transcript is empty (nothing to summarize)" do
        expect(Samagotchi::IdleRecap::RecapPrompt.build("", tool_count: 0)).to be_nil
      end
      it "puts the instructions in a system message and the transcript in the user message" do
        system, user = Samagotchi::IdleRecap::RecapPrompt.build(transcript)
        expect(system[:role]).to eq("system")
        expect(system[:content]).to include("recap only", "no preamble")
        expect(user[:role]).to eq("user")
        expect(user[:content]).to include(transcript)
      end
      it "tallies the tool names when the count is small" do
        result = text(Samagotchi::IdleRecap::RecapPrompt.build(transcript, tool_names: %w[execute read_file execute]))
        expect(result).to include("3 tool calls (execute x2, read_file)")
        expect(result).to include("handful of tool calls")
      end
      it "includes single tool call phrasing" do
        result = text(Samagotchi::IdleRecap::RecapPrompt.build(transcript, tool_count: 1))
        expect(result).to include("1 tool call")
      end
      it "asks not to enumerate the calls when the count is large" do
        result = text(Samagotchi::IdleRecap::RecapPrompt.build(transcript, tool_names: ["execute"] * 11))
        expect(result).to include("11 tool calls (execute x11)")
        expect(result).to include("Do not enumerate the tool calls")
      end
      it "includes overall goal, completion, facts, and pending in the prompt" do
        result = text(Samagotchi::IdleRecap::RecapPrompt.build(transcript, tool_count: 2))
        expect(result).to include("goal", "completed", "key facts", "pending")
      end
      it "asks for an updated recap of the whole session when given the previous one" do
        result = text(Samagotchi::IdleRecap::RecapPrompt.build(transcript, previous: "We set up Bluefin."))
        expect(result).to include("Earlier recap:\nWe set up Bluefin.")
        expect(result).to include("updated recap of the whole session", "do not just repeat the earlier recap")
        expect(result).to include("since the earlier recap")
      end
      it "keeps the tail of an overlong transcript, marking the cut" do
        long = ("a" * 100 + "\n\n") * 300
        user = Samagotchi::IdleRecap::RecapPrompt.build(long + "THE END").last[:content]
        expect(user).to include("(earlier part omitted)", "THE END")
        expect(user.size).to be < Samagotchi::IdleRecap::MAX_NEW_CHARS + 1_000
      end
    end
  end

  describe "#initialize" do
    it "requires an engine" do
      expect {
        described_class.new(model: model, base_url: base_url)
      }.to raise_error(ArgumentError, /engine/)
    end
    it "creates an IdleClient for the target with the recap's timeout when none is provided" do
      engine = stub_engine
      allow(Samagotchi::IdleClient).to receive(:new).and_return(double(summarize: "recap"))
      idle = described_class.new(engine: engine, model: model, base_url: base_url, timeout: 7.0)
      idle.send(:client_for, idle.target)
      expect(Samagotchi::IdleClient).to have_received(:new).with(model: model, base_url: base_url, api_key_env: nil, timeout: 7.0)
    end

    it "resolves the target at each attempt and rebuilds the client only when it changes" do
      two_turns = JSON.generate([{ "role" => "user", "content" => "a" }, { "role" => "model", "content" => "b" },
                                 { "role" => "user", "content" => "c" }])
      seq = [1]
      engine = stub_engine(messages: two_turns, last_activity: base_time.to_f - 5)
      allow(engine).to receive(:activity_seq) { seq[0] }
      targets = [{ base_url: "http://a/v1", api_key_env: nil, model: "m1", label: "a:m1" }]
      clients = []
      allow(Samagotchi::IdleClient).to receive(:new) { |**kw| clients << kw; double(summarize: nil) }
      idle = described_class.new(engine: engine, target: -> { targets.last }, inactivity: 0.0, clock: -> { base_time })
      drive(idle)
      seq[0] = 2
      drive(idle)
      targets << { base_url: "http://b/v1", api_key_env: "K", model: "m2", label: "b:m2" }
      seq[0] = 3
      drive(idle)
      expect(clients.map { |kw| kw[:model] }).to eq(%w[m1 m2])
    end

    it "makes no attempt when the target can't be resolved" do
      two_turns = JSON.generate([{ "role" => "user", "content" => "a" }, { "role" => "user", "content" => "c" }])
      engine = stub_engine(messages: two_turns, last_activity: base_time.to_f - 5)
      idle = described_class.new(engine: engine, target: -> { raise "no host" }, inactivity: 0.0, clock: -> { base_time })
      expect { drive(idle) }.not_to raise_error
      expect(idle).not_to be_in_flight
    end
    it "uses a custom client when provided" do
      client_double = double
      engine = stub_engine
      idle = described_class.new(engine: engine, model: model, base_url: base_url, client: client_double)
      expect(idle.send(:client_for, idle.target)).to eq(client_double)
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
      it "logs why the summarize thread failed, and emits nothing" do
        dir = Dir.mktmpdir("samagotchi-log")
        path = File.join(dir, "chi.log")
        Samagotchi::Log.configure(path: path)
        engine = stub_engine_with_two_user_turns
        failing = double("client")
        allow(failing).to receive(:summarize).and_raise(Errno::ECONNREFUSED, "localhost:9")
        idle = described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 0.0, timeout: 1.0, client: failing, clock: -> { base_time })
        allow(idle).to receive(:should_fire?).and_return(true)
        drive(idle)

        expect(engine).not_to have_received(:emit_recap)
        record = File.open(path) { |io| Samagotchi::LogLine.each_record(io).find { |r| r.event == "summarize_failed" } }
        expect(record.to_h).to include(level: "ERROR", tag: "recap")
        expect(record.fields).to include("error" => "Errno::ECONNREFUSED")
      ensure
        FileUtils.remove_entry(dir)
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
      expect(engine).to have_received(:emit_recap).with(recap: anything, generation: gen_v1, covered: 3)
      # Invalidate (bumps generation)
      idle.invalidate!
      expect(idle.generation).to eq(gen_v1 + 1)
      # Build a fresh engine for the second call, with something new said
      more = JSON.generate(JSON.parse(messages_with_two_user_turns) + [{ "role" => "model", "content" => "Continuing" }])
      engine2 = stub_engine(messages: more)
      allow(idle).to receive(:should_fire?).and_return(true)
      idle.instance_variable_set(:@engine, engine2)
      idle.instance_variable_set(:@client_override, double("client_v2", summarize: "recap v2"))
      # Note: @generation is gen_v1+1; start bumps it to gen_v1+2
      expected_gen = gen_v1 + 2
      drive(idle)
      # The emit should use the new generation
      expect(engine2).to have_received(:emit_recap).with(recap: anything, generation: expected_gen, covered: 4)
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
      expect(engine).to have_received(:emit_recap).with(recap: "late recap", generation: idle.generation, covered: 3)
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

  describe "incremental recaps" do
    def msg(role, content) = { "role" => role, "content" => content }
    let(:first) { [msg("user", "My project is Bluefin"), msg("model", "Noted."), msg("user", "What is 2+2?"), msg("model", "4")] }
    let(:prompts) { [] }
    let(:recording_client) do
      c = double("client")
      allow(c).to receive(:summarize) { |prompt| prompts << prompt; "recap #{prompts.size}" }
      c
    end
    let(:seq) { [1] }
    let(:messages) { [first.dup] }

    def engine_for
      e = stub_engine(last_activity: base_time.to_f - 5)
      allow(e).to receive(:activity_seq) { seq[0] }
      allow(e).to receive(:messages_json_for_recap) { JSON.generate(messages[0]) }
      e
    end

    def recap_for(engine)
      described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 0.0,
                          timeout: 5.0, client: recording_client, clock: -> { base_time })
    end

    def user_text(prompt) = prompt.last[:content]

    it "summarizes only what is new since the last recap, with the previous recap in the prompt" do
      engine = engine_for
      idle = recap_for(engine)
      drive(idle)
      expect(idle.state).to include(text: "recap 1", covered: 4)
      messages[0] += [msg("user", "Reply PONG"), msg("model", "PONG")]
      seq[0] = 2
      drive(idle)
      expect(prompts.size).to eq(2)
      expect(user_text(prompts[1])).to include("Earlier recap:\nrecap 1", "Reply PONG", "PONG")
      expect(user_text(prompts[1])).not_to include("Bluefin")
      expect(idle.state).to include(text: "recap 2", covered: 6)
      expect(engine).to have_received(:emit_recap).with(recap: "recap 2", generation: idle.generation, covered: 6)
    end

    it "sends nothing when nothing new was said (a /recap or a context note re-arms the window)" do
      idle = recap_for(engine_for)
      drive(idle)
      messages[0] += [msg("system", "[note] a context note")]
      seq[0] = 2
      drive(idle)
      seq[0] = 3
      drive(idle)
      expect(prompts.size).to eq(1)
    end

    it "counts a !cmd output (a user message) as new" do
      idle = recap_for(engine_for)
      drive(idle)
      messages[0] += [msg("user", "$ ls\nREADME.md")]
      seq[0] = 2
      drive(idle)
      expect(prompts.size).to eq(2)
    end

    it "starts over when the covered messages were rewritten (a rollback plus a new turn)" do
      idle = recap_for(engine_for)
      drive(idle)
      messages[0] = first[0, 2] + [msg("user", "Actually, what is 3+3?"), msg("model", "6")]
      seq[0] = 2
      drive(idle)
      expect(user_text(prompts[1])).not_to include("Earlier recap")
      expect(user_text(prompts[1])).to include("Bluefin", "3+3")
      expect(idle.state).to include(covered: 4, text: "recap 2")
    end

    it "continues when an older model message lost its thinking (done when the next turn starts)" do
      messages[0] = first[0, 3] + [msg("model", "<think>\nsimple sum\n</think>\n\n4")]
      idle = recap_for(engine_for)
      drive(idle)
      messages[0] = first[0, 3] + [msg("model", "\n4"), msg("user", "Reply PONG"), msg("model", "PONG")]
      seq[0] = 2
      drive(idle)
      expect(user_text(prompts[1])).to include("Earlier recap:\nrecap 1")
      expect(user_text(prompts[1])).not_to include("Bluefin")
    end

    it "starts over when the history is shorter than the recap covered" do
      idle = recap_for(engine_for)
      drive(idle)
      messages[0] = [msg("user", "one"), msg("model", "a"), msg("user", "two")]
      seq[0] = 2
      drive(idle)
      expect(user_text(prompts[1])).not_to include("Earlier recap")
      expect(idle.state).to include(covered: 3)
    end

    it "keeps the previous state when an attempt fails" do
      engine = engine_for
      idle = recap_for(engine)
      drive(idle)
      allow(recording_client).to receive(:summarize).and_raise(Samagotchi::IdleClient::SummarizeError)
      messages[0] += [msg("user", "more")]
      seq[0] = 2
      drive(idle)
      expect(idle.state).to include(text: "recap 1", covered: 4)
    end
  end

  describe "with a store (recap.json)" do
    def msg(role, content) = { "role" => role, "content" => content }
    let(:history) { [msg("user", "My project is Bluefin"), msg("model", "Noted."), msg("user", "2+2?"), msg("model", "4")] }
    let(:prompts) { [] }
    let(:recording_client) do
      c = double("client")
      allow(c).to receive(:summarize) { |prompt| prompts << prompt; "recap #{prompts.size}" }
      c
    end
    let(:store_class) do
      Class.new do
        attr_accessor :key, :saved, :loads
        def initialize(key, saved = nil) = (@key = key; @saved = saved; @loads = 0)
        def load = (@loads += 1; @saved&.dup)
        def save(state) = @saved = state.dup
      end
    end

    def idle_with(store, messages, model_name: model)
      engine = stub_engine(messages: JSON.generate(messages), last_activity: base_time.to_f - 5)
      described_class.new(engine: engine, model: model_name, base_url: base_url, inactivity: 0.0,
                          timeout: 5.0, client: recording_client, clock: -> { base_time }, store: store)
    end

    it "saves each recap with what it covers, the model and when" do
      store = store_class.new("s1")
      drive(idle_with(store, history))
      expect(store.saved).to include(text: "recap 1", covered: 4, model: model)
      expect(store.saved[:covered_digest]).to eq(described_class.digest(history.last))
      expect(Time.iso8601(store.saved[:created_at])).to be_within(60).of(Time.now)
    end

    it "continues from the saved recap after a restart (a new worker)" do
      store = store_class.new("s1")
      drive(idle_with(store, history))
      restarted = idle_with(store, history + [msg("user", "Reply PONG"), msg("model", "PONG")])
      expect(restarted.state).to include(text: "recap 1", covered: 4)
      drive(restarted)
      expect(prompts.last.last[:content]).to include("Earlier recap:\nrecap 1")
      expect(prompts.last.last[:content]).not_to include("Bluefin")
    end

    it "reloads when the session changes under it (the REPL's /new or /resume)" do
      store = store_class.new("s1", { text: "old", covered: 2, covered_digest: "x" })
      idle = idle_with(store, history)
      expect(idle.state).to include(text: "old")
      store.key = "s2"
      store.saved = nil
      expect(idle.state).to be_nil
      expect(store.loads).to eq(2)
    end
  end

  describe "#write_now (the worker leaving)" do
    let(:two_turns) do
      JSON.generate([{ "role" => "user", "content" => "Hello" }, { "role" => "model", "content" => "Hi" },
                     { "role" => "user", "content" => "What about X?" }])
    end
    let(:store) do
      Class.new do
        attr_reader :saved
        def key = "s1"
        def load = nil
        def save(state) = @saved = state
      end.new
    end

    def idle_for(engine, client, timeout: 5.0, clock: -> { base_time })
      described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 180.0,
                          timeout: timeout, client: client, clock: clock, store: store)
    end

    it "writes a recap now, without waiting for the inactivity window, and saves it" do
      engine = stub_engine(messages: two_turns, last_activity: base_time.to_f)
      started = []
      idle = idle_for(engine, double(summarize: "Left recap."))
      expect(idle.write_now(on_start: -> { started << :yes })).to eq("Left recap.")
      expect(started).to eq([:yes])
      expect(store.saved).to include(text: "Left recap.", covered: 3)
    end

    it "sends nothing when nothing is new since the saved recap" do
      engine = stub_engine(messages: two_turns, last_activity: base_time.to_f)
      client = double(summarize: "Left recap.")
      idle = idle_for(engine, client)
      idle.write_now
      started = []
      expect(idle.write_now(on_start: -> { started << :yes })).to be_nil
      expect(started).to be_empty
      expect(client).to have_received(:summarize).once
    end

    it "sends nothing below the minimum user turns" do
      engine = stub_engine(messages: JSON.generate([{ "role" => "user", "content" => "Hello" }]))
      client = double(summarize: "x")
      expect(idle_for(engine, client).write_now).to be_nil
      expect(client).not_to have_received(:summarize)
    end

    it "gives up after the timeout" do
      engine = stub_engine(messages: two_turns)
      gate = Queue.new
      client = double("slow")
      allow(client).to receive(:summarize) { gate.pop; "late" }
      idle = described_class.new(engine: engine, model: model, base_url: base_url, timeout: 0.2, client: client, store: store)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(idle.write_now).to be_nil
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.0
      expect(store.saved).to be_nil
      expect(idle).not_to be_in_flight
      gate.push(:go)
    end

    it "waits for the attempt already in flight instead of starting another" do
      engine = stub_engine(messages: two_turns, last_activity: base_time.to_f - 500)
      gate = Queue.new
      client = double("slow")
      allow(client).to receive(:summarize) { gate.pop; "from the idle window" }
      idle = idle_for(engine, client)
      idle.tick
      expect(idle).to be_in_flight
      Thread.new { sleep(0.1); gate.push(:go) }
      expect(idle.write_now).to eq("from the idle window")
      expect(client).to have_received(:summarize).once
    end
  end

  describe "#request_now (/recap)" do
    let(:two_turns) do
      JSON.generate([{ "role" => "user", "content" => "Hello" }, { "role" => "model", "content" => "Hi" },
                     { "role" => "user", "content" => "What about X?" }])
    end

    def idle_for(engine, client = double(summarize: "Asked recap."))
      described_class.new(engine: engine, model: model, base_url: base_url, inactivity: 180.0,
                          timeout: 5.0, client: client, clock: -> { base_time })
    end

    it "starts an attempt at once, without the inactivity window; the scheduler collects it" do
      engine = stub_engine(messages: two_turns, last_activity: base_time.to_f)
      idle = idle_for(engine)
      expect(idle.request_now).to eq(:started)
      500.times { break unless idle.in_flight?; sleep(0.01); idle.tick }
      expect(engine).to have_received(:emit_recap).with(recap: "Asked recap.", generation: idle.generation, covered: 3)
    end

    it "says why there is nothing to ask" do
      short = stub_engine(messages: JSON.generate([{ "role" => "user", "content" => "Hello" }]))
      expect(idle_for(short).request_now).to eq(:too_short)

      engine = stub_engine(messages: two_turns)
      idle = idle_for(engine)
      idle.write_now
      expect(idle.request_now).to eq(:nothing_new)

      busy = stub_engine(messages: two_turns, turn_running: true)
      expect(idle_for(busy).request_now).to eq(:busy)
    end

    it "does not start a second attempt while one is in flight" do
      gate = Queue.new
      client = double("slow")
      allow(client).to receive(:summarize) { gate.pop; "x" }
      idle = idle_for(stub_engine(messages: two_turns), client)
      expect(idle.request_now).to eq(:started)
      expect(idle.request_now).to eq(:in_flight)
      gate.push(:go)
    end
  end
end
