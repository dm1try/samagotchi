# frozen_string_literal: true

require "samagotchi/terminal_ui"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "support/test_kernel"

require_relative "support/recording_surface"

RSpec.describe Samagotchi::TerminalUI do
  let(:client) { test_client }
  let(:ansi_escape) { /\e\[[0-9;]+m/ }

  def repl_session
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd)
  end

  # Run one interactive REPL turn (Engine#run_turn, rendered by the UI's
  # EventRenderer), capturing stdout.
  def run_and_render(agent, prompt:)
    original = $stdout
    buffer = StringIO.new
    $stdout = buffer
    begin
      agent.run_engine_turn(repl_session, prompt)
    ensure
      $stdout = original
    end
    buffer.string
  end

  around do |example|
    original_thinking_mode = ENV["SAMAGOTCHI_THINKING_LEVEL"]
    original_skip_agent_md = ENV["SAMAGOTCHI_SKIP_AGENT_MD"]
    original_history_file = ENV["SAMAGOTCHI_HISTORY_FILE"]
    original_xdg_state_home = ENV["XDG_STATE_HOME"]
    original_status_line = ENV["SAMAGOTCHI_STATUS_LINE"]
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    original_columns = ENV["COLUMNS"]
    original_default_input = ENV["SAMAGOTCHI_DEFAULT_INPUT"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    ENV.delete("SAMAGOTCHI_DEFAULT_INPUT")
    example.run
    ENV["SAMAGOTCHI_THINKING_LEVEL"] = original_thinking_mode
    ENV["SAMAGOTCHI_SKIP_AGENT_MD"] = original_skip_agent_md
    ENV["SAMAGOTCHI_HISTORY_FILE"] = original_history_file
    ENV["XDG_STATE_HOME"] = original_xdg_state_home
    ENV["SAMAGOTCHI_STATUS_LINE"] = original_status_line
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
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
      # Isolate from the developer's real ~/.config/samagotchi/config.yml
      # `memories:` baseline. Engine#preload_memory_list merges that baseline
      # into every prompt + sticky status line, so without this the personal
      # baseline (e.g. user_preferences) leaks into the assertions.
      # Mirrors spec/engine_spec.rb:65.
      allow(Samagotchi::ConfigFile).to receive(:preloaded_memories).and_return([])
      ENV.delete("SAMAGOTCHI_SKIP_AGENT_MD")
      # The prompt entrypoint runs one turn then drops into the REPL; stub
      # Reline to exit immediately so .run returns in tests.
      allow(Reline).to receive(:readmultiline).and_return(nil)
    end

    it "sends the prompt to the kernel and prints the response" do
      allow(client).to receive(:complete).and_return("file1.rb\
file\
file2.rb")
      agent = described_class.new(prompt: "list files", client: client)
      expect { agent.run }.to output(/file1.rb/).to_stdout
    end

    it "builds its KernelLoop with the client and options" do
      result = Samagotchi::LLM::ModelResult.new(
        text: "ok",
        conversation: [],
        exhausted: false,
        pending_tool_calls: false,
        tool_activity: []
      )
      kernel = test_kernel(client: client)
      allow(kernel).to receive(:run).and_return(result)
      expect(Samagotchi::KernelLoop).to receive(:new)
        .with(client: client, profile: nil, reminder_store: instance_of(Samagotchi::ReminderStore))
        .and_return(kernel)

      agent = described_class.new(prompt: "hi", client: client)
      expect { agent.run }.to output(/ok/).to_stdout
    end

    it "runs the prompt once then enters the interactive loop (exits on first read)" do
      call_count = 0
      allow(client).to receive(:complete) do
        call_count += 1
        "done"
      end
      agent = described_class.new(prompt: "hello", client: client)
      agent.run
      expect(call_count).to eq(1)   # one prompt turn; REPL exits on first read
    end

    it "forwards no_interrupt to the engine, which runs every turn with 1000 iterations" do
      agent = described_class.new(prompt: "test", no_interrupt: true)
      engine = agent.instance_variable_get(:@engine)
      expect(engine.instance_variable_get(:@no_interrupt)).to be true
    end

    it "prints concise tool activity lines in normal output" do
      responses = [
        %(<|tool_call>call:read{path: "README.md"}<tool_call|>),
        "done"
      ]
      allow(client).to receive(:complete).and_return(*responses)

      agent = described_class.new(prompt: "read readme", client: client)
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
      agent = described_class.new(prompt: "read readme", client: client)
      allow_any_instance_of(Samagotchi::TerminalUI::AttachedView).to receive(:color_output?).and_return(true)
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
      agent = described_class.new(prompt: "read readme", client: client)
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
      agent = described_class.new(prompt: "read readme", client: client)
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
      agent = described_class.new(prompt: "hi", client: client)
      output = run_and_render(agent, prompt: "hi")
      expect(output).to match(/\A(?!.*tool> reading memory).*ok/m)
    end

    it "prints unified sticky status line with memory segment when memory files were loaded" do
      responses = [
        %(<|tool_call>call:read{path: "memories/refactoring_backlog.md"}<tool_call|>),
        "done"
      ]
      allow(client).to receive(:complete).and_return(*responses)
      agent = described_class.new(prompt: "read memory", client: client)
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
      agent = described_class.new(prompt: "hi", client: client)
      agent.run
      expect(received_prompt).to include("friendly name for the Samagotchi assistant harness")
    end

    it "injects project and system memory indexes into the system prompt" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("", scope: "project").and_return("- **project**: test notes")
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("", scope: "system").and_return("- **system**: shared notes")
      agent = described_class.new(prompt: "hi", client: client)
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
      agent = described_class.new(prompt: "hi", client: client, memories: ["foo"])
      agent.run
      expect(received_prompt).to include("this memory is required by the user in the current context: memory name: foo")
      expect(received_prompt).to include("foo body")
    end

    it "names a preloaded --memory entry in the status row" do
      allow(client).to receive(:complete).and_return("ok")
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("foo", scope: nil).and_return("foo body")
      agent = described_class.new(prompt: "hi", client: client, memories: ["foo"])
      run_and_render(agent, prompt: "hi")
      expect(agent.instance_variable_get(:@status_row).rows(200).join("\n")).to include("mem: foo")
    end

    it "keeps a --mute memory out of the prompt and names it in the status row" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      index = "- **foo** · system · 2026-09-01 · 10 — foo\n- **bar** · system · 2026-09-01 · 10 — bar\n"
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("", scope: "system").and_return(index)
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("foo", scope: nil).and_return("foo body")
      agent = described_class.new(prompt: "hi", client: client, memories: ["foo"], muted_memories: ["system/bar.md"])
      run_and_render(agent, prompt: "hi")

      expect(received_prompt).to include("**foo**")
      expect(received_prompt).not_to include("**bar**")
      expect(agent.instance_variable_get(:@status_row).rows(200).join("\n")).to include("mem: foo | muted: bar")
      expect(agent.engine.muted_memory_names).to eq(["bar"])
    end

    it "records the --memory and --mute lists on a new REPL session" do
      allow(client).to receive(:complete).and_return("ok")
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("foo", scope: nil).and_return("foo body")
      agent = described_class.new(prompt: "hi", client: client, non_interactive: true,
                                  memories: ["foo"], muted_memories: ["system/bar.md"])
      agent.run

      session = agent.engine.session
      expect(session.preloaded_memory_names).to eq(["foo"])
      expect(session.muted_memory_names).to eq(["system/bar.md"])
    end

    it "merges a resumed session's stored --memory and --mute lists with the flags" do
      stored = Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd,
                                               preloaded_memory_names: ["foo"], muted_memory_names: ["bar"])
      stored.save
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      agent = described_class.new(client: client, session_id: stored.id, memories: ["baz"], muted_memories: ["bar", "qux"])

      expect(agent.instance_variable_get(:@requested_memories)).to eq(%w[foo baz])
      expect(agent.engine.muted_memory_names).to eq(%w[bar qux])
    ensure
      agent&.instance_variable_get(:@owner_lock)&.release
    end

    it "resolves scope-prefixed --memory entries" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("foo", scope: "project").and_return("foo body")
      agent = described_class.new(prompt: "hi", client: client, memories: ["project/foo"])
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
      agent = described_class.new(prompt: "hi", client: client, memories: ["missing"])
      expect { agent.run }.not_to raise_error
      # A missing entry is skipped (see Engine#explicit_memory_section), so its
      # name/body must never leak into the prompt. Pinned to the actual marker
      # rather than the weaker "required" text for a precise skip assertion.
      expect(received_prompt).not_to include("memory name: missing")
    end

    it "does not inject an explicit memory section when no --memory flags are given" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      agent = described_class.new(prompt: "hi", client: client)
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
      agent = described_class.new(prompt: "hi", client: client)
      agent.run
      # All tool declaration string values must use <|"|> delimiters
      expect(received_prompt).to include('description:<|"|>Run any shell command')
      expect(received_prompt).to include('description:<|"|>Read a file from disk. Large files may be truncated to a head+tail preview with metadata. Optionally pass start_line and end_line (1-based, inclusive) to read only a specific line range. An image file (png, jpeg, gif, webp) comes back as the picture itself: read it to see it.<|"|>')
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
      agent = described_class.new(prompt: "hi", client: client)
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

      agent = described_class.new(prompt: "hi", client: client)
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

      agent = described_class.new(prompt: "hi", client: client)
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

      agent = described_class.new(prompt: "hi", client: client)
      agent.run

      expect(received_prompt).to include("Small-context retrieval protocol:")
      expect(received_prompt).to include("If the user provides file:line")
      expect(received_prompt).to include("src/app.rb:130")
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

      agent = described_class.new(prompt: "hi", client: client)
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

      agent = described_class.new(prompt: "hi", client: client)
      agent.run

      expect(received_prompt).to include("Current working directory:")
      expect(received_prompt).to include(Dir.pwd)
      expect(received_prompt).to include("Home directory: #{Dir.home} (write it as ~ or $HOME in commands and paths)")
    end

    it "injects the current session id as context" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")

      agent = described_class.new(prompt: "hi", client: client)
      out = StringIO.new
      original_stdout = $stdout
      begin
        $stdout = out
        agent.run
      ensure
        $stdout = original_stdout
      end

      id = out.string[/Session: (\S+)/, 1]
      expect(id).not_to be_nil
      expect(received_prompt).to include("Current session id: #{id}")
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

      agent = described_class.new(prompt: "hi", client: client)
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

      agent = described_class.new(prompt: "refactor this", client: client)
      agent.run

      expect(seen.length).to eq(1) # one prompt turn only
      expect(seen.first).to include("refactor this") # prompt was fed to the model
      expect(Reline).to have_received(:readmultiline).at_least(:once) # REPL was entered
    end

    # Scenario 2: -p "x" --non-interactive runs one turn then exits (no REPL).
    it "runs the -p prompt once and exits without entering the REPL when --non-interactive" do
      seen = []
      allow(client).to receive(:complete) { |p| seen << p; "done" }
      agent = described_class.new(prompt: "refactor this", client: client, non_interactive: true)

      expect(Reline).not_to receive(:readmultiline) # never enters the REPL
      agent.run

      expect(seen.length).to eq(1)
      expect(seen.first).to include("refactor this")
    end

    # An empty answer (retries used up) is a failure: a line on stderr, exit 1,
    # nothing on stdout that could pass for an answer.
    it "says so on stderr and exits 1 when the -p --non-interactive turn ends with an empty answer" do
      allow(client).to receive(:complete).and_return("")
      agent = described_class.new(prompt: "hi", client: client, non_interactive: true)

      status = nil
      expect do
        expect { agent.run }.to raise_error(SystemExit) { |e| status = e.status }
      end.to output("chi: the model gave an empty answer\n").to_stderr
      expect(status).to eq(1)
    end

    it "exits normally when the -p --non-interactive turn answers" do
      allow(client).to receive(:complete).and_return("done")
      agent = described_class.new(prompt: "hi", client: client, non_interactive: true)
      expect { agent.run }.not_to output.to_stderr
    end

    # Scenario 7: --non-interactive with no -p is a harmless no-op exit.
    it "exits without building a session or entering the REPL for --non-interactive with no prompt" do
      expect(client).not_to receive(:complete)
      expect(Reline).not_to receive(:readmultiline)
      agent = described_class.new(client: client, non_interactive: true)
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

      agent = described_class.new(prompt: "next step", client: client)
      agent.instance_variable_set(:@resume_session, resumed)
      agent.run

      expect(seen.length).to eq(1) # one turn on the resumed session
      expect(seen.first).to include("next step")
      expect(seen.first).to include("prior prompt") # prior history present in context
    end

    describe "Engine#shutdown as it leaves (the plugins' services stop)" do
      def shut_down?(agent)
        engine = agent.engine
        engine.instance_variable_get(:@shut_down)
      end

      it "shuts down after an early return (--non-interactive with no prompt)" do
        agent = described_class.new(client: client, non_interactive: true)
        agent.run
        expect(shut_down?(agent)).to be(true)
      end

      it "shuts down after a -p --non-interactive turn" do
        allow(client).to receive(:complete).and_return("done")
        agent = described_class.new(prompt: "hi", client: client, non_interactive: true)
        agent.run
        expect(shut_down?(agent)).to be(true)
      end

      it "shuts down when the REPL ends, and when it raises" do
        allow(Reline).to receive(:readmultiline).and_return(nil)
        agent = described_class.new(client: client)
        agent.run
        expect(shut_down?(agent)).to be(true)

        crashing = described_class.new(client: client)
        allow(crashing).to receive(:assist_loop).and_raise(RuntimeError, "boom")
        expect { crashing.run }.to raise_error(RuntimeError, "boom")
        expect(shut_down?(crashing)).to be(true)
      end
    end

    # Scenario 4: a plain interactive session (no prompt) drops into the REPL.
    it "drops into the REPL for a plain interactive session (no prompt)" do
      allow(Reline).to receive(:readmultiline).and_return("hello", nil)
      allow(client).to receive(:complete).and_return("hi there")

      agent = described_class.new(client: client)
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

      agent = described_class.new(prompt: "first turn", client: client)
      agent.run

      expect(responses.length).to eq(2)
      expect(responses.first).to include("first turn")
      expect(responses.last).to include("follow-up")
    end

    describe "no-op exit for --non-interactive with no prompt" do
      it "builds nothing and prints no banner" do
        expect {
          described_class.new(client: client, non_interactive: true).run
        }.not_to output(/Session:|Resumed session:/).to_stdout
      end
    end
  end

  describe "Thinking Mode (control token injection)" do
    let(:base_prompt) { "Base Prompt" }

    before do
      # Clear ENV to ensure tests are isolated from the environment
      ENV.delete("SAMAGOTCHI_THINKING_LEVEL")
      ENV.delete("SAMAGOTCHI_SKIP_AGENT_MD")
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    end

    it "includes the <|think|> token by default" do
      agent = described_class.new(prompt: "hi", client: client)
      allow(client).to receive(:complete) do |prompt|
        expect(prompt).to include("<|think|>")
        "ok"
      end
      agent.run
    end

    it "omits the <|think|> token with thinking off (SAMAGOTCHI_THINKING_LEVEL=off)" do
      ENV["SAMAGOTCHI_THINKING_LEVEL"] = "off"
      agent = described_class.new(prompt: "hi", client: client)
      allow(client).to receive(:complete) do |prompt|
        expect(prompt).not_to include("<|think|>")
        "ok"
      end
      agent.run
    end

    it "does not include the Gemma think token for Qwen profiles" do
      agent = described_class.new(
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

  # The REPL's turn view is the attached TUI's: AttachedView draws the
  # activity row and StatusRow the status row (their specs pin the rows);
  # these check the REPL feeds them.
  describe "turn view" do
    before { allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("") }

    # A memory read as the Engine hands it to the REPL: its tool_call_started,
    # then the used_memories_updated it follows it with.
    def memory_read_event(agent, event)
      agent.engine.send(:emit_event, agent.method(:handle_stream_event), event)
    end

    let(:surface) { RecordingSurface.new }
    let(:agent) { described_class.new(prompt: "hi", client: client, surface: surface, spinner_tick_interval: nil) }

    # The REPL draws the row at each read and as a turn starts.
    before { agent.send(:refresh_status_row) }

    it "shows the running tool in the activity row and a memory it read in the status row" do
      agent.send(:handle_stream_event, type: :generation_started)
      memory_read_event(agent, type: :tool_call_started, tool: "memory_read", call: { name: "memory_read", content: "notes" })

      expect(surface.slots[:activity].first).to include("running memory_read…")
      expect(surface.slots[:status]).to eq(["status> model=#{agent.instance_variable_get(:@effective_model_name)} | mem: notes"])
    end

    it "keeps the session's memories in the status row after the generation and the turn end" do
      agent.send(:handle_stream_event, type: :generation_started)
      memory_read_event(agent, type: :tool_call_started, tool: "read", call: { name: "read", content: "memories/refactoring_backlog.md" })
      agent.send(:handle_stream_event, type: :generation_completed)
      agent.send(:refresh_status_row)

      expect(surface.slots[:status].first).to include("mem: refactoring_backlog")
    end

    it "shows the kernel's context estimate in the status row" do
      agent.send(:handle_stream_event, type: :context_status, usage: { estimated_pct: 12.34 }, bucket: "under20")

      expect(surface.slots[:status].first).to include("ctx=12.3% (under20)")
    end

    it "shows the model the server said it served" do
      agent.send(:handle_stream_event, type: :generation_completed, served_model: "ornith-1.5", requested_model: "m1")

      expect(surface.slots[:status].first).to include("model=ornith-1.5 (served; asked ")
    end

    describe "Ctrl-C with a prompt open" do
      let(:agent) { described_class.new(prompt: "hi", client: client) }
      let(:seam) { Samagotchi::TerminalUI::RelineSeam }

      after { seam.interrupt_handler = nil }

      it "cancels the running turn and keeps the prompt" do
        controller = Samagotchi::Client::CancellationController.new
        agent.instance_variable_set(:@active_cancel_controller, controller)

        agent.send(:with_interrupt_arbiter) do
          expect(seam.interrupt_handler.call).to be(true)
        end

        expect(controller.reason).to eq(:ctrl_c)
      end

      it "leaves Ctrl-C to Reline with no turn running, and puts the handler back after" do
        seam.interrupt_handler = previous = -> { :previous }

        agent.send(:with_interrupt_arbiter) do
          expect(seam.interrupt_handler.call).to be(false)
        end

        expect(seam.interrupt_handler).to be(previous)
      end
    end

    it "prints idle status before the next assist prompt when enabled" do
      allow(client).to receive(:complete).and_return("done")
      allow(Reline).to receive(:readmultiline).and_return("hello", nil)

      agent = described_class.new(client: client)
      allow(agent).to receive(:color_output?).and_return(false)

      expect { agent.run }.to output(/status> model=.*done/m).to_stdout
    end

    it "does not print idle status when SAMAGOTCHI_STATUS_LINE is off" do
      ENV["SAMAGOTCHI_STATUS_LINE"] = "off"
      allow(client).to receive(:complete).and_return("done")
      allow(Reline).to receive(:readmultiline).and_return("hello", nil)

      agent = described_class.new(client: client)
      allow(agent).to receive(:color_output?).and_return(false)

      expect { agent.run }.not_to output(/status> /).to_stdout
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
      original_xdg = ENV["XDG_CONFIG_HOME"]
      Dir.mktmpdir("samagotchi-empty") do |empty_cfg|
        begin
          ENV["XDG_CONFIG_HOME"] = empty_cfg
          Samagotchi::Config.reload!(cli_overrides: {}) rescue nil
          ENV["SAMAGOTCHI_HISTORY_FILE"] = File.join(tmpdir, "history.json")
          Dir.chdir(tmpdir)
          example.run
        ensure
          ENV["XDG_CONFIG_HOME"] = original_xdg
          Samagotchi::Config.reload!(cli_overrides: {}) rescue nil
          Dir.chdir(previous_dir) rescue nil
        end
      end
      FileUtils.rm_rf(tmpdir)
    end

    it "accepts yes and resumes an exhausted turn" do
      responses = Array.new(100, looping_call) + ["finished"]

      allow(client).to receive(:complete) { |_prompt| responses.shift }
      allow(Reline).to receive(:readmultiline).and_return("run", nil)
      allow(Reline).to receive(:readline).and_return("yes")

      agent = described_class.new(client: client)

      expect { agent.run }
        .to output(/iteration limit reached.*finished/m).to_stdout
    end

    it "keeps /continue working for backward compatibility" do
      responses = Array.new(100, looping_call) + ["finished"]

      allow(client).to receive(:complete) { |_prompt| responses.shift }
      allow(Reline).to receive(:readmultiline).and_return("run", nil)
      allow(Reline).to receive(:readline).and_return("/continue")

      agent = described_class.new(client: client)

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

      agent = described_class.new(client: client)

      expect { agent.run }
        .to output(/runtime model set to Qwen3-14B-Instruct \(profile=qwen36, name\).*done/m).to_stdout
      expect(captured_kwargs[:model]).to eq("Qwen3-14B-Instruct")
    end

    it "shows effective /model value without calling the model" do
      ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "env-model"
      allow(Reline).to receive(:readmultiline).and_return("/model", nil)
      expect(client).not_to receive(:complete)

      agent = described_class.new(client: client)

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

      agent = described_class.new(client: client)

      expect { agent.run }
        .to output(/ggml-org\/gemma-4-26b-a4b-it-GGUF:Q4_K_M \(loaded\).*Qwen3-14B-Instruct \(unloaded\)/m).to_stdout
    end

    it "rejects new input until the interrupted turn is resumed" do
      allow(client).to receive(:complete)
        .and_return(*Array.new(100, looping_call), "finished")
      allow(Reline).to receive(:readmultiline).and_return("run", nil)
      allow(Reline).to receive(:readline).and_return("new request", "yes")

      agent = described_class.new(client: client)

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

      agent = described_class.new(client: client)

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

      agent = described_class.new(client: client)

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

      agent = described_class.new(client: client)

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

      agent = described_class.new(client: client)

      expect { agent.run }.to output(/done/).to_stdout
      expect(received_prompt).to include("line one\nline two")
    end

    it "restores the submitted prompt after retry exhaustion" do
      allow(client).to receive(:complete).and_raise(
        Samagotchi::Client::RetryExhausted.new(attempts: 6, last_error: Errno::ECONNREFUSED.new)
      )
      allow(Reline).to receive(:readmultiline).and_return("retry me", nil)

      agent = described_class.new(client: client)
      allow(agent).to receive(:piped_input?).and_return(false) # typed at a terminal
      expect(agent).to receive(:queue_input_prefill).with("retry me").and_call_original
      expect { agent.run }.to output(/✕ turn failed: network error after 6 attempts \(host llama.cpp: Errno::ECONNREFUSED\) · .*\n  prompt restored for retry/).to_stdout
    end

    it "injects queued prefill text into the next multiline input" do
      agent = described_class.new(prompt: "hi", client: client)
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
      allow(Samagotchi::MemoryBundle::SystemBundle).to receive(:skip?).and_return(true)
      ENV.delete("SAMAGOTCHI_SKIP_AGENT_MD")
      allow(Samagotchi::MemoryPaths).to receive(:system_dir).and_return(system_memories_dir)

      project_memories_dir = File.join(tmpdir, "memories")
      FileUtils.mkdir_p(project_memories_dir)
      allow(Samagotchi::MemoryPaths).to receive(:project_dir).and_return(project_memories_dir)
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

      agent = described_class.new(prompt: "hi", client: client)
      allow(Reline).to receive(:line_buffer).and_return("@lib/sama")

      candidates = agent.send(:assist_path_completion_candidates, "@lib/sama")

      expect(candidates).to include("@lib/samagotchi/")
    end

    it "completes when @token appears later in the line" do
      FileUtils.mkdir_p("lib/samagotchi")
      File.write("lib/samagotchi/terminal_ui.rb", "# test")

      agent = described_class.new(prompt: "hi", client: client)
      allow(Reline).to receive(:line_buffer).and_return("please open @lib/sama")

      candidates = agent.send(:assist_path_completion_candidates, "@lib/sama")

      expect(candidates).to include("@lib/samagotchi/")
    end

    it "completes project memories with # shorthand" do
      FileUtils.mkdir_p("memories")
      File.write("memories/release_notes.md", "# notes")

      agent = described_class.new(prompt: "hi", client: client)
      allow(Reline).to receive(:line_buffer).and_return("#rel")

      candidates = agent.send(:assist_path_completion_candidates, "#rel")

      expect(candidates).to include("#release_notes")
    end

    it "completes system memories with # shorthand" do
      File.write(File.join(system_memories_dir, "shared_notes.md"), "# notes")

      agent = described_class.new(prompt: "hi", client: client)
      allow(Reline).to receive(:line_buffer).and_return("#sha")

      candidates = agent.send(:assist_path_completion_candidates, "#sha")

      expect(candidates).to include("#shared_notes")
    end

    it "disambiguates duplicate memory names across scopes" do
      FileUtils.mkdir_p("memories")
      File.write("memories/notes.md", "# project")
      File.write(File.join(system_memories_dir, "notes.md"), "# system")

      agent = described_class.new(prompt: "hi", client: client)

      candidates = agent.send(:assist_path_completion_candidates, "#")

      expect(candidates).to include("#project/notes")
      expect(candidates).to include("#system/notes")
      expect(candidates).not_to include("#notes")
    end

    it "prioritizes project memories ahead of system memories in the # list" do
      FileUtils.mkdir_p("memories")
      File.write("memories/zebra.md", "# project")
      File.write(File.join(system_memories_dir, "alpha.md"), "# system")

      agent = described_class.new(prompt: "hi", client: client)

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

      agent = described_class.new(prompt: "hi", client: client)
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

      agent = described_class.new(prompt: "hi", client: client)
      value = agent.send(:read_input, awaiting_continue: false)

      expect(value).to eq("#feature_flags")
      expect(Reline.completion_proc).to be(original_proc)
      expect(Reline.autocompletion).to be(false)
    end

    it "does not enable path completion for continuation input" do
      agent = described_class.new(prompt: "hi", client: client)
      allow(Reline).to receive(:readline).and_return("yes")

      expect(agent).not_to receive(:with_scoped_at_path_completion)
      expect(agent.send(:read_input, awaiting_continue: true)).to eq("yes")
    end

    it "sends #name and #scope/name to the model as typed" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "done"
      end
      allow(Reline).to receive(:readmultiline).and_return("Please review #project/plan and #shared_notes for PR #1", nil)

      agent = described_class.new(client: client)

      expect { agent.run }.to output(/done/).to_stdout
      expect(received_prompt).to include("Please review #project/plan and #shared_notes for PR #1")
      expect(received_prompt).not_to include("memory \"")
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

      agent = described_class.new(client: client)
      agent.run

      expect(Reline::HISTORY.to_a).to include("older prompt", "latest prompt")
    end

    it "persists accepted prompts and keeps only the latest 100 entries" do
      seed_entries = (1..105).map { |idx| "prompt-#{idx}" }
      FileUtils.mkdir_p(File.dirname(history_file))
      File.write(history_file, JSON.pretty_generate(seed_entries))
      allow(Reline).to receive(:readmultiline).and_return("new prompt", nil)

      agent = described_class.new(client: client)
      agent.run

      persisted = JSON.parse(File.read(history_file))
      expect(persisted.length).to eq(100)
      expect(persisted.first).to eq("prompt-7")
      expect(persisted.last).to eq("new prompt")
    end

    it "does not persist continuation yes or no answers" do
      looping_call = %(<|tool_call>call:execute{command: "echo step"}<tool_call|>)
      responses = Array.new(10, looping_call) + ["finished", "fresh answer"]

      allow(client).to receive(:complete) { |_prompt| responses.shift }
      allow(Reline).to receive(:readmultiline).and_return("first request", "second request", nil)
      allow(Reline).to receive(:readline).and_return("no")

      agent = described_class.new(client: client)
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
      agent = described_class.new(client: client, profile: gemma_profile)

      hint = agent.engine.instance_variable_get(:@prompt_builder).send(:tool_call_hint)
      expect(hint).to include("<|tool_call>call:")
    end

    it "uses Qwen tool call hint for Qwen profile" do
      qwen_profile = Samagotchi::ModelProfile.qwen36
      agent = described_class.new(client: client, profile: qwen_profile)

      hint = agent.engine.instance_variable_get(:@prompt_builder).send(:tool_call_hint)
      expect(hint).to include("<tool_call>")
      expect(hint).to include("<function=")
      expect(hint).to include("<parameter=")
    end
  end

  describe "#assist_loop exits with session id" do
    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      ENV.delete("SAMAGOTCHI_SKIP_AGENT_MD")
      allow(client).to receive(:complete).and_return("done")
      # Nothing is sent: keep the session, for the resume line.
      allow(Samagotchi::SessionManager).to receive(:discard_empty?).and_return(false)
    end

    it "prints the session id on exit" do
      agent = described_class.new(client: client)
      agent.instance_variable_set(:@resume_session, nil)
      # Stub Reline to return nil (exit) immediately
      allow(Reline).to receive(:readmultiline).and_return(nil)
      session = Samagotchi::Session.new_session(
        mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd
      )
      messages = [{ role: "system", content: agent.engine.assist_system_prompt }]
      expect do
        agent.send(:assist_loop, session: session, messages: messages)
        agent.keep_after_exit(session)
      end.to output(/Continue session: chi --resume [0-9a-f-]+\n\z/).to_stdout
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
      ENV["SAMAGOTCHI_DEFAULT_INPUT"] = "Please "
      agent = described_class.new(client: client)
      agent.instance_variable_set(:@resume_session, nil)
      expect(agent).to receive(:queue_input_prefill).with("Please ")
      agent.send(:queue_default_input)
    end

    it "keeps the default input as given, its trailing space too" do
      ENV["SAMAGOTCHI_DEFAULT_INPUT"] = "Please "
      agent = described_class.new(client: client)
      agent.instance_variable_set(:@resume_session, nil)
      agent.send(:queue_default_input)
      expect(agent.send(:consume_input_prefill)).to eq("Please ")
    end

    it "queues no blank prefill" do
      agent = described_class.new(client: client)
      agent.send(:queue_input_prefill, "  \n")
      expect(agent.send(:consume_input_prefill)).to be_nil
    end

    it "does not queue when --no-default-input is true" do
      ENV["SAMAGOTCHI_DEFAULT_INPUT"] = "Please "
      agent = described_class.new(client: client, no_default_input: true)
      expect(agent).not_to receive(:queue_input_prefill)
      agent.send(:queue_default_input)
    end

    it "does not queue when resuming a session" do
      ENV["SAMAGOTCHI_DEFAULT_INPUT"] = "Please "
      agent = described_class.new(client: client)
      agent.instance_variable_set(:@resume_session, double("session", id: "abc-123"))
      expect(agent).not_to receive(:queue_input_prefill)
      agent.send(:queue_default_input)
    end

    it "does not queue when env is not set" do
      ENV.delete("SAMAGOTCHI_DEFAULT_INPUT")
      agent = described_class.new(client: client)
      expect(agent).not_to receive(:queue_input_prefill)
      agent.send(:queue_default_input)
    end

    it "does not queue when env is blank" do
      ENV["SAMAGOTCHI_DEFAULT_INPUT"] = "   "
      agent = described_class.new(client: client)
      expect(agent).not_to receive(:queue_input_prefill)
      agent.send(:queue_default_input)
    end
  end
end
