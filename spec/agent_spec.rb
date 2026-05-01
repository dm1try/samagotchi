# frozen_string_literal: true

require "samagotchi/agent"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"

RSpec.describe Samagotchi::Agent do
  let(:client) { instance_double(Samagotchi::Client) }
  let(:ansi_escape) { /\e\[[0-9;]+m/ }

  around do |example|
    original_thinking_mode = ENV["THINKING_MODE"]
    original_skip_agent_md = ENV["SAMAGOTCHI_SKIP_AGENT_MD"]
    original_history_file = ENV["SAMAGOTCHI_HISTORY_FILE"]
    original_xdg_state_home = ENV["XDG_STATE_HOME"]
    original_thinking_ui = ENV["SAMAGOTCHI_THINKING_UI"]
    example.run
    ENV["THINKING_MODE"] = original_thinking_mode
    ENV["SAMAGOTCHI_SKIP_AGENT_MD"] = original_skip_agent_md
    ENV["SAMAGOTCHI_HISTORY_FILE"] = original_history_file
    ENV["XDG_STATE_HOME"] = original_xdg_state_home
    ENV["SAMAGOTCHI_THINKING_UI"] = original_thinking_ui
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

    it "passes log_file configuration through to KernelLoop" do
      result = Samagotchi::KernelLoop::Result.new(
        output: "ok",
        conversation: [],
        exhausted: false,
        pending_tool_calls: false,
        tool_activity: []
      )
      kernel = instance_double(Samagotchi::KernelLoop, run: result)
      expect(Samagotchi::KernelLoop).to receive(:new)
        .with(client: client, verbose: false, log_file: "tmp/custom.log")
        .and_return(kernel)

      agent = described_class.new(mode: "assist", prompt: "hi", client: client, log_file: "tmp/custom.log")
      expect { agent.run }.to output(/ok/).to_stdout
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

    it "prints sticky session memory line when memory files were loaded" do
      responses = [
        %(<|tool_call>call:read{path: "memories/refactoring_backlog.md"}<tool_call|>),
        "done"
      ]
      allow(client).to receive(:complete).and_return(*responses)

      agent = described_class.new(mode: "assist", prompt: "read memory", client: client)
      allow(agent).to receive(:color_output?).and_return(false)

      expect { agent.run }
        .to output(/memories> active this session: refactoring_backlog.*done/m).to_stdout
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
      expect(received_prompt).to include('description:<|"|>Read a file from disk. Large files may be truncated to a head+tail preview with metadata.<|"|>')
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

    it "includes strict edit declaration guidance about read-first and small unique chunks" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")

      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      agent.run

      expect(received_prompt).to include("Before calling edit, read the file")
      expect(received_prompt).to include("Prefer small, minimal, unique chunks")
    end

    it "includes edit workflow instructions in assist mode" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")

      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      agent.run

      expect(received_prompt).to include("Editing workflow:")
      expect(received_prompt).to include("Copy old_text verbatim")
      expect(received_prompt).to include("Use write for full-file rewrites")
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

    it "includes edit workflow instructions in evolve mode" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      agent = described_class.new(mode: "evolve", prompt: "hi", client: client)
      allow(agent).to receive(:rg_available?).and_return(false)

      agent.run

      expect(received_prompt).to include("Editing workflow:")
      expect(received_prompt).to include("Copy old_text verbatim")
      expect(received_prompt).to include("Use write for full-file rewrites")
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

  describe "thinking spinner" do
    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      ENV["SAMAGOTCHI_THINKING_UI"] = "spinner"
    end

    it "renders spinner progress in TTY mode while streaming" do
      allow(client).to receive(:complete) do |_prompt, on_chunk: nil|
        on_chunk&.call(content: "a", payload: { "content" => "a" })
        on_chunk&.call(content: "b", payload: { "content" => "b" })
        "done"
      end

      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:thinking_spinner_enabled?).and_return(true)

      expect { agent.run }.to output(/thinking\.\.\..*done/m).to_stdout
    end

    it "does not render spinner in non-TTY mode" do
      allow(client).to receive(:complete) do |_prompt, on_chunk: nil|
        on_chunk&.call(content: "a", payload: { "content" => "a" })
        "done"
      end
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:thinking_spinner_enabled?).and_return(false)

      expect { agent.run }.to output(/done/).to_stdout
      expect { agent.run }.not_to output(/thinking\.\.\./).to_stdout
    end

    it "tracks active memory names for direct reads under memories/" do
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:color_output?).and_return(false)

      agent.send(:handle_stream_event, type: :tool_call_started, call: { name: "read", content: "memories/refactoring_backlog.md" })

      expect(agent.send(:memory_spinner_segment)).to include("mem: refactoring_backlog")
      expect(agent.send(:memory_sticky_line)).to include("active this session: refactoring_backlog")
    end

    it "tracks active memory names for memory_read tool calls" do
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:color_output?).and_return(false)

      agent.send(:handle_stream_event, type: :tool_call_started, call: { name: "memory_read", content: "crawler_exploration_ideas" })

      expect(agent.send(:memory_spinner_segment)).to include("mem: crawler_exploration_ideas")
      expect(agent.send(:memory_sticky_line)).to include("active this session: crawler_exploration_ideas")
    end

    it "shows only current generation memories in spinner" do
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:thinking_spinner_enabled?).and_return(false)
      allow(agent).to receive(:color_output?).and_return(false)

      agent.send(:handle_stream_event, type: :generation_started)
      agent.send(:handle_stream_event, type: :tool_call_started, call: { name: "read", content: "memories/refactoring_backlog.md" })
      expect(agent.send(:memory_spinner_segment)).to include("refactoring_backlog")
      expect(agent.send(:memory_sticky_line)).to include("refactoring_backlog")

      agent.send(:handle_stream_event, type: :generation_completed)

      expect(agent.send(:memory_spinner_segment)).to eq("")
      expect(agent.send(:memory_sticky_line)).to include("refactoring_backlog")
    end

    it "keeps session memories across generation completion" do
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:thinking_spinner_enabled?).and_return(false)
      allow(agent).to receive(:color_output?).and_return(false)

      agent.send(:handle_stream_event, type: :generation_started)
      agent.send(:handle_stream_event, type: :tool_call_started, call: { name: "read", content: "memories/refactoring_backlog.md" })
      expect(agent.send(:memory_sticky_line)).to include("refactoring_backlog")

      agent.send(:handle_stream_event, type: :generation_completed)

      expect(agent.send(:memory_sticky_line)).to include("refactoring_backlog")
    end
  end

  describe "assist-mode continuation" do
    let(:looping_call) { %(<|tool_call>call:execute{command: "echo step"}<tool_call|>) }
    let(:tmpdir) { Dir.mktmpdir("samagotchi-continuation") }

    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      ENV.delete("SAMAGOTCHI_SKIP_AGENT_MD")
    end

    around do |example|
      previous_dir = Dir.pwd
      ENV["SAMAGOTCHI_HISTORY_FILE"] = File.join(tmpdir, "history.json")
      Dir.chdir(tmpdir)
      example.run
      Dir.chdir(previous_dir)
      FileUtils.rm_rf(tmpdir)
    end

    it "accepts yes and resumes an exhausted turn" do
      responses = Array.new(10, looping_call) + ["finished"]

      allow(client).to receive(:complete) { |_prompt| responses.shift }
      allow(Reline).to receive(:readmultiline).and_return("run", nil)
      allow(Reline).to receive(:readline).and_return("yes")

      agent = described_class.new(mode: "assist", client: client)

      expect { agent.run }
        .to output(/iteration limit reached.*finished/m).to_stdout
    end

    it "keeps /continue working for backward compatibility" do
      responses = Array.new(10, looping_call) + ["finished"]

      allow(client).to receive(:complete) { |_prompt| responses.shift }
      allow(Reline).to receive(:readmultiline).and_return("run", nil)
      allow(Reline).to receive(:readline).and_return("/continue")

      agent = described_class.new(mode: "assist", client: client)

      expect { agent.run }
        .to output(/iteration limit reached.*finished/m).to_stdout
    end

    it "rejects new input until the interrupted turn is resumed" do
      allow(client).to receive(:complete)
        .and_return(*Array.new(10, looping_call), "finished")
      allow(Reline).to receive(:readmultiline).and_return("run", nil)
      allow(Reline).to receive(:readline).and_return("new request", "yes")

      agent = described_class.new(mode: "assist", client: client)

      expect { agent.run }
        .to output(/answer yes, no, or no, <reason>.*finished/m).to_stdout
    end

    it "supports no to cancel the interrupted turn" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length <= 10 ? looping_call : "fresh answer"
      end
      old_request = "OLD_BROAD_REQUEST_UNIQUE"
      next_request = "NEW_NARROW_REQUEST_UNIQUE"
      allow(Reline).to receive(:readmultiline).and_return(old_request, next_request, nil)
      allow(Reline).to receive(:readline).and_return("no")

      agent = described_class.new(mode: "assist", client: client)

      expect { agent.run }
        .to output(/interrupted turn cancelled; enter your next prompt.*fresh answer/m).to_stdout
      expect(prompts.last).to include(next_request)
      expect(prompts.last).not_to include(old_request)
    end

    it "accepts no with explanation and records it in conversation" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length <= 10 ? looping_call : "fresh answer"
      end
      old_request = "OLD_BROAD_REQUEST_WITH_REASON"
      next_request = "NEW_NARROW_REQUEST_WITH_REASON"
      allow(Reline).to receive(:readmultiline).and_return(old_request, next_request, nil)
      allow(Reline).to receive(:readline).and_return("no, this is too risky")

      agent = described_class.new(mode: "assist", client: client)

      expect { agent.run }
        .to output(/noted your explanation.*fresh answer/m).to_stdout
      expect(prompts.last).to include("I chose not to continue the interrupted turn because: this is too risky")
      expect(prompts.last).to include(next_request)
      expect(prompts.last).not_to include(old_request)
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

  describe "assist-mode persistent prompt history" do
    let(:tmpdir) { Dir.mktmpdir("samagotchi-history") }
    let(:xdg_state_home) { File.join(tmpdir, "state") }
    let(:history_file) { File.join(xdg_state_home, "samagotchi", "history.json") }

    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      allow(client).to receive(:complete).and_return("done")
      ENV.delete("SAMAGOTCHI_SKIP_AGENT_MD")
    end

    around do |example|
      previous_dir = Dir.pwd
      previous_history = Reline::HISTORY.to_a
      Reline::HISTORY.clear
      ENV.delete("SAMAGOTCHI_HISTORY_FILE")
      ENV["XDG_STATE_HOME"] = xdg_state_home
      Dir.chdir(tmpdir)
      example.run
      Dir.chdir(previous_dir)
      Reline::HISTORY.clear
      previous_history.each { |entry| Reline::HISTORY << entry }
      FileUtils.rm_rf(tmpdir)
    end

    it "loads XDG state prompt history on assist startup" do
      FileUtils.mkdir_p(File.dirname(history_file))
      File.write(history_file, JSON.pretty_generate(["older prompt", "latest prompt"]))
      allow(Reline).to receive(:readmultiline).and_return(nil)

      agent = described_class.new(mode: "assist", client: client)
      agent.run

      expect(Reline::HISTORY.to_a).to include("older prompt", "latest prompt")
    end

    it "persists accepted prompts and keeps only the latest 20 entries" do
      seed_entries = (1..25).map { |idx| "prompt-#{idx}" }
      FileUtils.mkdir_p(File.dirname(history_file))
      File.write(history_file, JSON.pretty_generate(seed_entries))
      allow(Reline).to receive(:readmultiline).and_return("new prompt", nil)

      agent = described_class.new(mode: "assist", client: client)
      agent.run

      persisted = JSON.parse(File.read(history_file))
      expect(persisted.length).to eq(20)
      expect(persisted.first).to eq("prompt-7")
      expect(persisted.last).to eq("new prompt")
    end

    it "does not persist continuation yes or no answers" do
      looping_call = %(<|tool_call>call:execute{command: "echo step"}<tool_call|>)
      responses = Array.new(10, looping_call) + ["finished", "fresh answer"]

      allow(client).to receive(:complete) { |_prompt| responses.shift }
      allow(Reline).to receive(:readmultiline).and_return("first request", "second request", nil)
      allow(Reline).to receive(:readline).and_return("no")

      agent = described_class.new(mode: "assist", client: client)
      agent.run

      persisted = JSON.parse(File.read(history_file))
      expect(persisted).to include("first request", "second request")
      expect(persisted).not_to include("no")
      expect(persisted).not_to include("yes")
    end

  end
end
