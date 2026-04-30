# frozen_string_literal: true

require "samagotchi/agent"

RSpec.describe Samagotchi::Agent do
  let(:client) { instance_double(Samagotchi::Client) }

  describe "#run with a one-off prompt" do
    it "sends the prompt to the kernel and prints the response" do
      allow(client).to receive(:complete).and_return("file1.rb\
file\
file2.rb")
      agent = described_class.new(mode: "assist", prompt: "list files", client: client)
      expect { agent.run }.to output(/file1.rb/).to_stdout
    end

    it "does not start an interactive loop" do
      call_count = 0
      allow(client).to receive(:complete) do
        call_count += 1
        "done"
      end
      agent = described_class.new(mode: "assist", prompt: "hello", client: client)
      agent.run
      expect(call_count).to eq(1)
    end

    it "uses the assist system prompt" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      agent.run
      expect(received_prompt).to include("Ruby code assistant")
    end

    it "injects the memory index into the system prompt" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("").and_return("- **notes**: test notes")
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      agent.run
      expect(received_prompt).to include("Memories:")
      expect(received_prompt).to include("- **notes**: test notes")
    end

    it "uses Gemma 4 string delimiters (<|\"|\">...<|\"|>) for all string values in tool declarations" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("").and_return("")
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      agent.run
      # All tool declaration string values must use <|"|> delimiters
      expect(received_prompt).to include('description:<|"|>Run any shell command')
      expect(received_prompt).to include('description:<|"|>Read a file from disk<|"|>')
      expect(received_prompt).to include('description:<|"|>Write content to a file')
      expect(received_prompt).to include('type:<|"|>string<|"|>')
    end

    it "uses Gemma 4 string delimiters in the tool call hint shown to the model" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("").and_return("")
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      agent.run
      expect(received_prompt).to include('param:<|"|>value<|"|>')
    end
  end

  describe "Thinking Mode (control token injection)" do
    let(:base_prompt) { "Base Prompt" }

    before do
      # Clear ENV to ensure tests are isolated from the environment
      ENV.delete("THINKING_MODE")
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("").and_return("")
    end

    it "includes the <|think|> token by default" do
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(client).to receive(:complete) do |prompt|
        expect(prompt).to include("<|think|>")
        "ok"
      end
      agent.run
    end

    it "omits the <|think|> token when THINKING_MODE=false" do
      ENV["THINKING_MODE"] = "false"
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(client).to receive(:complete) do |prompt|
        expect(prompt).not_to include("<|think|>")
        "ok"
      end
      agent.run
    end
  end
end
