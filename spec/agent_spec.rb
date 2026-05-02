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
    original_thinking_render_interval = ENV["SAMAGOTCHI_THINKING_RENDER_INTERVAL"]
    original_status_line = ENV["SAMAGOTCHI_STATUS_LINE"]
    original_status_width_mode = ENV["SAMAGOTCHI_STATUS_WIDTH_MODE"]
    original_status_fixed_width = ENV["SAMAGOTCHI_STATUS_FIXED_WIDTH"]
    original_status_max_width = ENV["SAMAGOTCHI_STATUS_MAX_WIDTH"]
    original_columns = ENV["COLUMNS"]
    example.run
    ENV["THINKING_MODE"] = original_thinking_mode
    ENV["SAMAGOTCHI_SKIP_AGENT_MD"] = original_skip_agent_md
    ENV["SAMAGOTCHI_HISTORY_FILE"] = original_history_file
    ENV["XDG_STATE_HOME"] = original_xdg_state_home
    ENV["SAMAGOTCHI_THINKING_UI"] = original_thinking_ui
    ENV["SAMAGOTCHI_THINKING_RENDER_INTERVAL"] = original_thinking_render_interval
    ENV["SAMAGOTCHI_STATUS_LINE"] = original_status_line
    ENV["SAMAGOTCHI_STATUS_WIDTH_MODE"] = original_status_width_mode
    ENV["SAMAGOTCHI_STATUS_FIXED_WIDTH"] = original_status_fixed_width
    ENV["SAMAGOTCHI_STATUS_MAX_WIDTH"] = original_status_max_width
    ENV["COLUMNS"] = original_columns
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

    it "does not render tool activity lines for startup memory index reads" do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("", scope: "project").and_return("- project index")
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("", scope: "system").and_return("- system index")
      allow(client).to receive(:complete).and_return("ok")

      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      expect { agent.run }
        .to output(/\A(?!.*tool> reading memory).*ok/m).to_stdout
    end

    it "prints unified sticky status line with memory segment when memory files were loaded" do
      responses = [
        %(<|tool_call>call:read{path: "memories/refactoring_backlog.md"}<tool_call|>),
        "done"
      ]
      allow(client).to receive(:complete).and_return(*responses)

      agent = described_class.new(mode: "assist", prompt: "read memory", client: client)
      allow(agent).to receive(:color_output?).and_return(false)

      expect { agent.run }
        .to output(/status> mode=assist \| mem: refactoring_backlog.*done/m).to_stdout
    end

    it "uses the assist system prompt" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      agent.run
      expect(received_prompt).to include("friendly name for the Samagotchi assistant harness")
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
      ENV.delete("SAMAGOTCHI_THINKING_PREVIEW_LINES")
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

    it "renders a tail preview line while streaming" do
      allow(client).to receive(:complete) do |_prompt, on_chunk: nil|
        on_chunk&.call(content: "hello", payload: { "content" => "hello" })
        on_chunk&.call(content: " world", payload: { "content" => " world" })
        "done"
      end

      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:thinking_spinner_enabled?).and_return(true)
      allow(agent).to receive(:color_output?).and_return(false)
      allow(agent).to receive(:thinking_render_min_interval).and_return(0.0)

      expect { agent.run }.to output(/model> .*hello world.*done/m).to_stdout
    end

    it "renders the preview line in color when color output is enabled" do
      allow(client).to receive(:complete) do |_prompt, on_chunk: nil|
        on_chunk&.call(content: "hello", payload: { "content" => "hello" })
        "done"
      end

      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:thinking_spinner_enabled?).and_return(true)
      allow(agent).to receive(:color_output?).and_return(true)
      allow(agent).to receive(:thinking_render_min_interval).and_return(0.0)

      expect { agent.run }.to output(/#{ansi_escape}model> … hello#{ansi_escape}.*done/m).to_stdout
    end

    it "keeps preview lines at a fixed height and pads when content is short" do
      ENV["SAMAGOTCHI_THINKING_PREVIEW_LINES"] = "3"
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:thinking_spinner_enabled?).and_return(true)
      allow(agent).to receive(:color_output?).and_return(false)

      agent.send(:handle_stream_event, type: :generation_started)
      agent.send(:handle_stream_event, type: :generation_chunk, content: "short")

      lines, has_content = agent.send(:thinking_tail_preview_lines)
      expect(has_content).to be(true)
      expect(lines.length).to eq(3)
      expect(lines[0]).to include("short")
      expect(lines[1].strip).to eq("")
      expect(lines[2].strip).to eq("")
    end

    it "caps each preview line to fixed width" do
      ENV["SAMAGOTCHI_THINKING_PREVIEW_LINES"] = "3"
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:thinking_spinner_enabled?).and_return(true)
      allow(agent).to receive(:color_output?).and_return(false)

      agent.send(:handle_stream_event, type: :generation_started)
      agent.send(:handle_stream_event, type: :generation_chunk, content: "x" * 500)

      lines, = agent.send(:thinking_tail_preview_lines)
      expect(lines.length).to eq(3)
      expect(lines.all? { |line| line.length <= described_class::THINKING_PREVIEW_WIDTH }).to be(true)
    end

    it "sanitizes control tokens in preview text before line layout" do
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:thinking_spinner_enabled?).and_return(true)
      allow(agent).to receive(:color_output?).and_return(false)

      agent.send(:handle_stream_event, type: :generation_started)
      raw = "start <|tool_call> call:read{path: \"x\"}<tool_call|> " + ("x" * 120)
      agent.send(:handle_stream_event, type: :generation_chunk, content: raw)

      lines, has_content = agent.send(:thinking_tail_preview_lines)
      flattened = lines.join(" ")
      expect(has_content).to be(true)
      expect(flattened).not_to include("<|tool_call>")
      expect(flattened).not_to include("<tool_call|>")
    end

    it "clamps preview line count config to the supported range" do
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)

      ENV["SAMAGOTCHI_THINKING_PREVIEW_LINES"] = "0"
      expect(agent.send(:thinking_preview_lines_count)).to eq(1)

      ENV["SAMAGOTCHI_THINKING_PREVIEW_LINES"] = "7"
      expect(agent.send(:thinking_preview_lines_count)).to eq(3)

      ENV["SAMAGOTCHI_THINKING_PREVIEW_LINES"] = "invalid"
      expect(agent.send(:thinking_preview_lines_count)).to eq(1)
    end

    it "does not capture preview text outside assist mode" do
      agent = described_class.new(mode: "evolve", prompt: "hi", client: client)
      allow(agent).to receive(:thinking_spinner_enabled?).and_return(true)
      allow(agent).to receive(:color_output?).and_return(false)

      agent.send(:handle_stream_event, type: :generation_started)
      agent.send(:handle_stream_event, type: :generation_chunk, content: "preview me")

      expect(agent.send(:thinking_tail_preview_line)).to be_nil
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

    it "uses configured render interval for spinner throttling" do
      ENV["SAMAGOTCHI_THINKING_RENDER_INTERVAL"] = "0.2"
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)

      expect(agent.send(:thinking_render_min_interval)).to eq(0.2)
    end

    it "falls back to default render interval for invalid values" do
      ENV["SAMAGOTCHI_THINKING_RENDER_INTERVAL"] = "invalid"
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)

      expect(agent.send(:thinking_render_min_interval)).to eq(0.08)
    end

    it "tracks active memory names for direct reads under memories/" do
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:color_output?).and_return(false)

      agent.send(:handle_stream_event, type: :tool_call_started, call: { name: "read", content: "memories/refactoring_backlog.md" })

      expect(agent.send(:memory_spinner_segment)).to include("mem: refactoring_backlog")
      expect(agent.send(:memory_sticky_line)).to include("active this session: refactoring_backlog")
    end

    it "builds a generalized status line with mode, context, and memory segments" do
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:color_output?).and_return(false)

      result = Samagotchi::KernelLoop::Result.new(
        output: "ok",
        conversation: [
          {
            role: "system",
            content: "CONTEXT_STATUS window_tokens=256000 est_used_tokens=90000 est_remaining_tokens=166000 est_pct=35.2 bucket=20plus thresholds=20,40,60,80 guidance=clarify_scope_minimize_uncertainty"
          }
        ],
        exhausted: false,
        pending_tool_calls: false,
        tool_activity: []
      )

      agent.send(:capture_context_status_from_result, result)
      agent.send(:handle_stream_event, type: :tool_call_started, call: { name: "read", content: "memories/refactoring_backlog.md" })

      status = agent.send(:build_status_line, scope: :spinner)
      expect(status).to include("mode=assist")
      expect(status).to include("ctx=35.2% (20plus)")
      expect(status).to include("| mem:")
    end

    it "defaults status width mode to terminal_cap" do
      ENV.delete("SAMAGOTCHI_STATUS_WIDTH_MODE")
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)

      expect(agent.send(:status_width_mode)).to eq("terminal_cap")
    end

    it "supports fixed status width mode" do
      ENV["SAMAGOTCHI_STATUS_WIDTH_MODE"] = "fixed"
      ENV["SAMAGOTCHI_STATUS_FIXED_WIDTH"] = "73"
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)

      expect(agent.send(:status_effective_width)).to eq(73)
    end

    it "caps terminal-aware status width to SAMAGOTCHI_STATUS_MAX_WIDTH" do
      ENV["SAMAGOTCHI_STATUS_WIDTH_MODE"] = "terminal_cap"
      ENV["SAMAGOTCHI_STATUS_MAX_WIDTH"] = "50"
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:terminal_columns).and_return(120)

      expect(agent.send(:status_effective_width)).to eq(50)
    end

    it "uses COLUMNS when IO.console width is unavailable" do
      ENV["COLUMNS"] = "77"
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(IO).to receive(:console).and_return(nil)

      expect(agent.send(:terminal_columns)).to eq(77)
    end

    it "keeps spinner memory notification across generation completion within the same turn" do
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:color_output?).and_return(false)

      agent.send(:handle_stream_event, type: :tool_call_started, call: { name: "read", content: "memories/refactoring_backlog.md" })
      expect(agent.send(:thinking_spinner_status_line, "/")).to include("memory_loaded: refactoring_backlog")

      agent.send(:handle_stream_event, type: :generation_completed)

      expect(agent.send(:thinking_spinner_status_line, "/")).to include("memory_loaded: refactoring_backlog")
    end

    it "keeps memory notification inline with spinner status during thinking" do
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:color_output?).and_return(false)

      agent.send(:handle_stream_event, type: :generation_started)
      agent.send(:handle_stream_event, type: :tool_call_started, call: { name: "memory_read", content: "crawler_exploration_ideas" })

      line = agent.send(:thinking_spinner_status_line, "\\")
      expect(line).to include("thinking... \\")
      expect(line).to include("memory_loaded: crawler_exploration_ideas")
      expect(line).to include("last_tool:")
      expect(line).to include("memory_")
    end

    it "does not show inline last-tool info for non-memory tool calls" do
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:color_output?).and_return(false)

      agent.send(:handle_stream_event, type: :generation_started)
      agent.send(:handle_stream_event, type: :tool_call_started, call: { name: "execute", content: "echo hi" })

      line = agent.send(:thinking_spinner_status_line, "|")
      expect(line).not_to include("loaded:")
      expect(line).not_to include("tool:")
    end

    it "refreshes spinner immediately when memory tool calls start" do
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:color_output?).and_return(false)

      expect(agent).to receive(:render_thinking_spinner).at_least(:once)
      agent.instance_variable_set(:@thinking_spinner_active, true)

      agent.send(:handle_stream_event, type: :tool_call_started, call: { name: "memory_read", content: "crawler_exploration_ideas" })
    end

    it "renders retry status in the same spinner line" do
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:color_output?).and_return(false)

      agent.send(:handle_stream_event, type: :generation_started)
      agent.send(
        :handle_stream_event,
        type: :generation_retrying,
        attempt: 1,
        max_retries: 5,
        next_delay: 0.5,
        error_class: "Errno::ECONNREFUSED"
      )

      line = agent.send(:thinking_spinner_status_line, "/")
      expect(line).to include("network error: retrying")
      expect(line).to include("(1/6 in 0.5s)")
    end

    it "renders retry status in red when color output is enabled" do
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:color_output?).and_return(true)

      agent.send(:handle_stream_event, type: :generation_started)
      agent.send(
        :handle_stream_event,
        type: :generation_retrying,
        attempt: 2,
        max_retries: 5,
        next_delay: 1.0,
        error_class: "Net::OpenTimeout"
      )

      line = agent.send(:thinking_spinner_status_line, "-")
      expect(line).to include("\e[31m")
      expect(line).to include("network error: retrying")
    end

    it "cancels via ctrl-c byte while the hotkey monitor is active" do
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      controller = Samagotchi::Client::CancellationController.new

      agent.send(:process_cancel_hotkey_char, described_class::CTRL_C_BYTE, at: agent.send(:monotonic_time), controller: controller)

      expect(controller).to be_cancelled
      expect(controller.reason).to eq(:ctrl_c)
    end

    it "starts and stops the cancel hotkey monitor around generation" do
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      controller = Samagotchi::Client::CancellationController.new
      agent.instance_variable_set(:@active_cancel_controller, controller)

      expect(agent).to receive(:start_cancel_hotkey_monitor).with(controller)
      expect(agent).to receive(:stop_cancel_hotkey_monitor).at_least(:once)

      agent.send(:handle_stream_event, type: :generation_started)
      agent.send(:handle_stream_event, type: :generation_completed)
    end

    it "uses cbreak mode for the cancel hotkey monitor input wrapper" do
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      stdin = double("stdin")
      observed = []

      allow(stdin).to receive(:cbreak) do |&block|
        observed << :cbreak
        block.call
      end

      agent.send(:with_cancel_hotkey_input_mode, stdin) do
        observed << :inside
      end

      expect(observed).to eq([:cbreak, :inside])
    end

    it "resets spinner memory notification on a new run" do
      result = Samagotchi::KernelLoop::Result.new(
        output: "done",
        conversation: [],
        exhausted: false,
        pending_tool_calls: false,
        tool_activity: []
      )
      kernel = instance_double(Samagotchi::KernelLoop, run: result)
      allow(Samagotchi::KernelLoop).to receive(:new).and_return(kernel)

      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:color_output?).and_return(false)

      agent.send(:handle_stream_event, type: :tool_call_started, call: { name: "memory_read", content: "crawler_exploration_ideas" })
      expect(agent.send(:thinking_spinner_status_line, "/")).to include("memory_loaded: crawler_exploration_ideas")

      allow(agent).to receive(:handle_stream_event)
      agent.send(:run_kernel_with_thinking_feedback, [{ role: "user", content: "hi" }])

      expect(agent.send(:thinking_spinner_status_line, "/")).not_to include("memory_loaded: crawler_exploration_ideas")
      expect(agent.send(:thinking_spinner_status_line, "/")).not_to include("last_tool: memory_read")
    end

    it "prints idle status before the next assist prompt when enabled" do
      allow(client).to receive(:complete).and_return("done")
      allow(Reline).to receive(:readmultiline).and_return("hello", nil)

      agent = described_class.new(mode: "assist", client: client)
      allow(agent).to receive(:color_output?).and_return(false)

      expect { agent.run }.to output(/status> mode=assist.*done/m).to_stdout
    end

    it "does not print idle status when SAMAGOTCHI_STATUS_LINE is off" do
      ENV["SAMAGOTCHI_STATUS_LINE"] = "off"
      allow(client).to receive(:complete).and_return("done")
      allow(Reline).to receive(:readmultiline).and_return("hello", nil)

      agent = described_class.new(mode: "assist", client: client)
      allow(agent).to receive(:color_output?).and_return(false)

      expect { agent.run }.not_to output(/status> /).to_stdout
    end

    it "tracks active memory names for memory_read tool calls" do
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:color_output?).and_return(false)

      agent.send(:handle_stream_event, type: :tool_call_started, call: { name: "memory_read", content: "crawler_exploration_ideas" })

      expect(agent.send(:memory_spinner_segment)).to include("mem: crawler_exploration_ideas")
      expect(agent.send(:memory_sticky_line)).to include("active this session: crawler_exploration_ideas")
    end

    it "keeps spinner memory names across generation completion within a turn" do
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:thinking_spinner_enabled?).and_return(false)
      allow(agent).to receive(:color_output?).and_return(false)

      agent.send(:handle_stream_event, type: :generation_started)
      agent.send(:handle_stream_event, type: :tool_call_started, call: { name: "read", content: "memories/refactoring_backlog.md" })
      expect(agent.send(:memory_spinner_segment)).to include("refactoring_backlog")
      expect(agent.send(:memory_sticky_line)).to include("refactoring_backlog")

      agent.send(:handle_stream_event, type: :generation_completed)

      expect(agent.send(:memory_spinner_segment)).to include("refactoring_backlog")
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

    it "restores the submitted prompt after retry exhaustion" do
      allow(client).to receive(:complete).and_raise(
        Samagotchi::Client::RetryExhausted.new(attempts: 6, last_error: Errno::ECONNREFUSED.new)
      )
      allow(Reline).to receive(:readmultiline).and_return("retry me", nil)

      agent = described_class.new(mode: "assist", client: client)

      expect(agent).to receive(:queue_input_prefill).with("retry me").and_call_original
      expect { agent.run }.to output(/network error after 6 attempts; prompt restored for retry/m).to_stdout
    end

    it "injects queued prefill text into the next multiline input" do
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:color_output?).and_return(false)
      allow(Reline).to receive(:line_buffer).and_return("retry me")

      previous_hook = Reline.pre_input_hook
      allow(Reline).to receive(:readmultiline) do |_prompt, _history, &_block|
        expect(Reline.pre_input_hook).not_to be_nil
        Reline.pre_input_hook.call
        "retry me"
      end
      expect(Reline).to receive(:insert_text).with("retry me")

      agent.send(:queue_input_prefill, "retry me")
      value = agent.send(:read_input, awaiting_continue: false)

      expect(value).to eq("retry me")
      expect(Reline.pre_input_hook).to be(previous_hook)
    end
  end

  describe "assist-mode @ path completion" do
    let(:tmpdir) { Dir.mktmpdir("samagotchi-path-complete") }
    let(:system_memories_dir) { Dir.mktmpdir("samagotchi-system-memories") }

    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      ENV.delete("SAMAGOTCHI_SKIP_AGENT_MD")
      stub_const("Samagotchi::Tools::SYSTEM_MEMORIES_DIR", system_memories_dir)
    end

    around do |example|
      previous_dir = Dir.pwd
      previous_completion_proc = Reline.completion_proc
      previous_autocompletion = Reline.autocompletion
      Dir.chdir(tmpdir)
      example.run
      Dir.chdir(previous_dir)
      Reline.completion_proc = previous_completion_proc
      Reline.autocompletion = previous_autocompletion
      FileUtils.rm_rf(tmpdir)
      FileUtils.rm_rf(system_memories_dir)
    end

    it "completes project paths when input starts with @" do
      FileUtils.mkdir_p("lib/samagotchi")
      File.write("lib/samagotchi/agent.rb", "# test")

      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(Reline).to receive(:line_buffer).and_return("@lib/sama")

      candidates = agent.send(:assist_path_completion_candidates, "@lib/sama")

      expect(candidates).to include("@lib/samagotchi/")
    end

    it "completes when @token appears later in the line" do
      FileUtils.mkdir_p("lib/samagotchi")
      File.write("lib/samagotchi/agent.rb", "# test")

      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(Reline).to receive(:line_buffer).and_return("please open @lib/sama")

      candidates = agent.send(:assist_path_completion_candidates, "@lib/sama")

      expect(candidates).to include("@lib/samagotchi/")
    end

    it "completes project memories with # shorthand" do
      FileUtils.mkdir_p("memories")
      File.write("memories/release_notes.md", "# notes")

      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(Reline).to receive(:line_buffer).and_return("#rel")

      candidates = agent.send(:assist_path_completion_candidates, "#rel")

      expect(candidates).to include("#release_notes")
    end

    it "completes system memories with # shorthand" do
      File.write(File.join(system_memories_dir, "shared_notes.md"), "# notes")

      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(Reline).to receive(:line_buffer).and_return("#sha")

      candidates = agent.send(:assist_path_completion_candidates, "#sha")

      expect(candidates).to include("#shared_notes")
    end

    it "disambiguates duplicate memory names across scopes" do
      FileUtils.mkdir_p("memories")
      File.write("memories/notes.md", "# project")
      File.write(File.join(system_memories_dir, "notes.md"), "# system")

      agent = described_class.new(mode: "assist", prompt: "hi", client: client)

      candidates = agent.send(:assist_path_completion_candidates, "#")

      expect(candidates).to include("#project/notes")
      expect(candidates).to include("#system/notes")
      expect(candidates).not_to include("#notes")
    end

    it "prioritizes project memories ahead of system memories in the # list" do
      FileUtils.mkdir_p("memories")
      File.write("memories/zebra.md", "# project")
      File.write(File.join(system_memories_dir, "alpha.md"), "# system")

      agent = described_class.new(mode: "assist", prompt: "hi", client: client)

      candidates = agent.send(:assist_path_completion_candidates, "#")

      expect(candidates.first).to eq("#zebra")
      expect(candidates).to eq(["#zebra", "#alpha"])
    end

    it "restores Reline completion proc after multiline input" do
      File.write("README.md", "test")
      original_proc = proc { ["original"] }
      Reline.completion_proc = original_proc
      Reline.autocompletion = false

      allow(Reline).to receive(:line_buffer).and_return("@REA")
      allow(Reline).to receive(:readmultiline) do |_prompt, _history, &_block|
        expect(Reline.autocompletion).to be(true)
        expect(Reline.completion_proc.call("@REA")).to include("@README.md")
        "@README.md"
      end

      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      value = agent.send(:read_input, awaiting_continue: false)

      expect(value).to eq("@README.md")
      expect(Reline.completion_proc).to be(original_proc)
      expect(Reline.autocompletion).to be(false)
    end

    it "offers # memory candidates during multiline input" do
      FileUtils.mkdir_p("memories")
      File.write("memories/feature_flags.md", "# flags")
      original_proc = proc { ["original"] }
      Reline.completion_proc = original_proc
      Reline.autocompletion = false

      allow(Reline).to receive(:line_buffer).and_return("#fea")
      allow(Reline).to receive(:readmultiline) do |_prompt, _history, &_block|
        expect(Reline.autocompletion).to be(true)
        expect(Reline.completion_proc.call("#fea")).to include("#feature_flags")
        "#feature_flags"
      end

      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      value = agent.send(:read_input, awaiting_continue: false)

      expect(value).to eq("#feature_flags")
      expect(Reline.completion_proc).to be(original_proc)
      expect(Reline.autocompletion).to be(false)
    end

    it "does not enable path completion for continuation input" do
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(Reline).to receive(:readline).and_return("yes")

      expect(agent).not_to receive(:with_scoped_at_path_completion)
      expect(agent.send(:read_input, awaiting_continue: true)).to eq("yes")
    end

    it "normalizes memory shorthand only for the model-facing prompt" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "done"
      end
      allow(Reline).to receive(:readmultiline).and_return("Please review #project/plan and #shared_notes", nil)

      agent = described_class.new(mode: "assist", client: client)

      expect { agent.run }.to output(/done/).to_stdout
      expect(received_prompt).to include('Please review memory "plan" in project scope and memory "shared_notes"')
      expect(received_prompt).not_to include("#project/plan")
      expect(received_prompt).not_to include("#shared_notes")
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
