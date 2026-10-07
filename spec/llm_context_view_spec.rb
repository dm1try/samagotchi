# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm_context_view"
require "samagotchi/kernel_loop"
require "samagotchi/model_profile"
require "samagotchi/llm/chat_loop"
require_relative "support/fake_chat_adapter"
require_relative "support/test_kernel"

RSpec.describe Samagotchi::LLMContextView do
  let(:conversation) do
    [{ role: "system", content: "base" }, { role: "user", content: "hi" },
     { role: "model", content: "<|tool_call>call:read{}<tool_call|>" },
     { role: "tool_response", content: "[read] lib/x.rb\n1: x", tool_ids: ["t1"] }]
  end

  it "is none by default, and under none returns the conversation it was given" do
    view = described_class.new

    expect(view).to be_none
    expect(view.messages(conversation)).to equal(conversation)
    expect(view.messages(conversation).map(&:object_id)).to eq(conversation.map(&:object_id))
  end

  # A view that records what it was asked for, and the formatter's input:
  # under none the formatter gets the very Array the view was given.
  def spy_view(kernel)
    seen = []
    view = described_class.new
    allow(view).to receive(:messages).and_wrap_original do |original, messages|
      seen << messages
      original.call(messages)
    end
    allow(kernel).to receive(:llm_context_view).and_return(view)
    seen
  end

  def formatted_inputs
    inputs = []
    allow(Samagotchi::Prompt).to receive(:format_with_images).and_wrap_original do |original, messages, **options|
      inputs << messages
      original.call(messages, **options)
    end
    inputs
  end

  describe "the native loop" do
    let(:client) { instance_double(Samagotchi::Client) }
    let(:kernel) { Samagotchi::KernelLoop.new(client: client, profile: Samagotchi::ModelProfile.qwen36) }

    before do
      allow(client).to receive(:complete) do |_prompt, on_chunk: nil, **|
        on_chunk&.call(content: "Answer", payload: { "content" => "Answer" })
        "Answer"
      end
    end

    it "formats every request's prompt from the view's messages, unchanged under none" do
      seen = spy_view(kernel)
      inputs = formatted_inputs

      kernel.run(conversation.first(2))

      expect(seen).not_to be_empty
      expect(inputs.length).to eq(seen.length)
      inputs.zip(seen).each { |input, viewed| expect(input).to equal(viewed) }
    end

    it "formats the turn-end warm-up from the view's messages too" do
      first = kernel.run(conversation.first(2))
      seen = spy_view(kernel)
      inputs = formatted_inputs

      kernel.warmup_prompt(first.conversation)

      expect(seen.length).to eq(1)
      expect(inputs).to eq(seen)
      expect(inputs.first).to equal(seen.first)
    end
  end

  describe "the chat loop" do
    let(:kernel) { test_kernel }
    let(:backend) do
      Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: FakeChatAdapter.new(FakeChatAdapter.text("hello back")))
    end

    it "builds the wire messages from the view's messages, the same as without it under none" do
      plain = backend.wire_messages(conversation)
      seen = spy_view(kernel)

      expect(backend.wire_messages(conversation)).to eq(plain)
      expect(seen).to eq([conversation])
      expect(seen.first).to equal(conversation)
    end
  end
end
