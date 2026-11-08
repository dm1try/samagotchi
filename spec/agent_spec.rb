# frozen_string_literal: true

require "samagotchi/terminal_ui"
# Engine#initialize loads SystemBundle lazily; the @ path completion group
# stubs it before any Engine exists.
require "samagotchi/memory_bundle/system_bundle"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "support/test_kernel"

# The one-shot host (chi -p … --non-interactive): the prompt its Engine
# builds, and its one turn.
RSpec.describe Samagotchi::TerminalUI do
  let(:client) { test_client }

  around do |example|
    original_thinking_mode = ENV["SAMAGOTCHI_THINKING_LEVEL"]
    original_skip_agents_md = ENV["SAMAGOTCHI_SKIP_AGENTS_MD"]
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
    ENV["SAMAGOTCHI_SKIP_AGENTS_MD"] = original_skip_agents_md
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
      ENV.delete("SAMAGOTCHI_SKIP_AGENTS_MD")
    end

    it "sends the prompt to the kernel and prints the response" do
      allow(client).to receive(:complete).and_return("file1.rb\
file\
file2.rb")
      agent = described_class.new(prompt: "list files", client: client)
      expect { agent.run }.to output(/file1.rb/).to_stdout
    end

    it "has its Engine build the KernelLoop with the client, the Engine's hooks, store and tools" do
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
        .with(client: client, profile: nil, model_name: "Gemma-4B-it", reprefill: an_instance_of(Samagotchi::ReprefillMeter),
              services: an_instance_of(Samagotchi::KernelLoop::Services)
          .and(having_attributes(hooks: instance_of(Samagotchi::Hooks::Registry), reminder_store: instance_of(Samagotchi::ReminderStore),
                                 tools: instance_of(Samagotchi::Tools::Registry), gate: instance_of(Samagotchi::Guardrails::Gate))))
        .and_return(kernel)

      agent = described_class.new(prompt: "hi", client: client)
      expect { agent.run }.to output(/ok/).to_stdout
    end

    it "runs the prompt once" do
      call_count = 0
      allow(client).to receive(:complete) do
        call_count += 1
        "done"
      end
      agent = described_class.new(prompt: "hello", client: client)
      agent.run
      expect(call_count).to eq(1)
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
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("foo", hash_including(scope: nil)).and_return("foo body")
      agent = described_class.new(prompt: "hi", client: client, memories: ["foo"])
      agent.run
      expect(received_prompt).to include("this memory is required by the user in the current context: memory name: foo")
      expect(received_prompt).to include("foo body")
    end

    it "gives the Engine a resumed session's appended files first, then the flag's, without saving the merge" do
      stored = Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd,
                                               setup: Samagotchi::SessionSetup.new(appended_prompt_files: ["/r/a.md"]))
      stored.save
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      allow(Samagotchi::Engine).to receive(:new).and_call_original
      agent = described_class.new(client: client, session_id: stored.id, appended_prompt_files: ["/r/b.md", "/r/a.md"])

      expect(Samagotchi::Engine).to have_received(:new).with(hash_including(appended_prompt_files: ["/r/a.md", "/r/b.md"]))
      expect(Samagotchi::Session.load(stored.id).appended_prompt_files).to eq(["/r/a.md"])
    ensure
      agent&.instance_variable_get(:@owner_lock)&.release
    end

    it "merges a resumed session's stored --memory and --mute lists with the flags" do
      stored = Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd,
                                               preloaded_memory_names: ["foo"], muted_memory_names: ["bar"])
      stored.save
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      agent = described_class.new(client: client, session_id: stored.id, memories: ["baz"], muted_memories: %w[bar qux])

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
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("foo", hash_including(scope: "project")).and_return("foo body")
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
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).with("missing", hash_including(scope: nil)).and_return("Error: memory not found: missing")
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
      expect(received_prompt).to include('type:<|"|>STRING<|"|>')
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

    it "injects AGENTS.md as project specific description when present" do
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:file?).with(File.join(Dir.pwd, "AGENTS.md")).and_return(true)
      allow(File).to receive(:read).with(File.join(Dir.pwd, "AGENTS.md"), encoding: "UTF-8").and_return("Use project conventions")

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

    it "skips AGENTS.md injection when SAMAGOTCHI_SKIP_AGENTS_MD=true" do
      ENV["SAMAGOTCHI_SKIP_AGENTS_MD"] = "true"
      received_prompt = nil
      allow(client).to receive(:complete) do |prompt|
        received_prompt = prompt
        "ok"
      end
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:file?).with(File.join(Dir.pwd, "AGENTS.md")).and_return(true)
      allow(File).to receive(:read).with(File.join(Dir.pwd, "AGENTS.md"), encoding: "UTF-8").and_return("Use project conventions")

      agent = described_class.new(prompt: "hi", client: client)
      agent.run

      expect(received_prompt).not_to include("Project specific description:")
      expect(received_prompt).not_to include("Use project conventions")
    end
  end

  describe "run entrypoints (--prompt / --non-interactive / --resume)" do
    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      ENV.delete("SAMAGOTCHI_SKIP_AGENTS_MD")
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

      agent = described_class.new(prompt: "next step", client: client)
      agent.instance_variable_set(:@resume_session, resumed)
      agent.run

      expect(seen.length).to eq(1) # one turn on the resumed session
      expect(seen.first).to include("next step")
      expect(seen.first).to include("prior prompt") # prior history present in context
    end
  end

  describe "Thinking Mode (control token injection)" do
    let(:base_prompt) { "Base Prompt" }

    before do
      # Clear ENV to ensure tests are isolated from the environment
      ENV.delete("SAMAGOTCHI_THINKING_LEVEL")
      ENV.delete("SAMAGOTCHI_SKIP_AGENTS_MD")
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
end
