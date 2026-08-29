# frozen_string_literal: true

require "samagotchi/llm/backend"

RSpec.describe Samagotchi::LLM::RubyLLMBackend do
  # A fake gem Chat standing in for a real RubyLLM::Chat. Behaviour (add_message
  # recording, `messages`, `complete` streaming/cancel) is wired per example so we
  # never hit the network or require an OpenAI API key.
  let(:recorded_adds) { [] }
  let(:messages_store) { [] }
  let(:fake_chat) { instance_double(RubyLLM::Chat) }
  let(:backend) { described_class.new(model_name: "custom-local-model") }

  # Install the fake Chat. `add_message_recorder` captures the attrs the backend
  # passed to seed_chat; `messages_return` overrides what `messages` yields.
  def install_fake_chat!(complete_behaviour:, add_message_recorder: nil, messages_return: nil)
    allow(RubyLLM).to receive(:chat).and_return(fake_chat)
    allow(fake_chat).to receive(:add_message) do |attrs|
      add_message_recorder&.call(attrs)
      messages_store << RubyLLM::Message.new(attrs)
    end
    allow(fake_chat).to receive(:messages) { (messages_return || messages_store).dup }
    # Stub `complete` by wrapping the received streaming block in our per-example
    # behaviour; its return value becomes `complete`'s return value.
    allow(fake_chat).to receive(:complete) do |&block|
      complete_behaviour.call(block)
    end
  end

  describe "registration" do
    it "is a ModelBackend subclass" do
      expect(backend).to be_a(Samagotchi::LLM::ModelBackend)
    end
  end

  describe "#complete — inbound message mapping" do
    it "normalizes the string role to a symbol then maps engine roles to gem symbols" do
      install_fake_chat!(
        complete_behaviour: ->(_b) {},
        add_message_recorder: ->(attrs) { recorded_adds << attrs }
      )

      backend.complete(messages: [
        { role: "system", content: "sys" },
        { role: "user", content: "hi" },
        { role: "model", content: "last" }
      ])

      # :model -> :assistant (normalized first), :system/:user pass through
      expect(recorded_adds.map { |a| a[:role] }).to eq(%i[system user assistant])
      expect(recorded_adds.map { |a| a[:content] }).to eq(["sys", "hi", "last"])
    end
  end

  describe "#complete — single-pass text completion" do
    let(:response) { RubyLLM::Message.new(role: :assistant, content: "hello back") }

    before do
      install_fake_chat!(
        complete_behaviour: ->(_b) { response },
        messages_return: [
          RubyLLM::Message.new(role: :user, content: "hi"),
          RubyLLM::Message.new(role: :assistant, content: "hello back")
        ]
      )
    end

    it "returns a ModelResult mirroring the read surface" do
      result = backend.complete(messages: [{ role: "user", content: "hi" }])

      expect(result).to be_a(Samagotchi::LLM::ModelResult)
      expect(result.text).to eq("hello back")
      expect(result.output).to eq("hello back")
      expect(result.tool_calls).to be_nil
      expect(result.provider).to eq(:ruby_llm)
      expect(result.canceled?).to be(false)
    end

    it "serializes the conversation back to string role keys (assistant -> \"model\")" do
      result = backend.complete(messages: [{ role: "user", content: "hi" }])

      expect(result.conversation).to eq([
        { role: "user", content: "hi" },
        { role: "model", content: "hello back" }
      ])
    end
  end

  describe "#complete — streaming events" do
    it "emits :generation_chunk per chunk and one :generation_completed at the end" do
      events = []
      response = RubyLLM::Message.new(role: :assistant, content: "chunk1chunk2")
      install_fake_chat!(complete_behaviour: ->(block) do
        block.call(double(content: "chunk1"))
        block.call(double(content: "chunk2"))
        response
      end)

      backend.complete(
        messages: [{ role: "user", content: "hi" }],
        on_stream_event: ->(event) { events << event }
      )

      chunks = events.select { |e| e[:type] == :generation_chunk }
      expect(chunks.map { |e| e[:content] }).to eq(%w[chunk1 chunk2])
      completed = events.select { |e| e[:type] == :generation_completed }
      expect(completed.length).to eq(1)
      expect(completed.first[:content_length]).to eq(12)
    end

    it "ignores empty content chunks" do
      events = []
      install_fake_chat!(complete_behaviour: ->(block) do
        block.call(double(content: ""))
        block.call(double(content: "real"))
        double(content: "real")
      end)

      backend.complete(
        messages: [{ role: "user", content: "hi" }],
        on_stream_event: ->(event) { events << event }
      )

      chunks = events.select { |e| e[:type] == :generation_chunk }.map { |e| e[:content] }
      expect(chunks).to eq(["real"])
    end
  end

  describe "#complete — cancellation off the main thread" do
    it "raises RequestCancelled into the request thread, returning a canceled result with text '' and no partial assistant" do
      entered = Queue.new
      cc = Samagotchi::Client::CancellationController.new
      # complete yields a chunk, then blocks as if in a Faraday socket read so the
      # peer raise lands mid-flight; never adds the assistant message on cancel.
      install_fake_chat!(complete_behaviour: ->(block) do
        block.call(double(content: "partial"))
        entered << :inflight
        sleep(30)
        block.call(double(content: "more")) # unreachable once cancelled
        double(content: "should-not-be-used")
      end)

      result_holder = {}
      worker = Thread.new do
        result_holder[:result] = backend.complete(
          messages: [{ role: "user", content: "hi" }],
          cancel_controller: cc
        )
      rescue StandardError => e
        result_holder[:error] = e
      end

      # Wait until the fake is actually blocked inside complete (so cancel lands).
      expect(entered.pop).to eq(:inflight)
      cc.cancel!("test-cancel")
      worker.join(5)

      expect(worker).not_to be_alive
      expect(result_holder[:error]).to be_nil
      expect(result_holder[:result].canceled?).to be(true)
      expect(result_holder[:result].cancellation_reason).to eq("test-cancel")
      expect(result_holder[:result].text).to eq("")
      # No partial assistant turn leaked into the conversation.
      expect(result_holder[:result].conversation).to eq([{ role: "user", content: "hi" }])
    end
  end

  describe "#complete — cancel on the main thread" do
    it "degrades gracefully: completion runs, no raise into the main thread, valid result" do
      response = RubyLLM::Message.new(role: :assistant, content: "chunkAchunkB")
      cc = Samagotchi::Client::CancellationController.new
      install_fake_chat!(complete_behaviour: ->(block) do
        block.call(double(content: "chunkA"))
        # a cancel requested mid-completion on the main thread cannot interrupt;
        # the gem finishes normally (graceful degradation)
        cc.cancel!("main-thread-cancel")
        block.call(double(content: "chunkB"))
        response
      end)

      # RSpec runs on the main thread, so this exercises the inline path.
      result = backend.complete(
        messages: [{ role: "user", content: "hi" }],
        cancel_controller: cc
      )

      expect(result.canceled?).to be(false)
      expect(result.text).to eq("chunkAchunkB")
    end
  end

  describe "#complete — resume across turns" do
    it "after a cancel the returned conversation lacks the assistant turn, so the next reseed is clean" do
      cc = Samagotchi::Client::CancellationController.new
      entered = Queue.new

      # First turn cancels mid-flight (assistant never added).
      install_fake_chat!(complete_behaviour: ->(block) do
        block.call(double(content: "partial-one"))
        entered << :inflight
        sleep(30)
        double(content: "nope")
      end)

      result_holder = {}
      worker = Thread.new do
        result_holder[:result] = backend.complete(
          messages: [{ role: "user", content: "Ask part one" }],
          cancel_controller: cc
        )
      rescue StandardError => e
        result_holder[:error] = e
      end
      expect(entered.pop).to eq(:inflight)
      cc.cancel!("cancel-1")
      worker.join(5)

      expect(result_holder[:result].canceled?).to be(true)
      expect(result_holder[:result].conversation).to eq([{ role: "user", content: "Ask part one" }])

      # Second turn re-seeds from the (assistant-less) conversation — no dangling turn.
      # The engine builds a fresh cancel controller per turn, so cancel-1's state
      # does not leak into turn 2.
      install_fake_chat!(
        complete_behaviour: ->(block) do
          block.call(double(content: "part-two-chunk"))
          double(content: "part two")
        end,
        messages_return: [
          RubyLLM::Message.new(role: :user, content: "Ask part one"),
          RubyLLM::Message.new(role: :assistant, content: "part two")
        ]
      )

      result2 = backend.complete(
        messages: result_holder[:result].conversation,
        cancel_controller: Samagotchi::Client::CancellationController.new
      )

      expect(result2.canceled?).to be(false)
      expect(result2.text).to eq("part two")
      expect(result2.conversation).to eq([
        { role: "user", content: "Ask part one" },
        { role: "model", content: "part two" }
      ])
    end
  end

  describe "statelessness" do
    it "builds a fresh Chat from messages: each call (no gem Chat retained)" do
      chat1 = instance_double(RubyLLM::Chat)
      chat2 = instance_double(RubyLLM::Chat)
      calls = []
      allow(RubyLLM).to receive(:chat) do |**kwargs|
        calls << kwargs
        calls.length == 1 ? chat1 : chat2
      end
      allow(chat1).to receive(:add_message)
      allow(chat1).to receive(:complete).and_return(double(content: "one"))
      allow(chat1).to receive(:messages).and_return([])
      allow(chat2).to receive(:add_message)
      allow(chat2).to receive(:complete).and_return(double(content: "two"))
      allow(chat2).to receive(:messages).and_return([])

      backend.complete(messages: [{ role: "user", content: "hi" }])
      backend.complete(messages: [{ role: "user", content: "hi again" }])

      expect(calls.length).to eq(2)
      expect(chat1).not_to equal(chat2)
    end
  end

  describe "#complete — outbound message serialization" do
    it "maps gem symbols to string role keys (:assistant -> \"model\", :tool -> \"tool_response\")" do
      gem_msgs = [
        RubyLLM::Message.new(role: :system, content: "sys"),
        RubyLLM::Message.new(role: :user, content: "hi"),
        RubyLLM::Message.new(role: :assistant, content: "hello"),
        RubyLLM::Message.new(role: :tool, content: "tool output")
      ]
      install_fake_chat!(
        complete_behaviour: ->(_b) { gem_msgs.last },
        messages_return: gem_msgs
      )

      result = backend.complete(messages: [{ role: "user", content: "hi" }])
      expect(result.conversation).to eq([
        { role: "system", content: "sys" },
        { role: "user", content: "hi" },
        { role: "model", content: "hello" },
        { role: "tool_response", content: "tool output" }
      ])
    end
  end

  describe "#complete — model wiring" do
    it "constructs with a custom/local model name without ModelNotFoundError" do
      expect { described_class.new(model_name: "custom-local-model") }.not_to raise_error
      RubyLLM.configure { |c| c.openai_api_key = "local-dev-placeholder-key" }
      expect { RubyLLM.chat(model: "custom-local-model", provider: :openai, assume_model_exists: true) }
        .not_to raise_error
    end

    it "passes the model_name override through to RubyLLM.chat (gem provider + assume_model_exists)" do
      fake = instance_double(RubyLLM::Chat)
      captured = {}
      allow(RubyLLM).to receive(:chat) do |**kwargs|
        captured[:kwargs] = kwargs
        fake
      end
      allow(fake).to receive(:add_message)
      allow(fake).to receive(:complete).and_return(double(content: "x"))
      allow(fake).to receive(:messages).and_return([])

      backend.complete(messages: [{ role: "user", content: "hi" }], model_name: "override-model")

      expect(captured[:kwargs]).to include(
        model: "override-model",
        provider: :openai,
        assume_model_exists: true
      )
    end
  end
end
