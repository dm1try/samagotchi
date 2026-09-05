# frozen_string_literal: true

require "samagotchi/llm/backend"

RSpec.describe Samagotchi::LLM::RubyLLMBackend do
  describe "#wire_messages" do
    let(:backend) { described_class.new(model_name: "test-model", gem_provider: :openai) }

    it "handles text-only user messages" do
      messages = [{ role: "user", content: "Hello, world!" }]
      result = backend.send(:wire_messages, messages)

      expect(result).to eq([
        {
          role: "user",
          content: [{ type: "text", text: "Hello, world!" }]
        }
      ])
    end

    it "handles multimodal user messages with image URI" do
      image_uri = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
      messages = [
        {
          role: "user",
          content: [
            { type: "text", text: "What is in this image?" },
            { type: "image_url", image_url: { url: image_uri } }
          ]
        }
      ]
      result = backend.send(:wire_messages, messages)

      expect(result).to eq([
        {
          role: "user",
          content: [
            { type: "text", text: "What is in this image?" },
            { type: "image_url", image_url: { url: image_uri } }
          ]
        }
      ])
    end

    it "handles tool_response messages" do
      messages = [
        {
          role: "tool_response",
          content: "Image read result: { uri: 'data:image/png;base64,...' }",
          tool_call_id: "call_123"
        }
      ]
      result = backend.send(:wire_messages, messages)

      expect(result).to eq([
        {
          role: "tool",
          content: "Image read result: { uri: 'data:image/png;base64,...' }",
          tool_call_id: "call_123"
        }
      ])
    end

    it "handles model (assistant) messages" do
      messages = [
        { role: "model", content: "Let me analyze this image for you." }
      ]
      result = backend.send(:wire_messages, messages)

      expect(result).to eq([
        {
          role: "assistant",
          content: "Let me analyze this image for you."
        }
      ])
    end

    it "handles system messages" do
      messages = [
        { role: "system", content: "You are a helpful assistant." }
      ]
      result = backend.send(:wire_messages, messages)

      expect(result).to eq([
        {
          role: "system",
          content: "You are a helpful assistant."
        }
      ])
    end

    it "handles mixed content with multiple images" do
      messages = [
        {
          role: "user",
          content: [
            { type: "text", text: "Compare these images:" },
            { type: "image_url", image_url: { url: "data:image/png;base64,abc123" } },
            { type: "image_url", image_url: { url: "data:image/jpeg;base64,xyz789" } }
          ]
        }
      ]
      result = backend.send(:wire_messages, messages)

      expect(result).to eq([
        {
          role: "user",
          content: [
            { type: "text", text: "Compare these images:" },
            { type: "image_url", image_url: { url: "data:image/png;base64,abc123" } },
            { type: "image_url", image_url: { url: "data:image/jpeg;base64,xyz789" } }
          ]
        }
      ])
    end
  end
end
