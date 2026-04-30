# frozen_string_literal: true

require "samagotchi/agent"
require "stringio"

RSpec.describe Samagotchi::Agent do
  let(:client) { instance_double(Samagotchi::Client) }

  around do |example|
    original_thinking_mode = ENV["THINKING_MODE"]
    original_skip_agent_md = ENV["SAMAGOTCHI_SKIP_AGENT_MD"]
    example.run
    ENV["THINKING_MODE"] = original_thinking_mode
    ENV["SAMAGOTCHI_SKIP_AGENT_MD"] = original_skip_agent_md
  end

  describe "#run with a one-off prompt" do
    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("").and_return("")
      ENV.delete("SAMAGOTCHI_SKIP_AGENT_MD")
    end

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

    it "injects AGENT.md as project specific description when present" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:file?).with(File.join(Dir.pwd, "AGENT.md")).and_return(true)
      allow(File).to receive(:read).with(File.join(Dir.pwd, "AGENT.md")).and_return("Use project conventions")

      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      agent.run

      expect(received_prompt).to include("Project specific description:")
      expect(received_prompt).to include("Use project conventions")
    end

    it "skips AGENT.md injection when SAMAGOTCHI_SKIP_AGENT_MD=true" do
      ENV["SAMAGOTCHI_SKIP_AGENT_MD"] = "true"
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:file?).with(File.join(Dir.pwd, "AGENT.md")).and_return(true)
      allow(File).to receive(:read).with(File.join(Dir.pwd, "AGENT.md")).and_return("Use project conventions")

      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      agent.run

      expect(received_prompt).not_to include("Project specific description:")
      expect(received_prompt).not_to include("Use project conventions")
    end
  end

  describe "Thinking Mode (control token injection)" do
    let(:base_prompt) { "Base Prompt" }

    before do
      # Clear ENV to ensure tests are isolated from the environment
      ENV.delete("THINKING_MODE")
      ENV.delete("SAMAGOTCHI_SKIP_AGENT_MD")
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

  describe "assist-mode continuation" do
    let(:looping_call) { %(<|tool_call>call:execute{command: "echo step"}<tool_call|>) }

    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("").and_return("")
      ENV.delete("SAMAGOTCHI_SKIP_AGENT_MD")
    end

    it "prompts for /continue and resumes an exhausted turn" do
      responses = Array.new(10, looping_call) + ["finished"]

      allow(client).to receive(:complete) { |_prompt| responses.shift }

      agent = described_class.new(mode: "assist", client: client)
      input = StringIO.new("run\n/continue\n")

      original_stdin = $stdin
      $stdin = input

      expect { agent.run }
        .to output(/iteration limit reached; type \/continue to resume.*finished/m).to_stdout
    ensure
      $stdin = original_stdin
    end

    it "rejects new input until the interrupted turn is resumed" do
      allow(client).to receive(:complete)
        .and_return(*Array.new(10, looping_call), "finished")

      agent = described_class.new(mode: "assist", client: client)
      input = StringIO.new("run\nnew request\n/continue\n")

      original_stdin = $stdin
      $stdin = input

      expect { agent.run }
        .to output(/type \/continue to resume the interrupted turn.*finished/m).to_stdout
    ensure
      $stdin = original_stdin
    end
  end
end
