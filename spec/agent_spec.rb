# frozen_string_literal: true

require "samagotchi/agent"
require "stringio"

RSpec.describe Samagotchi::Agent do
  let(:client) { instance_double(Samagotchi::Client) }
  let(:ansi_escape) { /\e\[[0-9;]+m/ }

  around do |example|
    original_thinking_mode = ENV["THINKING_MODE"]
    original_skip_agent_md = ENV["SAMAGOTCHI_SKIP_AGENT_MD"]
    example.run
    ENV["THINKING_MODE"] = original_thinking_mode
    ENV["SAMAGOTCHI_SKIP_AGENT_MD"] = original_skip_agent_md
  end

  describe "#run with a one-off prompt" do
    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
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

    it "prints concise tool activity lines in normal output" do
      responses = [
        %(<|tool_call>call:read{path: "README.md"}<tool_call|>),
        "done"
      ]
      allow(client).to receive(:complete).and_return(*responses)

      agent = described_class.new(mode: "assist", prompt: "read readme", client: client)
      allow(agent).to receive(:color_output?).and_return(false)
      expect { agent.run }
        .to output(/tool> reading file \(read path=\"README.md\"\): ok.*done/m).to_stdout
    end

    it "prints colored tool activity lines when stdout supports color" do
      responses = [
        %(<|tool_call>call:read{path: "README.md"}<tool_call|>),
        "done"
      ]
      allow(client).to receive(:complete).and_return(*responses)

      agent = described_class.new(mode: "assist", prompt: "read readme", client: client)
      allow(agent).to receive(:color_output?).and_return(true)
      expect { agent.run }
        .to output(/#{ansi_escape}tool>#{ansi_escape} reading file .*#{ansi_escape}ok#{ansi_escape}.*done/m).to_stdout
    end

    it "prints plain tool activity lines when NO_COLOR is set" do
      responses = [
        %(<|tool_call>call:read{path: "README.md"}<tool_call|>),
        "done"
      ]
      allow(client).to receive(:complete).and_return(*responses)

      agent = described_class.new(mode: "assist", prompt: "read readme", client: client)
      allow(agent).to receive(:color_output?).and_return(false)
      expect { agent.run }
        .to output(/tool> reading file \(read path=\"README.md\"\): ok.*done/m).to_stdout
    end

    it "prints concise memory tool activity lines for system prompt memory index reads" do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("", scope: "project").and_return("- project index")
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("", scope: "system").and_return("- system index")
      allow(client).to receive(:complete).and_return("ok")

      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      expect { agent.run }
        .to output(/tool> reading memory \(memory_read name=\"\" scope=\"project\"\): ok.*tool> reading memory \(memory_read name=\"\" scope=\"system\"\): ok.*ok/m).to_stdout
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

    it "includes the context status telemetry protocol in the system prompt" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      agent.run
      expect(received_prompt).to include("CONTEXT_STATUS")
      expect(received_prompt).to include("Treat CONTEXT_STATUS as telemetry")
      expect(received_prompt).to include("Never ignore direct user instructions")
    end

    it "injects project and system memory indexes into the system prompt" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("", scope: "project").and_return("- **project**: test notes")
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("", scope: "system").and_return("- **system**: shared notes")
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      agent.run
      expect(received_prompt).to include("Project memories:")
      expect(received_prompt).to include("System memories:")
      expect(received_prompt).to include("- **project**: test notes")
      expect(received_prompt).to include("- **system**: shared notes")
    end

    it "uses Gemma 4 string delimiters (<|\"|\">...<|\"|>) for all string values in tool declarations" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
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
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
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

  describe "rg guidance" do
    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      ENV.delete("SAMAGOTCHI_SKIP_AGENT_MD")
      ENV.delete("THINKING_MODE")
    end

    it "includes rg guidance in the prompt when rg is available" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:rg_available?).and_return(true)
      agent.run
      expect(received_prompt).to include("prefer `rg` (ripgrep) over `grep`")
    end

    it "omits rg guidance from the prompt when rg is not available" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:rg_available?).and_return(false)
      agent.run
      expect(received_prompt).not_to include("prefer `rg` (ripgrep) over `grep`")
    end

    it "includes rg guidance in the evolve prompt when rg is available" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      agent = described_class.new(mode: "evolve", prompt: "hi", client: client)
      allow(agent).to receive(:rg_available?).and_return(true)
      agent.run
      expect(received_prompt).to include("prefer `rg` (ripgrep) over `grep`")
    end
  end

  describe "Thinking Mode (control token injection)" do
    let(:base_prompt) { "Base Prompt" }

    before do
      # Clear ENV to ensure tests are isolated from the environment
      ENV.delete("THINKING_MODE")
      ENV.delete("SAMAGOTCHI_SKIP_AGENT_MD")
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
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
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      ENV.delete("SAMAGOTCHI_SKIP_AGENT_MD")
    end

    it "prompts for /continue and resumes an exhausted turn" do
      responses = Array.new(10, looping_call) + ["finished"]

      allow(client).to receive(:complete) { |_prompt| responses.shift }
      allow(Reline).to receive(:readmultiline).and_return("run", nil)
      allow(Reline).to receive(:readline).and_return("/continue")

      agent = described_class.new(mode: "assist", client: client)

      expect { agent.run }
        .to output(/iteration limit reached; type \/continue to resume.*finished/m).to_stdout
    end

    it "rejects new input until the interrupted turn is resumed" do
      allow(client).to receive(:complete)
        .and_return(*Array.new(10, looping_call), "finished")
      allow(Reline).to receive(:readmultiline).and_return("run", nil)
      allow(Reline).to receive(:readline).and_return("new request", "/continue")

      agent = described_class.new(mode: "assist", client: client)

      expect { agent.run }
        .to output(/type \/continue to resume the interrupted turn.*finished/m).to_stdout
    end

    it "accepts multiline content from the default editor flow" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "done"
      end
      allow(Reline).to receive(:readmultiline).and_return("line one\nline two", nil)

      agent = described_class.new(mode: "assist", client: client)

      expect { agent.run }.to output(/done/).to_stdout
      expect(received_prompt).to include("line one\nline two")
    end
  end
end
