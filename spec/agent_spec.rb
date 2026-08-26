# frozen_string_literal: true

require "samagotchi/terminal_ui"
require "fileutils"
require "json"
require "ostruct"
require "stringio"
require "tmpdir"

RSpec.describe Samagotchi::TerminalUI do
  let(:client) { instance_double(Samagotchi::Client) }
  let(:ansi_escape) { /\e\[[0-9;]+m/ }

  # Build the [system, user] message pair the UI uses to seed a turn, so tests
  # can drive the interactive rendering path (run_kernel_with_thinking_feedback +
  # emit_result) directly — independent of the now-minimal prompt_mode.
  def ui_turn_messages(agent, prompt:)
    [
      { role: "system", content: agent.send(:system_prompt_with_index, agent.send(:assist_system_prompt)) },
      { role: "user", content: prompt }
    ]
  end

  # Run the UI's streaming kernel run and render the result, capturing stdout.
  # Mirrors what prompt_mode used to do before it became a minimal Engine run.
  def run_and_render(agent, prompt:)
    original = $stdout
    buffer = StringIO.new
    $stdout = buffer
    begin
      result = agent.send(:run_kernel_with_thinking_feedback, ui_turn_messages(agent, prompt: prompt))
      agent.send(:emit_result, result)
    ensure
      $stdout = original
    end
    buffer.string
  end

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
    original_model = ENV["SAMAGOTCHI_MODEL"]
    original_columns = ENV["COLUMNS"]
    original_default_input = ENV["SAMAGOTCHI_DEFAULT_INPUT"]
    ENV["SAMAGOTCHI_MODEL"] = "Gemma-4B-it"
    ENV.delete("SAMAGOTCHI_DEFAULT_INPUT")
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
    ENV["SAMAGOTCHI_MODEL"] = original_model
    ENV["COLUMNS"] = original_columns
    if original_default_input.nil?
      ENV.delete("SAMAGOTCHI_DEFAULT_INPUT")
    else
      ENV["SAMAGOTCHI_DEFAULT_INPUT"] = original_default_input
    end
  end

  describe "#run with a one-off prompt" do
    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      ENV.delete("SAMAGOTCHI_SKIP_AGENT_MD")
      # The prompt entrypoint runs one turn then drops into the REPL; stub
      # Reline to exit immediately so .run returns in tests.
      allow(Reline).to receive(:readmultiline).and_return(nil)
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
        .with(client: client, verbose: false, log_file: "tmp/custom.log", profile: instance_of(Samagotchi::ModelProfile), no_interrupt: false)
        .and_return(kernel)

      agent = described_class.new(mode: "assist", prompt: "hi", client: client, log_file: "tmp/custom.log")
      expect { agent.run }.to output(/ok/).to_stdout
    end

    it "runs the prompt once then enters the interactive loop (exits on first read)" do
      call_count = 0
      allow(client).to receive(:complete) do
        call_count += 1
        "done"
      end
      agent = described_class.new(mode: "assist", prompt: "hello", client: client)
      agent.run
      expect(call_count).to eq(1)   # one prompt turn; REPL exits on first read
    end

    it "forwards no_interrupt to the kernel loop" do
      agent = described_class.new(mode: "assist", prompt: "test", no_interrupt: true)
      kernel = agent.instance_variable_get(:@kernel)
      expect(kernel.instance_variable_get(:@no_interrupt)).to be true
    end

    it "prints concise tool activity lines in normal output" do
      responses = [
        %(<|tool_call>call:read{path: "README.md"}<tool_call|>),
        "done"
      ]
      allow(client).to receive(:complete).and_return(*responses)

      agent = described_class.new(mode: "assist", prompt: "read readme", client: client)
      allow(agent).to receive(:color_output?).and_return(false)
      output = run_and_render(agent, prompt: "read readme")
      expect(output).to include('tool> reading file (read path="README.md"): ok')
      expect(output).to include("done")
    end

    it "prints colored tool activity lines when stdout supports color" do
      responses = [
        %(<|tool_call>call:read{path: "README.md"}<tool_call|>),
        "done"
      ]
      allow(client).to receive(:complete).and_return(*responses)
      agent = described_class.new(mode: "assist", prompt: "read readme", client: client)
      allow(agent).to receive(:color_output?).and_return(true)
      output = run_and_render(agent, prompt: "read readme")
      expect(output).to match(/#{ansi_escape}tool>#{ansi_escape}/)
      expect(output).to match(/#{ansi_escape}ok#{ansi_escape}/)
      expect(output).to include("done")
    end

    it "prints plain tool activity lines when NO_COLOR is set" do
      responses = [
        %(<|tool_call>call:read{path: "README.md"}<tool_call|>),
        "done"
      ]
      allow(client).to receive(:complete).and_return(*responses)
      agent = described_class.new(mode: "assist", prompt: "read readme", client: client)
      allow(agent).to receive(:color_output?).and_return(false)
      output = run_and_render(agent, prompt: "read readme")
      expect(output).to include('tool> reading file (read path="README.md"): ok')
      expect(output).not_to match(/#{ansi_escape}/)
      expect(output).to include("done")
    end

    it "renders tool activity immediately without duplicating it at turn end" do
      responses = [
        %(<|tool_call>call:read{path: "README.md"}<tool_call|>),
        "done"
      ]
      allow(client).to receive(:complete).and_return(*responses)
      agent = described_class.new(mode: "assist", prompt: "read readme", client: client)
      allow(agent).to receive(:color_output?).and_return(false)
      output = run_and_render(agent, prompt: "read readme")
      tool_line = 'tool> reading file (read path="README.md"): ok'
      expect(output).to include(tool_line)
      expect(output).to include("done")
      expect(output.index(tool_line)).to be < output.index("done")
      expect(output.scan(/#{Regexp.escape(tool_line)}/).length).to eq(1)
    end

    it "does not render tool activity lines for startup memory index reads" do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("", scope: "project").and_return("- project index")
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("", scope: "system").and_return("- system index")
      allow(client).to receive(:complete).and_return("ok")
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      output = run_and_render(agent, prompt: "hi")
      expect(output).to match(/\A(?!.*tool> reading memory).*ok/m)
    end

    it "prints unified sticky status line with memory segment when memory files were loaded" do
      responses = [
        %(<|tool_call>call:read{path: "memories/refactoring_backlog.md"}<tool_call|>),
        "done"
      ]
      allow(client).to receive(:complete).and_return(*responses)
      agent = described_class.new(mode: "assist", prompt: "read memory", client: client)
      allow(agent).to receive(:color_output?).and_return(false)
      output = run_and_render(agent, prompt: "read memory")
      expect(output).to match(/mem: refactoring_backlog/)
      expect(output).to include("done")
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

    it "injects requested --memory entries into the system prompt" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("foo", scope: nil).and_return("foo body")
      agent = described_class.new(mode: "assist", prompt: "hi", client: client, memories: ["foo"])
      agent.run
      expect(received_prompt).to include("this memory is required by the user in the current context: memory name: foo")
      expect(received_prompt).to include("foo body")
    end

    it "marks a preloaded --memory entry as active in the sticky status line" do
      allow(client).to receive(:complete).and_return("ok")
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("foo", scope: nil).and_return("foo body")
      agent = described_class.new(mode: "assist", prompt: "hi", client: client, memories: ["foo"])
      run_and_render(agent, prompt: "hi")
      expect(agent.send(:sticky_status_lines).join("\n")).to include("mem: foo")
    end

    it "resolves scope-prefixed --memory entries" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("foo", scope: "project").and_return("foo body")
      agent = described_class.new(mode: "assist", prompt: "hi", client: client, memories: ["project/foo"])
      agent.run
      expect(received_prompt).to include("memory name: foo")
    end

    it "skips a --memory entry that cannot be found without crashing" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("missing", scope: nil).and_return("Error: memory not found: missing")
      agent = described_class.new(mode: "assist", prompt: "hi", client: client, memories: ["missing"])
      expect { agent.run }.not_to raise_error
      expect(received_prompt).not_to include("memory is required by the user")
    end

    it "does not inject an explicit memory section when no --memory flags are given" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      agent.run
      expect(received_prompt).not_to include("memory is required by the user")
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
      expect(received_prompt).to include('description:<|"|>Read a file from disk. Large files may be truncated to a head+tail preview with metadata. Optionally pass start_line and end_line (1-based, inclusive) to read only a specific line range.<|"|>')
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

    it "includes edit declaration guidance about exact-match and range modes" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")

      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      agent.run

      expect(received_prompt).to include("Mode 1 (default): replace an exact old_text block")
      expect(received_prompt).to include("Mode 2 (range): when start_line and end_line are provided")
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
      expect(received_prompt).to include("copy old_text verbatim")
      expect(received_prompt).to include("prefer range mode")
      expect(received_prompt).to include("Use write for full-file rewrites")
    end

    it "includes small-context retrieval protocol in assist mode" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")

      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      agent.run

      expect(received_prompt).to include("Small-context retrieval protocol:")
      expect(received_prompt).to include("If the user provides file:line")
      expect(received_prompt).to include("spec/agent_spec.rb:130")
      expect(received_prompt).to include("Read a full file only when targeted snippet extraction is insufficient")
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

    it "injects the current working directory as context" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")

      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      agent.run

      expect(received_prompt).to include("Current working directory:")
      expect(received_prompt).to include(Dir.pwd)
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

  describe "run entrypoints (--prompt / --non-interactive / --resume)" do
    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      ENV.delete("SAMAGOTCHI_SKIP_AGENT_MD")
    end

    # Scenario 1: -p "x" (no --non-interactive) feeds the prompt, runs one turn,
    # then STAYS in the REPL (Option B). Reline exits immediately.
    it "feeds a -p prompt, runs one turn, then enters the REPL" do
      seen = []
      allow(client).to receive(:complete) { |p| seen << p; "done" }
      allow(Reline).to receive(:readmultiline).and_return(nil) # exit REPL immediately

      agent = described_class.new(mode: "assist", prompt: "refactor this", client: client)
      agent.run

      expect(seen.length).to eq(1) # one prompt turn only
      expect(seen.first).to include("refactor this") # prompt was fed to the model
      expect(Reline).to have_received(:readmultiline).at_least(:once) # REPL was entered
    end

    # Scenario 2: -p "x" --non-interactive runs one turn then exits (no REPL).
    it "runs the -p prompt once and exits without entering the REPL when --non-interactive" do
      seen = []
      allow(client).to receive(:complete) { |p| seen << p; "done" }
      agent = described_class.new(mode: "assist", prompt: "refactor this", client: client, non_interactive: true)

      expect(Reline).not_to receive(:readmultiline) # never enters the REPL
      agent.run

      expect(seen.length).to eq(1)
      expect(seen.first).to include("refactor this")
    end

    # Scenario 7: --non-interactive with no -p is a harmless no-op exit.
    it "exits without building a session or entering the REPL for --non-interactive with no prompt" do
      expect(client).not_to receive(:complete)
      expect(Reline).not_to receive(:readmultiline)
      agent = described_class.new(mode: "assist", client: client, non_interactive: true)
      expect { agent.run }.not_to output(/Session:/).to_stdout
    end

    # Scenario 6/10: --resume ID -p x runs the prompt on the resumed session,
    # preserving prior history as context.
    it "runs the -p prompt on a resumed session and threads history as context" do
      resumed = Samagotchi::Session.new_session(
        mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd
      )
      resumed.messages = [
        { role: "system", content: "system" },
        { role: "user", content: "prior prompt" },
        { role: "model", content: "prior answer" }
      ]

      seen = []
      allow(client).to receive(:complete) { |p| seen << p; "done" }
      allow(Reline).to receive(:readmultiline).and_return(nil)

      agent = described_class.new(mode: "assist", prompt: "next step", client: client)
      agent.instance_variable_set(:@resume_session, resumed)
      agent.run

      expect(seen.length).to eq(1) # one turn on the resumed session
      expect(seen.first).to include("next step")
      expect(seen.first).to include("prior prompt") # prior history present in context
    end

    # Scenario 4: a plain interactive session (no prompt) drops into the REPL.
    it "drops into the REPL for a plain interactive session (no prompt)" do
      allow(Reline).to receive(:readmultiline).and_return("hello", nil)
      allow(client).to receive(:complete).and_return("hi there")

      agent = described_class.new(mode: "assist", client: client)
      agent.run

      expect(Reline).to have_received(:readmultiline).at_least(:once)
    end

    # Option B end-to-end: -p prompt turn, then a follow-up REPL turn runs too.
    it "runs the prompt turn then answers a follow-up REPL turn" do
      responses = []
      allow(client).to receive(:complete) do |p|
        responses << p
        "response: #{p}"
      end
      allow(Reline).to receive(:readmultiline).and_return("follow-up", nil)

      agent = described_class.new(mode: "assist", prompt: "first turn", client: client)
      agent.run

      expect(responses.length).to eq(2)
      expect(responses.first).to include("first turn")
      expect(responses.last).to include("follow-up")
    end

    describe "no-op exit for --non-interactive with no prompt" do
      it "builds nothing and prints no banner" do
        expect {
          described_class.new(mode: "assist", client: client, non_interactive: true).run
        }.not_to output(/Session:|Resumed session:/).to_stdout
      end
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

    it "does not include the Gemma think token for Qwen profiles" do
      agent = described_class.new(
        mode: "assist",
        prompt: "hi",
        client: client,
        profile: Samagotchi::ModelProfile.qwen36
      )
      allow(client).to receive(:complete) do |prompt|
        expect(prompt).not_to include("<|think|>")
        "ok"
      end
      agent.run
    end
  end

  describe "#status_server_segment" do
    let(:agent) { described_class.new(mode: "assist", client: client) }

    it "returns an empty string when host is localhost" do
      ENV["LLAMA_HOST"] = "localhost"
      ENV["LLAMA_PORT"] = "8080"
      expect(agent.send(:status_server_segment)).to eq("")
    end

    it "returns an empty string when host is 127.0.0.1" do
      ENV["LLAMA_HOST"] = "127.0.0.1"
      ENV["LLAMA_PORT"] = "8080"
      expect(agent.send(:status_server_segment)).to eq("")
    end

    it "returns the server segment when host is not localhost" do
      ENV["LLAMA_HOST"] = "192.168.1.29"
      ENV["LLAMA_PORT"] = "8080"
      expect(agent.send(:status_server_segment)).to eq("server=192.168.1.29:8080")
    end
  end

  describe "thinking spinner" do
    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      ENV["SAMAGOTCHI_THINKING_UI"] = "spinner"
      ENV.delete("SAMAGOTCHI_THINKING_PREVIEW_LINES")
    end

    it "renders spinner progress in TTY mode while streaming" do
      allow(client).to receive(:complete) do |_prompt, **kwargs|
        on_chunk = kwargs[:on_chunk]
        on_chunk&.call(content: "a", payload: { "content" => "a" })
        on_chunk&.call(content: "b", payload: { "content" => "b" })
        "done"
      end
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:thinking_spinner_enabled?).and_return(true)
      output = run_and_render(agent, prompt: "hi")
      expect(output).to match(/thinking\.\.\..*done/m)
    end

    it "renders a tail preview line while streaming" do
      allow(client).to receive(:complete) do |_prompt, **kwargs|
        on_chunk = kwargs[:on_chunk]
        on_chunk&.call(content: "hello", payload: { "content" => "hello" })
        on_chunk&.call(content: " world", payload: { "content" => " world" })
        "done"
      end
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:thinking_spinner_enabled?).and_return(true)
      allow(agent).to receive(:color_output?).and_return(false)
      allow(agent).to receive(:thinking_render_min_interval).and_return(0.0)
      output = run_and_render(agent, prompt: "hi")
      expect(output).to match(/model> .*hello world.*done/m)
    end

    it "renders the preview line in color when color output is enabled" do
      allow(client).to receive(:complete) do |_prompt, **kwargs|
        on_chunk = kwargs[:on_chunk]
        on_chunk&.call(content: "hello", payload: { "content" => "hello" })
        "done"
      end
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:thinking_spinner_enabled?).and_return(true)
      allow(agent).to receive(:color_output?).and_return(true)
      allow(agent).to receive(:thinking_render_min_interval).and_return(0.0)
      output = run_and_render(agent, prompt: "hi")
      expect(output).to match(/#{ansi_escape}model> … hello#{ansi_escape}.*done/m)
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

    it "captures preview text in assist mode" do
      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(agent).to receive(:thinking_spinner_enabled?).and_return(true)
      allow(agent).to receive(:color_output?).and_return(false)

      agent.send(:handle_stream_event, type: :generation_started)
      agent.send(:handle_stream_event, type: :generation_chunk, content: "preview me")

      expect(agent.send(:thinking_tail_preview_line)).not_to be_nil
      expect(agent.send(:thinking_tail_preview_line)).to include("preview me")
    end

    it "does not render spinner in non-TTY mode" do
      allow(client).to receive(:complete) do |_prompt, **kwargs|
        on_chunk = kwargs[:on_chunk]
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

    it "prefers server usage telemetry over estimated CONTEXT_STATUS in status output" do
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

      agent.send(:handle_stream_event, type: :generation_started)
      agent.send(
        :handle_stream_event,
        type: :generation_chunk,
        content: "chunk",
        payload: {
          "timings" => { "prompt_n" => 120, "predicted_n" => 30 },
          "n_ctx" => 1000
        }
      )

      status = agent.send(:build_status_line, scope: :spinner)
      expect(status).to include("ctx=15.0%")
      expect(status).to include("p=120")
      expect(status).to include("c=30")
      expect(status).to include("t=150")
      expect(status).not_to include("20plus")
    end

    it "falls back to estimated CONTEXT_STATUS when server usage is unavailable" do
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

      agent.send(:handle_stream_event, type: :generation_started)
      agent.send(:handle_stream_event, type: :generation_chunk, content: "chunk", payload: { "content" => "chunk" })

      status = agent.send(:build_status_line, scope: :spinner)
      expect(status).to include("ctx=35.2% (20plus)")
      expect(status).not_to include("p=")
      expect(status).not_to include("c=")
      expect(status).not_to include("t=")
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
      responses = Array.new(100, looping_call) + ["finished"]

      allow(client).to receive(:complete) { |_prompt| responses.shift }
      allow(Reline).to receive(:readmultiline).and_return("run", nil)
      allow(Reline).to receive(:readline).and_return("yes")

      agent = described_class.new(mode: "assist", client: client)

      expect { agent.run }
        .to output(/iteration limit reached.*finished/m).to_stdout
    end

    it "keeps /continue working for backward compatibility" do
      responses = Array.new(100, looping_call) + ["finished"]

      allow(client).to receive(:complete) { |_prompt| responses.shift }
      allow(Reline).to receive(:readmultiline).and_return("run", nil)
      allow(Reline).to receive(:readline).and_return("/continue")

      agent = described_class.new(mode: "assist", client: client)

      expect { agent.run }
        .to output(/iteration limit reached.*finished/m).to_stdout
    end

    it "supports /model in assist mode and applies it to subsequent requests" do
      captured_kwargs = nil
      allow(client).to receive(:complete) do |_prompt, **kwargs|
        captured_kwargs = kwargs
        "done"
      end
      allow(Reline).to receive(:readmultiline).and_return("/model Qwen3-14B-Instruct", "run", nil)

      agent = described_class.new(mode: "assist", client: client)

      expect { agent.run }
        .to output(/runtime model set to Qwen3-14B-Instruct \(profile=qwen36\).*done/m).to_stdout
      expect(captured_kwargs[:model]).to eq("Qwen3-14B-Instruct")
    end

    it "shows effective /model value without calling the model" do
      ENV["SAMAGOTCHI_MODEL"] = "env-model"
      allow(Reline).to receive(:readmultiline).and_return("/model", nil)
      expect(client).not_to receive(:complete)

      agent = described_class.new(mode: "assist", client: client)

      expect { agent.run }
        .to output(/runtime model: env-model/).to_stdout
    end

    it "lists discovered models without invoking completion" do
      allow(Reline).to receive(:readmultiline).and_return("/models", nil)
      allow(client).to receive(:list_models).and_return([
        { "id" => "ggml-org/gemma-4-26b-a4b-it-GGUF:Q4_K_M", "status" => "loaded" },
        { "id" => "Qwen3-14B-Instruct", "status" => "unloaded" }
      ])
      expect(client).not_to receive(:complete)

      agent = described_class.new(mode: "assist", client: client)

      expect { agent.run }
        .to output(/ggml-org\/gemma-4-26b-a4b-it-GGUF:Q4_K_M \(loaded\).*Qwen3-14B-Instruct \(unloaded\)/m).to_stdout
    end

    it "rejects new input until the interrupted turn is resumed" do
      allow(client).to receive(:complete)
        .and_return(*Array.new(100, looping_call), "finished")
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
        prompts.length <= 100 ? looping_call : "fresh answer"
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
        prompts.length <= 100 ? looping_call : "fresh answer"
      end
      old_request = "OLD_BROAD_REQUEST_WITH_REASON"
      next_request = "NEW_NARROW_REQUEST_WITH_REASON"
      allow(Reline).to receive(:readmultiline).and_return(old_request, next_request, nil)
      allow(Reline).to receive(:readline).and_return("no, this is too risky")

      agent = described_class.new(mode: "assist", client: client)

      expect { agent.run }
        .to output(/noted your explanation.*fresh answer/m).to_stdout
      expect(prompts.last).to include("I chose not to continue the interrupted turn because: this is too risky")
      expect(prompts.last).to include("Interrupted turn summary:")
      expect(prompts.last).to include(old_request)
      expect(prompts.last).to include("Please keep the original prompt context")
      expect(prompts.last).to include(next_request)
    end

    it "preserves prior user context while summarizing interrupted turns" do
      prompts = []
      responses = ["anchor response"] + Array.new(100, looping_call) + ["fresh answer"]
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        responses.shift
      end
      anchor_request = "INITIAL_PROMPT_ANCHOR_UNIQUE"
      interrupted_request = "INTERRUPTED_REQUEST_UNIQUE"
      next_request = "FOLLOWUP_REQUEST_UNIQUE"
      allow(Reline).to receive(:readmultiline).and_return(anchor_request, interrupted_request, next_request, nil)
      allow(Reline).to receive(:readline).and_return("no, stay in plan mode")

      agent = described_class.new(mode: "assist", client: client)

      expect { agent.run }
        .to output(/anchor response.*iteration limit reached.*noted your explanation.*fresh answer/m).to_stdout
      expect(prompts.last).to include(anchor_request)
      expect(prompts.last).to include(interrupted_request)
      expect(prompts.last).to include("I chose not to continue the interrupted turn because: stay in plan mode")
      expect(prompts.last).to include("Interrupted turn summary:")
      expect(prompts.last).to include("Please keep the original prompt context")
      expect(prompts.last).to include(next_request)
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

      project_memories_dir = File.join(tmpdir, "memories")
      FileUtils.mkdir_p(project_memories_dir)
      stub_const("Samagotchi::Tools::PROJECT_MEMORIES_DIR", project_memories_dir)
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
      File.write("lib/samagotchi/terminal_ui.rb", "# test")

      agent = described_class.new(mode: "assist", prompt: "hi", client: client)
      allow(Reline).to receive(:line_buffer).and_return("@lib/sama")

      candidates = agent.send(:assist_path_completion_candidates, "@lib/sama")

      expect(candidates).to include("@lib/samagotchi/")
    end

    it "completes when @token appears later in the line" do
      FileUtils.mkdir_p("lib/samagotchi")
      File.write("lib/samagotchi/terminal_ui.rb", "# test")

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

  describe "Profile-aware tool declarations" do
    it "uses Gemma tool call hint for Gemma profile" do
      gemma_profile = Samagotchi::ModelProfile.gemma4
      agent = described_class.new(mode: "assist", client: client, profile: gemma_profile)

      hint = agent.send(:tool_call_hint)
      expect(hint).to include("<|tool_call>call:")
    end

    it "uses Qwen tool call hint for Qwen profile" do
      qwen_profile = Samagotchi::ModelProfile.qwen36
      agent = described_class.new(mode: "assist", client: client, profile: qwen_profile)

      hint = agent.send(:tool_call_hint)
      expect(hint).to include("<tool_call>")
      expect(hint).to include("<function=")
      expect(hint).to include("<parameter=")
    end
  end

  describe "#shell_bang_command?" do
    let(:agent) { described_class.new(mode: "assist", prompt: "hi") }

    it "returns true for !ls" do
      expect(agent.send(:shell_bang_command?, "!ls")).to be(true)
    end

    it "returns true for !ruby -e 'puts 1'" do
      expect(agent.send(:shell_bang_command?, "!ruby -e 'puts 1'")).to be(true)
    end

    it "returns true for ! with leading space" do
      expect(agent.send(:shell_bang_command?, "! ls")).to be(true)
    end

    it "returns false for ! alone" do
      expect(agent.send(:shell_bang_command?, "!")).to be(false)
    end

    it "returns false for normal input" do
      expect(agent.send(:shell_bang_command?, "hello world")).to be(false)
    end

    it "returns false for ! at end of line" do
      expect(agent.send(:shell_bang_command?, "hello !")).to be(false)
    end

    it "returns false for empty string" do
      expect(agent.send(:shell_bang_command?, "")).to be(false)
    end
  end

  describe "#exit_command?" do
    let(:agent) { described_class.new(mode: "assist", prompt: "hi") }

    it "returns true for 'exit'" do
      expect(agent.send(:exit_command?, "exit")).to be(true)
    end

    it "returns true for '/exit'" do
      expect(agent.send(:exit_command?, "/exit")).to be(true)
    end

    it "is case-insensitive" do
      expect(agent.send(:exit_command?, "EXIT")).to be(true)
      expect(agent.send(:exit_command?, "/EXIT")).to be(true)
      expect(agent.send(:exit_command?, "Exit")).to be(true)
    end

    it "ignores surrounding whitespace" do
      expect(agent.send(:exit_command?, " exit ")).to be(true)
    end

    it "returns false for similar but different input" do
      expect(agent.send(:exit_command?, "exit now")).to be(false)
      expect(agent.send(:exit_command?, "exit!")).to be(false)
      expect(agent.send(:exit_command?, "no exit")).to be(false)
      expect(agent.send(:exit_command?, "xit")).to be(false)
    end
  end

  describe "#assist_loop exits with session id" do
    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      ENV.delete("SAMAGOTCHI_SKIP_AGENT_MD")
      allow(client).to receive(:complete).and_return("done")
    end

    it "prints the session id on exit" do
      agent = described_class.new(mode: "assist", client: client)
      agent.instance_variable_set(:@resume_session, nil)
      # Stub Reline to return nil (exit) immediately
      allow(Reline).to receive(:readmultiline).and_return(nil)
      session = Samagotchi::Session.new_session(
        mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd
      )
      messages = [{ role: "system", content: agent.send(:assist_system_prompt) }]
      expect { agent.send(:assist_loop, session: session, messages: messages) }
        .to output(/Session: [0-9a-f-]+/).to_stdout
    end
  end

  describe "#queue_default_input" do
    around do |example|
      original_env = ENV.fetch("SAMAGOTCHI_DEFAULT_INPUT", nil)

      begin
        ENV.delete("SAMAGOTCHI_DEFAULT_INPUT")
        example.run
      ensure
        if original_env.nil?
          ENV.delete("SAMAGOTCHI_DEFAULT_INPUT")
        else
          ENV["SAMAGOTCHI_DEFAULT_INPUT"] = original_env
        end
      end
    end

    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      ENV.delete("SAMAGOTCHI_SKIP_AGENT_MD")
    end

    it "queues prefill when env is set, no resume, and no --no-default-input" do
      ENV["SAMAGOTCHI_DEFAULT_INPUT"] = "Hey Chi, "
      agent = described_class.new(mode: "assist", client: client)
      agent.instance_variable_set(:@resume_session, nil)
      expect(agent).to receive(:queue_input_prefill).with("Hey Chi, ")
      agent.send(:queue_default_input)
    end

    it "does not queue when --no-default-input is true" do
      ENV["SAMAGOTCHI_DEFAULT_INPUT"] = "Hey Chi, "
      agent = described_class.new(mode: "assist", client: client, no_default_input: true)
      expect(agent).not_to receive(:queue_input_prefill)
      agent.send(:queue_default_input)
    end

    it "does not queue when resuming a session" do
      ENV["SAMAGOTCHI_DEFAULT_INPUT"] = "Hey Chi, "
      agent = described_class.new(mode: "assist", client: client)
      agent.instance_variable_set(:@resume_session, OpenStruct.new(id: "abc-123"))
      expect(agent).not_to receive(:queue_input_prefill)
      agent.send(:queue_default_input)
    end

    it "does not queue when env is not set" do
      ENV.delete("SAMAGOTCHI_DEFAULT_INPUT")
      agent = described_class.new(mode: "assist", client: client)
      expect(agent).not_to receive(:queue_input_prefill)
      agent.send(:queue_default_input)
    end

    it "does not queue when env is blank" do
      ENV["SAMAGOTCHI_DEFAULT_INPUT"] = "   "
      agent = described_class.new(mode: "assist", client: client)
      expect(agent).not_to receive(:queue_input_prefill)
      agent.send(:queue_default_input)
    end
  end
end
