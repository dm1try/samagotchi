# frozen_string_literal: true

require "spec_helper"
require "samagotchi/kernel_loop"
require "samagotchi/model_profile"
require "samagotchi/prompt"
require "samagotchi/llm/chat_loop"
require "samagotchi/context_note"
require_relative "support/fake_chat_adapter"
require_relative "support/test_kernel"

# The history stamps (MessageTime::KEY) are display-only: a turn on either
# loop keeps the older entries' stamps and stamps its own reply, and the
# bytes the model gets are the same as for the history without stamps (the
# prompt cache never sees them).
RSpec.describe "History stamps (MessageTime::KEY)" do
  let(:key) { Samagotchi::MessageTime::KEY }
  let(:note) do
    Samagotchi::ContextNote.message(note_id: "n1", text: "deploy frozen", source: "slack",
                                    created_at: "2026-10-24T07:00:00Z")
  end
  # An older turn (a prompt and its answer), a note, then this turn's prompt.
  let(:stamped) do
    [{ role: "user", content: "earlier", turn_id: "T1", at: "2026-10-24T09:00:00.000+02:00" },
     { role: "model", content: "<think>hm</think>done earlier", at: "2026-10-24T09:01:00.000+02:00" },
     note,
     { role: "user", content: "now", turn_id: "T2", at: "2026-10-24T10:00:00.000+02:00" }]
  end
  let(:unstamped) { stamped.map { |message| message.except(key) } }

  describe "the native loop (KernelLoop)" do
    let(:client) { test_client }
    let(:kernel) { test_kernel(client: client, profile: Samagotchi::ModelProfile.qwen36) }

    def run(messages, **options)
      prompts = []
      allow(client).to receive(:complete) do |prompt, **_kwargs|
        prompts << prompt
        "PONG"
      end
      [kernel.run(messages.map(&:dup), **options), prompts]
    end

    it "keeps the older entries' stamps through the turn and stamps the reply" do
      result, = run(stamped)

      expect(result.conversation.map { |m| m[key] }).to eq(stamped.map { |m| m[key] } + [message_at])
      expect(result.conversation.last).to include(role: "model", content: a_string_ending_with("PONG"))
    end

    it "keeps them on a resumed run's model messages too (the thought-keeping branch)" do
      # A Continue: no prompt of its own, the run resumed from its start.
      result, = run(stamped.first(3), reasoning_since: 0)

      expect(result.conversation[1]).to include(content: "<think>hm</think>done earlier", at: "2026-10-24T09:01:00.000+02:00")
    end

    it "sends the same prompt with and without stamps" do
      _, with = run(stamped)
      _, without = run(unstamped)

      expect(with).to eq(without)
    end
  end

  describe "the chat loop (LLM::ChatLoop)" do
    let(:adapter) { FakeChatAdapter.new(FakeChatAdapter.text("PONG")) }
    let(:loop_backend) { Samagotchi::LLM::ChatLoop.new(kernel: test_kernel, adapter: adapter) }

    it "keeps the older entries' stamps through the turn and stamps the reply" do
      result = loop_backend.complete(messages: stamped.map(&:dup), model_name: "m")

      expect(result.conversation.map { |m| m[key] }).to eq(stamped.map { |m| m[key] } + [message_at])
      expect(result.conversation.last).to include(role: "model", content: "PONG")
    end

    it "sends the same messages with and without stamps" do
      loop_backend.complete(messages: stamped.map(&:dup), model_name: "m")
      loop_backend.complete(messages: unstamped.map(&:dup), model_name: "m")

      with, without = adapter.requests.map { |request| request[:messages] }
      expect(with).to eq(without)
      expect(JSON.generate(loop_backend.wire_messages(stamped))).to eq(JSON.generate(loop_backend.wire_messages(unstamped)))
    end
  end

  describe "Prompt.format_with_images" do
    it "renders the same bytes with and without stamps" do
      profile = Samagotchi::ModelProfile.qwen36

      expect(Samagotchi::Prompt.format_with_images(stamped, profile: profile))
        .to eq(Samagotchi::Prompt.format_with_images(unstamped, profile: profile))
    end
  end
end
