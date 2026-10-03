# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "tmpdir"
require "support/thinking_off"
require "support/test_kernel"

RSpec.describe Samagotchi::Engine do
  include_context "thinking off"

  around do |example|
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    original_skip = ENV["SAMAGOTCHI_SKIP_AGENT_MD"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    ENV.delete("SAMAGOTCHI_SKIP_AGENT_MD")
    example.run
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
    ENV["SAMAGOTCHI_SKIP_AGENT_MD"] = original_skip
  end

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }

  def build_engine(**overrides)
    described_class.new(client: client, kernel: kernel, **overrides)
  end

  def make_session
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd)
  end

  describe "system prompt construction" do
    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    end

    it "builds a system prompt that identifies the assistant and embeds tool declarations" do
      engine = build_engine(profile: "gemma4")
      prompt = engine.system_prompt
      expect(prompt).to include("You are Chi")
      expect(prompt).to include("declaration:execute")
      expect(prompt).to include("declaration:web_fetch")
    end

    it "exposes the same base prompt via the class helper" do
      helper = described_class.system_prompt_for("gemma4")
      engine = build_engine(profile: "gemma4")
      expect(helper).to eq(engine.assist_system_prompt)
    end

    it "includes rg guidance in the system prompt when rg is available" do
      engine = build_engine(profile: "gemma4")
      allow(engine.instance_variable_get(:@prompt_builder)).to receive(:rg_available?).and_return(true)
      expect(engine.system_prompt).to include("prefer `rg` (ripgrep) over `grep`")
    end

    it "omits rg guidance from the system prompt when rg is not available" do
      engine = build_engine(profile: "gemma4")
      allow(engine.instance_variable_get(:@prompt_builder)).to receive(:rg_available?).and_return(false)
      expect(engine.system_prompt).not_to include("prefer `rg` (ripgrep) over `grep`")
    end

    it "names the attached session id so the agent can tell the user how to resume" do
      engine = build_engine(profile: "gemma4")
      expect(engine.system_prompt).not_to include("Current session id:")

      session = make_session
      engine.session = session
      prompt = engine.instance_variable_get(:@prompt_builder).then { |b| b.send(:system_prompt_with_index, b.base) }
      expect(prompt).to include("Current session id: #{session.id} (resume later with `chi --resume #{session.id}`)")
      expect(prompt).to include("My debug log: #{Samagotchi::LogPath.resolve} (one record per line; this session's carry sid=#{session.id[0, 8]})")
    end

    it "tells a delegated session which session reads its reply" do
      engine = build_engine(profile: "gemma4")
      session = make_session
      engine.session = session
      plain = engine.instance_variable_get(:@prompt_builder).then { |b| b.send(:system_prompt_with_index, b.base) }
      expect(plain).not_to include("Delegated by session")

      session.parent_id = "parent-1234"
      prompt = engine.instance_variable_get(:@prompt_builder).then { |b| b.send(:system_prompt_with_index, b.base) }
      expect(prompt).to include("Current session id: #{session.id} (resume later with `chi --resume #{session.id}`)")
      expect(prompt).to match(/^Delegated by session parent-1234: it reads your final reply; reach it with send_note\.$/)
    end
  end

  describe "bundle needs in the system prompt's index" do
    around do |example|
      Dir.mktmpdir do |tmp|
        with_env("PATH" => ENV["PATH"]) { with_config_home(tmp) { example.run } }
      end
    end

    it "marks a bundle memory's index line when a need isn't on the worker's PATH" do
      fixture = File.expand_path("fixtures/sample_needs_bundle", __dir__)
      Samagotchi::MemoryBundle::Installer.new(source: fixture, name: "sample-needs", scope: "system").run
      ENV["PATH"] = "/usr/bin:/bin"

      prompt = build_engine(profile: "gemma4").instance_variable_get(:@prompt_builder).send(:system_prompt_with_index, "base")
      expect(prompt).to match(/^- \*\*gh_helper\*\* · system · .* \[needs chi-surely-missing-cmd: not found on PATH\]$/)
    end
  end

  describe "project location in the system prompt" do
    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    end

    around do |example|
      Dir.mktmpdir { |tmp| @tmp = File.realpath(tmp); example.run }
    end

    def git(*args)
      system("git", "-c", "user.name=x", "-c", "user.email=x@x", "-c", "init.defaultBranch=main", *args,
             exception: true, out: File::NULL, err: File::NULL)
    end

    def project_prompt_in(dir)
      Dir.chdir(dir) { build_engine(profile: "gemma4").system_prompt }
    end

    let(:repo) { File.join(@tmp, "repo") }

    before do
      git("init", "-q", repo)
      git("-C", repo, "commit", "-q", "--allow-empty", "-m", "init")
    end

    it "shows the project root and memories folder from a linked worktree" do
      tree = File.join(@tmp, "repo-flip")
      git("-C", repo, "worktree", "add", "-q", "-b", "flip", tree)
      folder = Dir.chdir(repo) { Samagotchi::Tools::MemoryRead.memories_dir("project") }

      expect(project_prompt_in(tree)).to include(<<~TEXT.chomp)
        Current working directory:
        #{tree}
        Project root (only where shared project memories come from; read, edit, run and commit in the current working directory above):
        #{repo}
        Home directory: #{Dir.home} (write it as ~ or $HOME in commands and paths)
        Project memories folder:
        #{folder}
      TEXT
    end

    it "shows no root line at the repository root" do
      prompt = project_prompt_in(repo)
      expect(prompt).to include("Current working directory:\n#{repo}\nHome directory: #{Dir.home} (write it as ~ or $HOME in commands and paths)\nProject memories folder:\n")
      expect(prompt).not_to include("Project root (")
    end

    it "names the home directory once, with the advice to write it as ~ or $HOME" do
      allow(Dir).to receive(:home).and_return("/home/jdoe")
      prompt = project_prompt_in(repo)
      expect(prompt.scan("Home directory:").size).to eq(1)
      expect(prompt).to include("Home directory: /home/jdoe (write it as ~ or $HOME in commands and paths)")
    end

    it "shortens a memories folder under the home directory with ~" do
      allow(Samagotchi::Tools::MemoryRead).to receive(:memories_dir).with("project")
        .and_return(File.join(Dir.home, ".config", "samagotchi", "memories", "projects", "repo_abc"))
      expect(project_prompt_in(repo))
        .to include("Project memories folder:\n~/.config/samagotchi/memories/projects/repo_abc")
    end

    it "points the memory convention at the shown folder instead of a path pattern" do
      prompt = project_prompt_in(repo)
      expect(prompt).to include("Project scope: one folder per git repository, shared by its worktrees and subdirectories (path shown above)")
      expect(prompt).not_to include("<name>_<hash>")
    end
  end

  describe "memory injection" do
    before do
      allow(Samagotchi::ConfigFile).to receive(:preloaded_memories).and_return([])
    end

    it "injects requested memories into the system prompt" do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call) do |name, scope: nil, **_overlay_keys|
        name.to_s.empty? ? "" : "BODY-#{name}"
      end
      engine = build_engine(profile: "gemma4", memories: ["my_note"])
      prompt = engine.system_prompt
      expect(prompt).to include("memory name: my_note")
      expect(prompt).to include("BODY-my_note")
    end

    it "returns no explicit memory section when no memories are requested" do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      engine = build_engine(profile: "gemma4")
      expect(engine.instance_variable_get(:@prompt_builder).send(:explicit_memory_section)).to be_nil
    end

    it "merges the config.yml memories baseline with the --memory list (config first, deduped)" do
      allow(Samagotchi::ConfigFile).to receive(:preloaded_memories).and_return(%w[baseline_a baseline_b])
      allow(Samagotchi::Tools::MemoryRead).to receive(:call) do |name, scope: nil, **_overlay_keys|
        name.to_s.empty? ? "" : "BODY-#{name}"
      end
      engine = build_engine(profile: "gemma4", memories: ["baseline_b, cli_only"])

      expect(engine.instance_variable_get(:@prompt_builder).requested_memories).to eq(%w[baseline_a baseline_b cli_only])

      prompt = engine.system_prompt
      expect(prompt).to include("memory name: baseline_a")
      expect(prompt).to include("memory name: cli_only")
      expect(prompt.scan("memory name: baseline_b").size).to eq(1)
    end

    it "names where a memory that can't be loaded came from: config memories: or --memory" do
      allow(Samagotchi::ConfigFile).to receive(:preloaded_memories).and_return(%w[gone_config])
      allow(Samagotchi::Tools::MemoryRead).to receive(:call) do |name, scope: nil, **_overlay_keys|
        name.to_s.empty? ? "" : "Error: memory '#{name}' not found"
      end
      echoes = []
      allow(Samagotchi::Log).to receive(:warn).and_call_original
      allow(Samagotchi::Log).to receive(:warn).with(:memory, "preload_failed", anything) { |*, **fields| echoes << fields[:echo] }
      engine = build_engine(profile: "gemma4", memories: ["gone_cli"])
      engine.system_prompt

      expect(echoes).to eq([
        "Warning: memory 'gone_config' (from config memories:) could not be loaded (Error: memory 'gone_config' not found)",
        "Warning: --memory 'gone_cli' could not be loaded (Error: memory 'gone_cli' not found)"
      ])
    end

    it "uses only the config baseline when --memory is not given" do
      allow(Samagotchi::ConfigFile).to receive(:preloaded_memories).and_return(%w[only_from_config])
      allow(Samagotchi::Tools::MemoryRead).to receive(:call) do |name, scope: nil, **_overlay_keys|
        name.to_s.empty? ? "" : "BODY-#{name}"
      end
      engine = build_engine(profile: "gemma4")

      expect(engine.instance_variable_get(:@prompt_builder).requested_memories).to eq(%w[only_from_config])
      expect(engine.system_prompt).to include("memory name: only_from_config")
    end
  end

  describe "#run_turn" do
    let(:result) do
      Samagotchi::LLM::ModelResult.new(
        text: "hello back",
        conversation: [{ role: "user", content: "hi" }, { role: "model", content: "hello back" }],
        exhausted: false,
        pending_tool_calls: false,
        tool_activity: []
      )
    end

    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    end

    it "returns the kernel Result and updates the session" do
      allow(kernel).to receive(:run).and_return(result)
      session = make_session
      engine = build_engine(profile: "gemma4")

      returned = engine.run_turn(session, "hi")

      expect(returned).to be_a(Samagotchi::LLM::ModelResult)
      expect(returned.conversation).to eq(result.conversation)
      expect(session.last_prompt).to eq("hi")
      expect(session.messages).to eq(result.conversation)
    end

    it "emits turn_started, forwards raw kernel events unchanged, then turn_completed" do
      events = []
      allow(kernel).to receive(:run) do |_messages, **kwargs|
        cb = kwargs[:on_stream_event]
        cb.call(type: :generation_started, iteration: 1)
        cb.call(type: :generation_completed, iteration: 1, content: "hello back")
        result
      end
      session = make_session
      engine = build_engine(profile: "gemma4")

      engine.run_turn(session, "hi", on_event: proc { |event| events << event })

      types = events.map { |e| e[:type] }
      expect(types.first).to eq(:turn_started)
      expect(types.last).to eq(:turn_completed)
      expect(types).to include(:generation_started, :generation_completed)

      # Raw kernel events are forwarded unchanged.
      expect(events.find { |e| e[:type] == :generation_completed })
        .to eq(type: :generation_completed, iteration: 1, content: "hello back")

      # Higher-level Engine events carry turn boundaries + session id.
      expect(events.find { |e| e[:type] == :turn_started })
        .to include(session_id: session.id, prompt: "hi")
      expect(events.find { |e| e[:type] == :turn_completed }[:result]).to be_a(Samagotchi::LLM::ModelResult)
    end

    it "emits turn_canceled (not turn_completed) when the result is canceled" do
      canceled_result = Samagotchi::LLM::ModelResult.new(
        text: "",
        conversation: [],
        exhausted: false,
        pending_tool_calls: false,
        tool_activity: [],
        canceled: true,
        cancellation_reason: "user_interrupt"
      )
      events = []
      allow(kernel).to receive(:run).and_return(canceled_result)
      session = make_session
      engine = build_engine(profile: "gemma4")

      engine.run_turn(session, "hi", on_event: proc { |event| events << event })

      types = events.map { |e| e[:type] }
      expect(types).to include(:turn_canceled)
      expect(types).not_to include(:turn_completed)
      expect(events.find { |e| e[:type] == :turn_canceled }[:cancellation_reason]).to eq("user_interrupt")
    end

    it "does not raise when the event sink raises" do
      allow(kernel).to receive(:run).and_return(result)
      session = make_session
      engine = build_engine(profile: "gemma4")

      expect {
        engine.run_turn(session, "hi", on_event: proc { |_event| raise "boom" })
      }.not_to raise_error
    end

    it "forwards tool_call_completed output and output_truncated to the event sink" do
      engine = build_engine(profile: "gemma4")
      events = []
      allow(kernel).to receive(:run) do |_messages, **kwargs|
        kwargs[:on_stream_event]&.call(
          type: :tool_call_completed,
          output: "[read]\nhi",
          output_truncated: false,
          activity: { action: "reading file", tool: "read", params: 'path="x"', status: "ok" }
        )
        result
      end

      engine.run_turn(make_session, "hi", on_event: proc { |event| events << event })

      completed = events.find { |event| event[:type] == :tool_call_completed }
      expect(completed[:output]).to eq("[read]\nhi")
      expect(completed[:output_truncated]).to be(false)
    end

    describe "generation_chunk lanes" do
      # The loop that streamed a chunk split it (KernelLoop's per-generation
      # ThoughtStreamSplitter, the chat loop's reasoning field): the Engine
      # passes its lanes on as they are and splits nothing itself.
      def stream_turn_chunks(engine, session, chunks)
        events = []
        allow(kernel).to receive(:run) do |_messages, **kwargs|
          cb = kwargs[:on_stream_event]
          cb.call(type: :generation_started, iteration: 1)
          chunks.each { |c| cb.call(c.merge(type: :generation_chunk, iteration: 1)) }
          result
        end
        engine.run_turn(session, "hi", on_event: proc { |e| events << e })
        events.select { |e| e[:type] == :generation_chunk }
      end

      it "passes a split chunk on unchanged" do
        chunk = { content: "<think>a</think>b", text: "b", thinking: "a" }
        got = stream_turn_chunks(build_engine(profile: "qwen36"), make_session, [chunk]).first
        expect(got).to eq(chunk.merge(type: :generation_chunk, iteration: 1))
      end

      it "doesn't split a chunk that came without lanes" do
        chunk = { content: "<think>a</think>b" }
        got = stream_turn_chunks(build_engine(profile: "qwen36"), make_session, [chunk]).first
        expect(got).to eq(chunk.merge(type: :generation_chunk, iteration: 1))
      end
    end
  end

  describe "#switch_model!" do
    it "drops the client's cached context window (the new model may run with another -c)" do
      allow(client).to receive(:invalidate_context_window!)

      build_engine.switch_model!("Qwen3-14B")

      expect(client).to have_received(:invalidate_context_window!)
    end
  end

  describe "context window per turn" do
    before { allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("") }

    it "drops the cached window before the turn generates (the server may have restarted with another -c)" do
      calls = []
      allow(client).to receive(:invalidate_context_window!) { calls << :invalidate }
      allow(kernel).to receive(:run) do
        calls << :run
        Samagotchi::LLM::ModelResult.new(text: "ok", conversation: [], exhausted: false, pending_tool_calls: false, tool_activity: [])
      end

      build_engine(profile: "gemma4").run_turn(make_session, "hi")

      expect(calls).to eq(%i[invalidate run])
    end
  end

  describe "idle recap construction", :recap do
    around do |example|
      saved = ENV.values_at("SAMAGOTCHI_RECAP_BASE_URL", "SAMAGOTCHI_RECAP_MODEL")
      ENV["SAMAGOTCHI_RECAP_BASE_URL"] = "http://localhost:8080/v1"
      ENV["SAMAGOTCHI_RECAP_MODEL"] = "gemma-small"
      example.run
    ensure
      ENV["SAMAGOTCHI_RECAP_BASE_URL"], ENV["SAMAGOTCHI_RECAP_MODEL"] = saved
    end

    it "builds the recap job from configured settings" do
      expect(build_engine.recap).to be_a(Samagotchi::IdleRecap)
    end

    it "an explicit recap: false kwarg wins over configured settings" do
      expect(build_engine(recap: false).recap).to be_nil
    end
  end

  describe "#subscribe / persistent observer" do
    let(:result) do
      Samagotchi::LLM::ModelResult.new(
        text: "hello back",
        conversation: [{ role: "user", content: "hi" }, { role: "model", content: "hello back" }],
        exhausted: false,
        pending_tool_calls: false,
        tool_activity: []
      )
    end

    # Stub the kernel so it emits a small set of raw events on each run.
    def stub_kernel_events
      allow(kernel).to receive(:run) do |_messages, **kwargs|
        cb = kwargs[:on_stream_event]
        cb.call(type: :generation_started, iteration: 1)
        cb.call(type: :generation_completed, iteration: 1, content: "hello back")
        result
      end
    end

    # Stub the kernel, run a turn with a no-op on_event sink, and return nothing.
    def run_turn_with_kernel_events(engine, session, prompt)
      stub_kernel_events
      engine.run_turn(session, prompt, on_event: ->(_event) {})
    end

    it "delivers every event across multiple turns to a single observer" do
      events = []
      engine = build_engine(profile: "gemma4")
      engine.subscribe(observer: ->(event) { events << event })
      session = make_session

      2.times { |i| run_turn_with_kernel_events(engine, session, "hi #{i}") }

      expect(events.map { |e| e[:type] }.count(:turn_started)).to eq(2)
      expect(events.map { |e| e[:type] }.count(:turn_completed)).to eq(2)
      expect(events.map { |e| e[:type] }).to include(:generation_started, :generation_completed)
      # event_seq is strictly increasing and consecutive across turns.
      seqs = events.map { |e| e[:event_seq] }
      expect(seqs.first).to eq(1)
      expect(seqs).to eq((1..seqs.length).to_a)
    end

    it "delivers identical events to multiple subscribers" do
      first, second = [], []
      engine = build_engine(profile: "gemma4")
      engine.subscribe(observer: ->(event) { first << event })
      engine.subscribe(observer: ->(event) { second << event })
      session = make_session
      run_turn_with_kernel_events(engine, session, "hi")
      expect(first).to eq(second)
      expect(first).not_to be_empty
    end

    it "exposes a monotonic engine-local event_count that increments per emitted event" do
      engine = build_engine(profile: "gemma4")
      expect(engine.event_count).to eq(0)
      session = make_session
      run_turn_with_kernel_events(engine, session, "hi")
      expect(engine.event_count).to eq(4) # turn_started + 2 raw kernel + turn_completed
    end

    it "stops delivery after unsubscribe but leaves other subscribers intact" do
      dropped, kept = [], []
      engine = build_engine(profile: "gemma4")
      handle = engine.subscribe(observer: ->(event) { dropped << event })
      engine.subscribe(observer: ->(event) { kept << event })
      session = make_session

      run_turn_with_kernel_events(engine, session, "hi 1")
      handle.unsubscribe
      run_turn_with_kernel_events(engine, session, "hi 2")

      expect(dropped.map { |e| e[:type] }).to eq(%i[turn_started generation_started generation_completed turn_completed])
      expect(kept.map { |e| e[:type] }).to eq((%i[turn_started generation_started generation_completed turn_completed] * 2))
    end

    it "isolates a raising observer so the turn completes and others still receive" do
      other = []
      engine = build_engine(profile: "gemma4")
      engine.subscribe(observer: ->(_event) { raise "boom" })
      engine.subscribe(observer: ->(event) { other << event })
      session = make_session

      expect { run_turn_with_kernel_events(engine, session, "hi") }.not_to raise_error
      expect(other.map { |e| e[:type] }).to include(:turn_started, :turn_completed)
    end

    it "leaves on_event: un-sequenced while the observer receives a sequenced copy" do
      on_events, observer_events = [], []
      engine = build_engine(profile: "gemma4")
      engine.subscribe(observer: ->(event) { observer_events << event })
      stub_kernel_events
      session = make_session
      engine.run_turn(session, "hi", on_event: ->(event) { on_events << event })

      expect(on_events.count).to eq(observer_events.count)
      expect(on_events.first).not_to have_key(:event_seq)
      expect(observer_events.first).to have_key(:event_seq)
      expect(on_events.map { |e| e[:type] }).to eq(observer_events.map { |e| e[:type] })
    end

    it "does not deliver past events to a subscriber added after a turn ran" do
      engine = build_engine(profile: "gemma4")
      session = make_session
      run_turn_with_kernel_events(engine, session, "hi")

      events = []
      engine.subscribe(observer: ->(event) { events << event })
      run_turn_with_kernel_events(engine, session, "hi again")

      expect(events.map { |e| e[:type] }).to eq(%i[turn_started generation_started generation_completed turn_completed])
    end

    it "unsubscribe(nil) on the engine does not raise" do
      engine = build_engine(profile: "gemma4")
      expect { engine.unsubscribe(handle: nil) }.not_to raise_error
    end

    describe "#session_state_snapshot" do
      it "includes a metrics snapshot key carrying per-session analytics" do
        engine = build_engine(profile: "gemma4")
        snap = engine.session_state_snapshot
        expect(snap).to have_key(:metrics)
        expect(snap[:metrics]).to be_a(Hash)
        expect(snap[:metrics][:turns]).to eq(0)
      end

      it "carries the session's parent_id (nil before a session exists)" do
        engine = build_engine(profile: "gemma4")
        expect(engine.session_state_snapshot).to include(parent_id: nil)
      end
    end
  end
end
