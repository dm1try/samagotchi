# frozen_string_literal: true

require "tempfile"
require "samagotchi/session_commands"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/turn_flow"
require "samagotchi/kernel_loop"

RSpec.describe Samagotchi::SessionCommands do
  # /model and the first turn resolve the prompt profile; no /props probe here.
  before do
    allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil)
    engine.session = session
  end

  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "alpha" => { host: "alpha.test", port: 1111 },
      "beta" => { host: "beta.test", port: 2222 },
      "chat" => { host: "chat.test", port: 3333, api: :openai }
    })
  end
  # A worker's Engine starts on the session's model, which isn't the
  # config default the commands are given.
  let(:engine) { Samagotchi::Engine.new(host_registry: registry, model_name: "beta:Qwen3-14B") }
  let(:turn_flow) { Samagotchi::TurnFlow.new(engine: engine) }
  let(:saved) { [] }
  let(:commands) do
    described_class.new(engine: engine, turn_flow: turn_flow, default_model: "alpha:gemma-small",
                        save: ->(session) { saved << session.model_name })
  end
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "beta:Qwen3-14B", working_directory: Dir.pwd).tap do |s|
      s.messages = [{ role: "system", content: "sys" }, { role: "user", content: "old" }]
    end
  end

  def cancelled_turn
    turn_flow.before_prompt_turn
    engine.append_messages([{ role: "user", content: "go" }, { role: "model", content: "Partial\n[interrupted]" }])
    turn_flow.after_turn(Samagotchi::LLM::ModelResult.new(text: "", conversation: session.messages, exhausted: false,
                                                          pending_tool_calls: false, tool_activity: [], canceled: true))
  end

  def offered_continue
    turn_flow.before_prompt_turn
    engine.append_messages([{ role: "user", content: "the task" }, { role: "tool_response", content: "r1" }])
    turn_flow.after_turn(Samagotchi::LLM::ModelResult.new(text: "", conversation: session.messages, exhausted: true,
                                                          pending_tool_calls: true, tool_activity: [], canceled: false))
  end

  describe ".builtin_registry" do
    it "knows the commands a worker runs, and nothing else" do
      expect(%w[/model /models /guardrails !rollback /continue].map { |c| described_class.builtin_registry.command?(c) }).to all(be(true))
      expect(described_class.builtin_registry.command?("/guardrails revoke 2")).to be(true)
      expect(described_class.builtin_registry.command?("/guardrails wrong 2")).to be(true)
      expect(described_class.builtin_registry.command?("/guardrailsx")).to be(false)
      expect(described_class.builtin_registry.command?("/model beta:x --default")).to be(true)
      expect(described_class.builtin_registry.command?("/continue no, too slow")).to be(true)
      expect(described_class.builtin_registry.command?("!ls -la")).to be(true)
      expect(%w[/stats /recap /exit /detach hello ! /modelx].map { |c| described_class.builtin_registry.command?(c) }).to all(be(false))
    end

    it "takes ! followed by a command (a space between is fine) as a shell command" do
      ["!ls", "!ruby -e 'puts 1'", "! ls"].each do |line|
        expect(described_class.builtin_registry.lookup(line)&.id).to eq(:shell)
      end
      ["!", "hello !", "hello world", ""].each do |line|
        expect(described_class.builtin_registry.lookup(line)).to be_nil
      end
    end
  end

  describe "/help" do
    it "lists every command: the session's, the bundles' (with their source), then the UIs' own, marked by UI" do
      engine.command_registry.register("/hello", "greet", source: "sample-plugin") { |_args| "hi" }
      engine.command_registry.register("/side", "ask aside", anytime: true, source: "btw") { |_args| nil }
      commands = described_class.new(engine: engine, turn_flow: turn_flow, default_model: "alpha:gemma-small",
                                     registry: engine.command_registry)

      result = commands.run("/help")

      lines = result.output.lines.map(&:rstrip)
      expect(lines.first).to eq("commands:")
      expect(lines.map { |l| l.split.first }.drop(1))
        .to eq(%w[!<cmd> !rollback /context /continue /guardrails /help /llm-context /model /models /parent-answers /reasoning-history /recap /thinking /title /toolkit /working-set /hello /side
                  /archive /cut /detach /exit /participants /queue /quit /share /stats /unqueue])
      expect(lines).to include("  /hello              greet  (sample-plugin)", "  /side               ask aside  (btw; mid-turn too)",
                               start_with("  /model              show or switch the model  (show: mid-turn too)"),
                               "  /detach             leave and keep the worker running  (attached only)",
                               "  /cut                cut the running generation and go in now (/cut TEXT)  (terminal and web only)",
                               "  /queue              run as the next turn after this one (/queue TEXT)  (terminal only)",
                               "  /unqueue            remove your newest queued message before it runs  (attached only)",
                               "  /stats              show the session's stats  (terminal only)",
                               "  /participants       list this session's participants (revoke [P], cap P DOLLARS)  (attached only)")
      expect(result.status).to eq(:ok)
      expect(engine.command_registry.lookup("/help").anytime).to be(true)
      expect(lines).to include("  /title              show or set this session's title (--clear: back to its first message)  (mid-turn too)")
      expect(engine.command_registry.lookup("/title Coordinator")).to have_attributes(id: :title, anytime: true)
      expect(engine.command_registry.lookup("/titles")).to be_nil
    end
  end

  describe "the Engine's registry" do
    it "holds the built-ins, one registry per Engine" do
      other = Samagotchi::Engine.new(host_registry: registry, model_name: "beta:Qwen3-14B")
      expect(engine.command_registry.entries.map(&:name)).to eq(described_class.builtin_registry.entries.map(&:name))
      expect(engine.command_registry).not_to be(other.command_registry)
      expect(engine.command_registry).not_to be_frozen
    end

    it "is what #run looks lines up in, so a bundle's command added to it runs" do
      engine.command_registry.register("/hello", "say hello", source: "some-bundle") { |args| "hi #{args}" }
      commands = described_class.new(engine: engine, turn_flow: turn_flow, default_model: "alpha:gemma-small",
                                     registry: engine.command_registry)
      expect(commands.run("/hello  you ").output).to eq("hi you")
      expect(described_class.builtin_registry.command?("/hello")).to be(false)
    end

    it "runs a bundle's command with no output as nil, and a raise as an error" do
      engine.command_registry.register("/quiet", "nothing", source: "b") { |_args| nil }
      engine.command_registry.register("/boom", "raises", source: "b") { |_args| raise "nope" }
      commands = described_class.new(engine: engine, turn_flow: turn_flow, default_model: "alpha:gemma-small",
                                     registry: engine.command_registry)
      expect(commands.run("/quiet").to_h).to include(status: :ok, output: nil)
      expect(commands.run("/boom").to_h).to include(status: :error, output: "/boom: RuntimeError: nope")
    end
  end

  it "answers nil for a line that isn't one of its commands" do
    expect(commands.run("hello")).to be_nil
    expect(commands.run("/stats")).to be_nil
  end

  describe "/model" do
    it "names the default it was given, not the Engine's starting model (F12)" do
      result = commands.run("/model")

      expect(result.status).to eq(:ok)
      expect(result.output).to eq("runtime model: beta:Qwen3-14B (default: alpha:gemma-small, profile=qwen36, name)")
      expect(result.changed).to eq([])
    end

    it "names the served model when the server serves another one" do
      allow(engine).to receive(:served_model).and_return(["ornith-1.5", "Qwen3-14B"])

      expect(commands.run("/model").output)
        .to eq("runtime model: beta:Qwen3-14B (default: alpha:gemma-small, profile=qwen36, name); served: ornith-1.5")
    end

    it "says nothing of a served model the host's served: expects" do
      allow(engine).to receive(:served_model).and_return(["ornith-1.5", "Qwen3-14B"])
      allow(engine).to receive(:served_expected?).with("ornith-1.5").and_return(true)

      expect(commands.run("/model").output).to eq("runtime model: beta:Qwen3-14B (default: alpha:gemma-small, profile=qwen36, name)")
    end

    it "names the configured sampling of the model" do
      allow(Samagotchi::ConfigFile).to receive(:model_settings)
        .and_return("qwen3-14b" => Samagotchi::ModelSettings.new(sampling: { temperature: 0.6, presence_penalty: 1.5 }))

      expect(commands.run("/model").output)
        .to eq("runtime model: beta:Qwen3-14B (default: alpha:gemma-small, profile=qwen36, name); " \
               "sampling: temperature=0.6 presence_penalty=1.5 (models: qwen3-14b)")
    end

    it "names the model's thinking level and where it came from, nothing when none is set" do
      allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return("qwen3-14b" => Samagotchi::ModelSettings.new(thinking: :off))

      expect(commands.run("/model").output)
        .to eq("runtime model: beta:Qwen3-14B (default: alpha:gemma-small, profile=qwen36, name); thinking: off (models: qwen3-14b)")
    end

    it "names the session's own thinking level over the model's" do
      allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return("qwen3-14b" => Samagotchi::ModelSettings.new(thinking: :off))
      session.thinking = :low

      expect(commands.run("/model").output)
        .to eq("runtime model: beta:Qwen3-14B (default: alpha:gemma-small, profile=qwen36, name); thinking: low (session)")
    end

    it "names the model's steer cut wait and where it came from, nothing for the default" do
      allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return("qwen3-14b" => Samagotchi::ModelSettings.new(steer_cut_after: 0))

      expect(commands.run("/model").output)
        .to end_with("; steer cut: never (models: qwen3-14b)")

      allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return("qwen3-14b" => Samagotchi::ModelSettings.new(steer_cut_after: 60))

      expect(commands.run("/model").output)
        .to end_with("; steer cut: after 60 s (models: qwen3-14b)")

      allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return({})

      expect(commands.run("/model").output).not_to include("steer cut")
    end

    it "names the model notes the session's prompt carries, and the new model's after a switch" do
      session.prompt_notes = [{ "name" => "model_notes_qwen", "scope" => "system", "chars" => 40, "digest" => "0123456789ab" }]

      expect(commands.run("/model").output)
        .to eq("runtime model: beta:Qwen3-14B (default: alpha:gemma-small, profile=qwen36, name); " \
               "notes: model_notes_qwen (system, 40 chars)")

      gemma = Samagotchi::ModelNotes::Note.new(name: "model_notes_gemma", scope: "project", body: "B", chars: 1, digest: "d")
      allow(Samagotchi::ModelNotes).to receive(:for).and_return([gemma])
      expect(commands.run("/model alpha:gemma-small").output)
        .to eq("runtime model set to alpha:gemma-small (profile=gemma4, name); notes: model_notes_gemma (project, 1 chars)")
      expect(saved.last).to eq("alpha:gemma-small")
      expect(session.prompt_notes.map(&:name)).to eq(%w[model_notes_gemma])
    end

    it "names the notes a fresh session's prompt will load, before any turn runs" do
      fresh = Samagotchi::Session.new_session(mode: "assist", model_name: "beta:Qwen3-14B", working_directory: Dir.pwd)
      engine.session = fresh
      gemma = Samagotchi::ModelNotes::Note.new(name: "model_notes_gemma", scope: "project", body: "B", chars: 1, digest: "d")
      allow(Samagotchi::ModelNotes).to receive(:for).and_return([gemma])

      expect(commands.run("/model").output)
        .to eq("runtime model: beta:Qwen3-14B (default: alpha:gemma-small, profile=qwen36, name); " \
               "notes: model_notes_gemma (project, 1 chars)")
      expect(fresh.prompt_notes).to eq([])
    end

    it "sends the ctx % on the new model's window after the switch (Engine#announce_switched_context!)" do
      allow(engine).to receive(:announce_switched_context!).and_call_original

      commands.run("/model alpha:gemma-small")

      expect(engine).to have_received(:announce_switched_context!).once
    end

    it "saves the metrics after the switch, so the session's card drops the old model's %" do
      allow(engine).to receive(:announce_switched_context!).and_call_original
      allow(engine.metrics).to receive(:persist).and_call_original

      commands.run("/model alpha:gemma-small")

      expect(engine).to have_received(:announce_switched_context!).ordered
      expect(engine.metrics).to have_received(:persist).with(state_dir: engine.session_state_dir).ordered
    end

    it "switches the Engine's model and saves it on the session" do
      result = commands.run("/model alpha:gemma-small")

      expect(result.output).to eq("runtime model set to alpha:gemma-small (profile=gemma4, name)")
      expect(result.changed).to eq([:model])
      expect(result.model_name).to eq("alpha:gemma-small")
      expect(engine.effective_model_name).to eq("alpha:gemma-small")
      expect(session.model_name).to eq("alpha:gemma-small")
      expect(saved).to eq(["alpha:gemma-small"])
    end

    describe "on a successful switch" do
      it "carries the model's thinking level after the model note" do
        allow(Samagotchi::ConfigFile).to receive(:model_settings)
          .and_return("gemma-small" => Samagotchi::ModelSettings.new(thinking: :off))

        expect(commands.run("/model alpha:gemma-small").output)
          .to eq("runtime model set to alpha:gemma-small (profile=gemma4, name); thinking: off (models: gemma-small)")
      end

      it "prefers the session's own level over the model's" do
        allow(Samagotchi::ConfigFile).to receive(:model_settings)
          .and_return("gemma-small" => Samagotchi::ModelSettings.new(thinking: :off))
        session.thinking = :low

        expect(commands.run("/model alpha:gemma-small").output)
          .to eq("runtime model set to alpha:gemma-small (profile=gemma4, name); thinking: low (session)")
      end

      it "keeps no thinking note when the new model has none" do
        expect(commands.run("/model alpha:gemma-small").output).to eq("runtime model set to alpha:gemma-small (profile=gemma4, name)")
      end

      it "puts the level before the notes part" do
        allow(Samagotchi::ConfigFile).to receive(:model_settings)
          .and_return("gemma-small" => Samagotchi::ModelSettings.new(thinking: :off))
        gemma = Samagotchi::ModelNotes::Note.new(name: "model_notes_gemma", scope: "project", body: "B", chars: 1, digest: "d")
        allow(Samagotchi::ModelNotes).to receive(:for).and_return([gemma])

        expect(commands.run("/model alpha:gemma-small").output)
          .to eq("runtime model set to alpha:gemma-small (profile=gemma4, name); " \
                 "thinking: off (models: gemma-small); notes: model_notes_gemma (project, 1 chars)")
      end

      it "carries the level on a reset to the default" do
        allow(Samagotchi::ConfigFile).to receive(:model_settings)
          .and_return("gemma-small" => Samagotchi::ModelSettings.new(thinking: :off))

        expect(commands.run("/model clear").output)
          .to eq("runtime model reset to alpha:gemma-small (profile=gemma4, name); thinking: off (models: gemma-small)")
      end

      it "carries the level after the default clause" do
        allow(Samagotchi::ConfigFile).to receive(:write_default_model!)
        allow(Samagotchi::ConfigFile).to receive(:model_settings)
          .and_return("gemma-small" => Samagotchi::ModelSettings.new(thinking: :off))

        expect(commands.run("/model alpha:gemma-small --default").output)
          .to eq("runtime model set to alpha:gemma-small (profile=gemma4, name) and default updated; " \
                 "thinking: off (models: gemma-small)")
      end

      it "carries the level before the alias clause" do
        allow(Samagotchi::ConfigFile).to receive(:write_model_alias!)
        allow(Samagotchi::ConfigFile).to receive(:model_settings)
          .and_return("gemma-small" => Samagotchi::ModelSettings.new(thinking: :off))

        expect(commands.run("/model alpha:gemma-small --alias gemma").output)
          .to eq("runtime model set to alpha:gemma-small (profile=gemma4, name); " \
                 "thinking: off (models: gemma-small); alias 'gemma' -> 'alpha:gemma-small' persisted")
      end

      it "leaves a failed-persist alias reply without the level" do
        allow(Samagotchi::ConfigFile).to receive(:write_model_alias!).and_raise(StandardError, "disk full")
        allow(Samagotchi::ConfigFile).to receive(:model_settings)
          .and_return("gemma-small" => Samagotchi::ModelSettings.new(thinking: :off))

        expect(commands.run("/model alpha:gemma-small --alias gemma").output)
          .to eq("runtime model set to alpha:gemma-small (profile=gemma4, name) but failed to persist alias: disk full")
      end
    end

    # A chat host's loop doesn't use a prompt profile: naming one misleads.
    it "names no profile for a chat host's model" do
      # --default below would write the suite's shared config.yml.
      allow(Samagotchi::ConfigFile).to receive(:write_default_model!)
      expect(commands.run("/model chat:some/model:free").output).to eq("runtime model set to chat:some/model:free")
      expect(commands.run("/model").output).to eq("runtime model: chat:some/model:free (default: alpha:gemma-small)")

      commands.run("/model chat:some/model:free --default")
      expect(commands.run("/model").output).to eq("runtime model: chat:some/model:free")
    end

    it "resets to the given default on clear" do
      expect(commands.run("/model clear").output).to eq("runtime model reset to alpha:gemma-small (profile=gemma4, name)")
      expect(engine.effective_model_name).to eq("alpha:gemma-small")
    end

    it "moves its default along with --default" do
      expect(Samagotchi::ConfigFile).to receive(:write_default_model!).with("beta:Qwen3-14B").once

      commands.run("/model beta:Qwen3-14B --default")

      expect(commands.default_model).to eq("beta:Qwen3-14B")
      expect(commands.run("/model").output).to eq("runtime model: beta:Qwen3-14B (profile=qwen36, name)")
    end

    it "refuses a model whose host isn't configured, keeping the current one" do
      result = commands.run("/model nosuch:org/model")

      expect(result.status).to eq(:error)
      expect(result.output).to eq("unknown host 'nosuch' in model 'nosuch:org/model'; the configured hosts are alpha, beta, chat")
      expect(result.changed).to eq([])
      expect(engine.effective_model_name).to eq("beta:Qwen3-14B")
      expect(saved).to eq([])
    end

    it "refuses a bad alias before switching" do
      result = commands.run("/model alpha:gemma-small --alias bad/name")

      expect(result.output).to eq("invalid alias: alias name must not contain '/'")
      expect(engine.effective_model_name).to eq("beta:Qwen3-14B")
    end

    # CacheConfirm: once the session has a model reply, a switch to another
    # model asks a person first (cost :full); --yes applies it.
    describe "the confirm step once the session has a reply" do
      before { session.messages << { role: "model", content: "hi" } }

      def expect_asked(result, line)
        expect(result.status).to eq(:ok)
        expect(result.changed).to eq([])
        expect(result.confirm.line).to eq(line)
        expect(result.output).to start_with("runtime model: beta:Qwen3-14B\nSwitching to ")
        expect(result.output).to end_with("Nothing changed yet: send `#{line}` to apply.")
        expect(engine.effective_model_name).to eq("beta:Qwen3-14B")
        expect(saved).to eq([])
      end

      it "asks before a plain switch, changing nothing, and keeps the name's case" do
        result = commands.run("/model chat:Some/Model")

        expect_asked(result, "/model chat:Some/Model --yes")
        expect(result.output).to include("Switching to chat:Some/Model restarts the prompt cache")
      end

      it "asks before --default, --alias and clear, repeating the line's flags" do
        allow(Samagotchi::ConfigFile).to receive(:write_default_model!)
        allow(Samagotchi::ConfigFile).to receive(:write_model_alias!)

        expect_asked(commands.run("/model alpha:gemma-small --default"), "/model alpha:gemma-small --default --yes")
        expect_asked(commands.run("/model alpha:gemma-small --alias gemma --default"),
                     "/model alpha:gemma-small --alias gemma --default --yes")
        expect_asked(commands.run("/model clear"), "/model clear --yes")
        expect(Samagotchi::ConfigFile).not_to have_received(:write_default_model!)
        expect(Samagotchi::ConfigFile).not_to have_received(:write_model_alias!)
      end

      it "applies with --yes or -y, anywhere" do
        result = commands.run("/model --yes alpha:gemma-small")

        expect([result.changed, result.confirm]).to eq([[:model], nil])
        expect(engine.effective_model_name).to eq("alpha:gemma-small")
        expect(commands.run("/model beta:Qwen3-14B -y").changed).to eq([:model])
        expect(engine.effective_model_name).to eq("beta:Qwen3-14B")
      end

      it "applies at once for a sender that can't answer (chi send, a delegate)" do
        result = commands.run("/model alpha:gemma-small", confirm: false)

        expect([result.changed, result.confirm]).to eq([[:model], nil])
        expect(engine.effective_model_name).to eq("alpha:gemma-small")
      end

      it "doesn't ask for the model it already runs (the resolved ref), nor before the first reply" do
        expect(commands.run("/model beta:Qwen3-14B").confirm).to be_nil
        session.messages.pop
        expect(commands.run("/model alpha:gemma-small").confirm).to be_nil
        expect(engine.effective_model_name).to eq("alpha:gemma-small")
      end

      it "errors on a typo at once instead of asking" do
        unknown = commands.run("/model nosuch:org/model")
        bad_alias = commands.run("/model alpha:gemma-small --alias bad/name")

        expect([unknown.status, unknown.confirm]).to eq([:error, nil])
        expect(unknown.output).to start_with("unknown host 'nosuch'")
        expect([bad_alias.output, bad_alias.confirm]).to eq(["invalid alias: alias name must not contain '/'", nil])
      end

      it "names the size it rereads when known" do
        allow(engine).to receive(:cache_restart_tokens).and_return(12_400)

        expect(commands.run("/model alpha:gemma-small").output)
          .to include("The next request reads the whole conversation again (about 12.4k tokens).")
      end
    end
  end

  it "lists every host's models with /models" do
    allow(registry).to receive(:list_all_models).and_return("alpha" => { host: "alpha.test", port: 1111, error: "refused" })

    expect(commands.run("/models").output).to eq("alpha (alpha.test:1111) — unreachable: refused")
  end

  describe "/models on a big catalog" do
    # A remote provider's catalog (OpenRouter ~380 ids) must not flood the terminal.
    let(:catalog) do
      ids = (1..25).map { |i| format("vendor/model-%02d", i) } + ["qwen/qwen3.8-27b:free"]
      { "remote" => { host: "openrouter.ai", port: 443,
                      models: ids.map { |id| Samagotchi::LLM::ModelInfo.new(id: id, context_window: nil, supports_tools: nil, raw: {}) } } }
    end

    before do
      allow(registry).to receive(:list_all_models).and_return(catalog)
      allow(Samagotchi::ConfigFile).to receive(:model_aliases).and_return({})
    end

    it "shows 20 ids per host and says how to find the rest" do
      lines = commands.run("/models").output.lines(chomp: true)

      expect(lines.first).to eq("remote (openrouter.ai:443):")
      expect(lines[1..20]).to eq((1..20).map { |i| format("  vendor/model-%02d", i) })
      expect(lines[21..]).to eq(["  … and 6 more; /models <text> lists the ids containing <text>"])
    end

    it "lists every id containing the text, in any case" do
      expect(commands.run("/models QWEN").output).to eq("remote (openrouter.ai:443):\n  qwen/qwen3.8-27b:free")
      expect(commands.run("/models model-2").output.lines.size).to eq(7)
      expect(commands.run("/models nothing-like-it").output).to eq('no model ids contain "nothing-like-it"')
    end

    context "with ids declared under hosts.<name>.models" do
      let(:registry) do
        Samagotchi::HostRegistry.new(hosts_config: {
          "remote" => { host: "openrouter.ai", port: 443, models: Samagotchi::HostModel.parse_map(%w[rr/x], "remote") },
          "gw" => { host: "gw.example", port: 443, models: Samagotchi::HostModel.parse_map(%w[rr/a rr/b], "gw") }
        })
      end
      let(:catalog) do
        ids = (1..450).map { |i| format("vendor/model-%03d", i) }
        { "remote" => { host: "openrouter.ai", port: 443,
                        models: ids.map { |id| Samagotchi::LLM::ModelInfo.new(id: id, context_window: nil, supports_tools: nil, raw: {}) } },
          "gw" => { host: "gw.example", port: 443, models: [] } }
      end

      it "prints them first under their host as (config), outside the 20 per host, and on a host that lists none" do
        lines = commands.run("/models").output.lines(chomp: true)

        expect(lines.first(4)).to eq(["gw (gw.example:443):", "  rr/a (config)", "  rr/b (config)", "remote (openrouter.ai:443):"])
        expect(lines[4]).to eq("  rr/x (config)")
        expect(lines[5..24]).to eq((1..20).map { |i| format("  vendor/model-%03d", i) })
        expect(lines[25]).to eq("  … and 430 more; /models <text> lists the ids containing <text>")
      end

      it "keeps a status the host lists for a declared id, and folds its :batch variant whatever the case" do
        catalog["gw"][:models] = [Samagotchi::LLM::ModelInfo.new(id: "RR/A", context_window: nil, supports_tools: nil, raw: { "status" => "loaded" }),
                                  Samagotchi::LLM::ModelInfo.new(id: "rr/a:batch", context_window: nil, supports_tools: nil, raw: {})]

        expect(commands.run("/models rr/").output.lines(chomp: true).first(4))
          .to eq(["gw (gw.example:443):", "  RR/A (config, loaded)", "  rr/b (config)", "  … plus 1 :batch variant; /models :batch lists them"])
      end

      it "lists a down host's declared ids as (config, host down) under its unreachable line" do
        catalog["gw"] = { host: "gw.example", port: 443, models: [], error: "connection refused" }
        allow(Samagotchi::ConfigFile).to receive(:model_aliases).and_return({ "rr" => "gw:rr/a" })

        lines = commands.run("/models").output.lines(chomp: true)

        expect(lines.first(3)).to eq(["gw (gw.example:443) — unreachable: connection refused",
                                      "  rr/a (config, host down) (alias: rr)", "  rr/b (config, host down)"])
        expect(lines[3]).to eq("remote (openrouter.ai:443):")
        expect(lines.join("\n")).not_to include("orphan")
        expect(commands.run("/models rr/b").output)
          .to eq("gw (gw.example:443) — unreachable: connection refused\n  rr/b (config, host down)")
      end

      it "counts them as discovered for the orphan aliases, and filters them like any id" do
        allow(Samagotchi::ConfigFile).to receive(:model_aliases).and_return({ "rr" => "gw:rr/a" })

        expect(commands.run("/models").output).not_to include("orphan")
        expect(commands.run("/models rr/b").output).to eq("gw (gw.example:443):\n  rr/b (config)")
      end
    end

    context "with OpenRouter's :batch variants" do
      def info(id) = Samagotchi::LLM::ModelInfo.new(id: id, context_window: nil, supports_tools: nil, raw: {})

      let(:catalog) do
        ids = (1..25).map { |i| format("vendor/model-%02d", i) }
        ids += ["vendor/model-01:batch", "vendor/model-24:batch", "lonely/only:batch"]
        { "remote" => { host: "openrouter.ai", port: 443, models: ids.map { |id| info(id) } } }
      end

      it "hides a :batch variant of a listed id and says how many" do
        lines = commands.run("/models").output.lines(chomp: true)

        expect(lines[1..20]).to eq((1..20).map { |i| format("  vendor/model-%02d", i) })
        expect(lines[21..]).to eq(["  … and 6 more, plus 2 :batch variants; /models <text> lists the ids containing <text>"])
      end

      it "names the hidden variants when the filter shows everything else" do
        expect(commands.run("/models model-24").output.lines(chomp: true))
          .to eq(["remote (openrouter.ai:443):", "  vendor/model-24", "  … plus 1 :batch variant; /models :batch lists them"])
      end

      it "lists them when the filter asks for batch" do
        expect(commands.run("/models :batch").output.lines(chomp: true))
          .to eq(["remote (openrouter.ai:443):", "  vendor/model-01:batch", "  vendor/model-24:batch", "  lonely/only:batch"])
      end
    end

    it "is a command with an argument too" do
      expect(described_class.builtin_registry.command?("/models qwen")).to be(true)
      expect(described_class.builtin_registry.command?("/modelsx")).to be(false)
    end
  end

  describe "!rollback" do
    it "has nothing to roll back before a cancelled turn" do
      result = commands.run("!rollback")

      expect(result.output).to eq("nothing to rollback")
      expect(result.changed).to eq([])
      expect(saved).to be_empty
    end

    it "restores the pre-turn conversation after a cancelled turn, and saves it" do
      cancelled_turn

      result = commands.run("!rollback")

      expect(result.output).to eq("salvaged turn discarded; restored pre-turn state")
      expect(result.changed).to eq([:messages])
      expect(session.messages.map { |m| m[:content] }).to eq(%w[sys old])
      expect(saved).to eq(["beta:Qwen3-14B"])
    end
  end

  it "answers a pending continue offer no when !rollback discards the offered turn" do
    offered_continue

    result = commands.run("!rollback")

    expect(result).to have_attributes(output: "salvaged turn discarded; restored pre-turn state", decision: :abort)
    expect(turn_flow.awaiting_continue?).to be(false)
    expect(session.messages.map { |m| m[:content] }).to eq(%w[sys old])
  end

  describe "!cmd" do
    it "runs the command, adds its output to the conversation and ends the rollback window" do
      allow(Samagotchi::Tools::Execute).to receive(:call).with("echo hi", env: {}, on_timeout: :kill).and_return("hi\n")
      cancelled_turn

      result = commands.run("!echo hi")

      expect(result).to have_attributes(status: :ok, output: "hi\n", shell: true, changed: [:messages])
      expect(session.messages.last).to eq(role: "user", content: "!(echo hi)\nhi\n")
      expect(commands.run("!rollback").output).to eq("nothing to rollback")
      # As in the REPL, the next turn saves it.
      expect(saved).to be_empty
    end

    it "runs in the session's project env (ProjectEnv), as the model's execute does" do
      Samagotchi::ProjectEnv.install!(Samagotchi::ProjectEnv::NONE.with(env: { "PROJECT_PROBE" => "a" }.freeze))
      allow(Samagotchi::Tools::Execute).to receive(:call).and_return("ok\n")
      commands.run("!echo hi")
      expect(Samagotchi::Tools::Execute).to have_received(:call).with("echo hi", env: { "PROJECT_PROBE" => "a" }, on_timeout: :kill)
    ensure
      Samagotchi::ProjectEnv.reset!
    end

    # A worker started with --model X has it in its env marked as the CLI's
    # (SessionManager.spawn_options); a chi run from here must not take it
    # for its default.
    it "doesn't pass a --model worker's model on as the default" do
      with_env("SAMAGOTCHI_DEFAULT_MODEL" => "beta:Qwen3-14B", "SAMAGOTCHI_DEFAULT_MODEL_FROM_CLI" => "1") do
        expect(commands.run("!printenv SAMAGOTCHI_DEFAULT_MODEL").output).not_to include("beta:Qwen3-14B")
      end
    end

    it "keeps a default model that isn't the command line's" do
      with_env("SAMAGOTCHI_DEFAULT_MODEL" => "beta:Qwen3-14B", "SAMAGOTCHI_DEFAULT_MODEL_FROM_CLI" => nil) do
        expect(commands.run("!printenv SAMAGOTCHI_DEFAULT_MODEL").output).to include("beta:Qwen3-14B")
      end
    end
  end

  describe "/continue" do
    it "has nothing to continue without an offer" do
      expect(commands.run("/continue").output).to eq("nothing to continue")
      expect(commands.run("/continue no").output).to eq("nothing to continue")
    end

    it "asks the host to run the continue turn on yes" do
      offered_continue

      expect(commands.run("/continue").resume).to be(true)
      expect(commands.run("/continue yes").resume).to be(true)
      expect(turn_flow.awaiting_continue?).to be(true)
    end

    it "keeps the interrupted turn on no, with a note for the model (D3)" do
      offered_continue
      kept = session.messages.map { |m| m[:content] }

      result = commands.run("/continue no")

      expect(result.output).to eq("turn not continued; its work so far stays (!rollback erases it)")
      expect(result.changed).to eq([:messages])
      expect(session.messages.map { |m| m[:content] }[0...-1]).to eq(kept)
      expect(session.messages.last).to eq(Samagotchi::TurnNote.not_continued)
      expect(turn_flow.awaiting_continue?).to be(false)
      expect(saved.size).to eq(1)
    end

    it "notes the reason on no, <reason>" do
      offered_continue

      expect(commands.continue_answer("no, too slow").output).to eq("turn not continued; noted your reason")
      expect(session.messages.last[:content]).to start_with("I chose not to continue the turn that ran out of steps because: too slow")
    end

    # /continue yes as a command (chi send -m, a piped attach) from a parent
    # agent goes through the same check as its chi answer --option Continue.
    it "refuses a parent agent's yes under guardrails.parent_answers: hard, and takes its no" do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("guardrails.parent_answers").and_return("hard")
      offered_continue

      result = commands.run("/continue yes", as_parent: true)

      expect(result).to have_attributes(status: :error, resume: false, decision: :invalid)
      expect(result.output).to include("a parent agent may only stop this turn here (guardrails.parent_answers: hard)")
      expect(turn_flow.awaiting_continue?).to be(true)
      # A person's yes is theirs to give.
      expect(commands.run("/continue yes").resume).to be(true)
      expect(commands.run("/continue no", as_parent: true).output).to start_with("turn not continued")
    end

    it "holds a parent agent's yes to the session's own, stricter level (P3)" do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("guardrails.parent_answers").and_return("soft")
      session.parent_answers = "hard"
      offered_continue

      result = commands.run("/continue yes", as_parent: true)

      expect(result).to have_attributes(status: :error, resume: false, decision: :invalid)
      expect(result.output).to include("(parent_answers: hard (this session))")
      expect(commands.run("/continue yes").resume).to be(true)
    end

    it "lets a parent agent's yes through under soft and standard" do
      %w[soft standard].each do |strategy|
        allow(Samagotchi::Config).to receive(:get).and_call_original
        allow(Samagotchi::Config).to receive(:get).with("guardrails.parent_answers").and_return(strategy)
        offered_continue
        expect(commands.run("/continue yes", as_parent: true).resume).to be(true), strategy
      end
    end

    it "asks again on anything else" do
      offered_continue

      result = commands.continue_answer("maybe")

      expect(result).to have_attributes(status: :error, output: "answer yes, no, or no, <reason>")
      expect(turn_flow.awaiting_continue?).to be(true)
    end
  end

  describe "/model with default_model: nil" do
    let(:engine) { Samagotchi::Engine.new(host_registry: registry, model_name: "splash:test-id") }
    let(:commands) do
      described_class.new(engine: engine, turn_flow: turn_flow, default_model: nil,
                          save: ->(s) { s.save(state_dir: state_dir) })
    end

    it "shows the runtime model without 'default:' text" do
      result = commands.run("/model")

      expect(result.status).to eq(:ok)
      expect(result.output).to include("runtime model: splash:test-id")
      expect(result.output).not_to include("(default:")
      expect(result.changed).to eq([])
    end

    it "refuses /model clear with an error when there is no default" do
      result = commands.run("/model clear")

      expect(result.status).to eq(:error)
      expect(result.output).to include("no default model is configured")
      expect(result.output).to include("default.model")
    end

    it "still sets the runtime model on /model X" do
      result = commands.run("/model alpha:gemma-small")

      expect(result.status).to eq(:ok)
      expect(result.output).to include("runtime model set to alpha:gemma-small")
      expect(result.changed).to eq([:model])
      expect(engine.effective_model_name).to eq("alpha:gemma-small")
    end

    it "sets both runtime model and default on /model X --default" do
      # --default would write the suite's shared config.yml.
      allow(Samagotchi::ConfigFile).to receive(:write_default_model!)
      result = commands.run("/model alpha:gemma-small --default")

      expect(result.status).to eq(:ok)
      expect(result.output).to include("default updated")
      expect(result.changed).to eq([:model])
      expect(commands.default_model).to eq("alpha:gemma-small")
    end
  end

  describe "/working-set" do
    let(:path) { File.join(Dir.pwd, "README.md") }

    before do
      session.messages += [{ role: "model", content: "", tool_calls: [{ id: "c1", name: "read", arguments: { "path" => "README.md" } }] },
                           { role: "tool_response", content: "[read]\n#{"readme line\n" * 40}", tool_call_id: "c1", tool_ids: ["t1"] },
                           { role: "model", content: "Read it." }]
    end

    it "lists while a turn runs; a drop or undrop waits for the turn's end" do
      registry = described_class.builtin_registry

      expect(registry.mid_turn("/working-set")).to eq(:anytime)
      expect(registry.mid_turn("/working-set drop README.md")).to eq(:queue)
      expect(registry.mid_turn("/working-set undrop README.md")).to eq(:queue)
      expect(registry.mid_turn("/working-set pin README.md")).to eq(:queue)
      expect(registry.mid_turn("/working-set unpin README.md")).to eq(:queue)
      expect(registry.mid_turn("/working-set add Gemfile")).to eq(:queue)
      expect(registry.mid_turn("/working-set unadd Gemfile")).to eq(:queue)
    end

    it "adds what can be read (a file, a memory) to the next turn's note, refuses the rest; unadd takes one back" do
      memory = Tempfile.new(%w[style .md])
      allow(Samagotchi::Tools::MemoryRead).to receive(:memory_path).and_call_original
      allow(Samagotchi::Tools::MemoryRead).to receive(:memory_path).with("style", "project").and_return(memory.path)

      result = commands.run("/working-set add Gemfile memory:style")

      expect(result).to have_attributes(status: :ok, changed: [:messages])
      expect(result.output).to eq("added Gemfile: the next turn's note asks the model to read it first (one tool call)\n" \
                                  "added memory style: the next turn's note asks the model to read it first (one tool call)")
      expect(saved).not_to be_empty
      expect(session.messages.last[:content]).to include(%(load them with read "#{File.join(Dir.pwd, "Gemfile")}", memory_read "style"))
      expect(commands.run("/working-set").output).to include("at the next turn's start: added Gemfile, added memory style")

      refused = commands.run("/working-set add nope.rb lib memory:nope README.md")
      expect(refused).to have_attributes(status: :error, changed: [])
      expect(refused.output.lines.map(&:chomp)).to eq(
        ["add nope.rb: no such file", "add lib: a directory: add its files", "add memory:nope: no such memory",
         "add README.md: #{Samagotchi::WorkingSetSteer::Refused.text(:already_sent)}"]
      )

      expect(commands.run("/working-set unadd Gemfile memory:style"))
        .to have_attributes(status: :ok, output: "unadded Gemfile: its add was never sent; nothing changes\n" \
                                                 "unadded memory style: its add was never sent; nothing changes")
      expect(session.messages.last).not_to include(kind: "working_set")
    ensure
      memory&.close!
    end

    it "lists the set, then the change the next turn starts with; the conversation changes and is saved" do
      expect(commands.run("/working-set").output).to start_with("working set (1 item):\n  README.md  read · ~")

      result = commands.run("/working-set drop README.md")

      expect(result).to have_attributes(status: :ok, changed: [:messages])
      expect(saved).not_to be_empty
      expect(session.messages.last).to include(kind: "working_set")
      listing = commands.run("/working-set").output
      expect(listing).to include("README.md  read · dropped")
      expect(listing).to include("at the next turn's start: dropped README.md")
    end

    it "pins on the session (saved, re-announced) without a note under none; a pinned item can't be dropped" do
      announced = []
      allow(engine).to receive(:announce_working_set) { announced << :set }

      result = commands.run("/working-set pin README.md")

      expect(result).to have_attributes(status: :ok, changed: [:working_set_pins])
      expect(result.output).to eq("pinned README.md (t1): forget_outputs refuses its outputs, its later reads too " \
                                  "(the strategy has no forget layer now: the pin holds when it has)")
      expect(session.working_set_pins).to eq([Samagotchi::WorkingSetPin.new(kind: "file", key: path)])
      expect(saved).not_to be_empty
      expect(announced).to eq([:set])
      expect(session.messages.last).not_to include(kind: "working_set")
      expect(commands.run("/working-set").output).to include("README.md  read · pinned")

      refused = commands.run("/working-set drop README.md")
      expect(refused).to have_attributes(status: :error, changed: [],
                                         output: "drop README.md: #{Samagotchi::WorkingSetSteer::Refused.text(:unpin_first)}")

      expect(commands.run("/working-set unpin README.md")).to have_attributes(status: :ok, changed: [:working_set_pins],
                                                                              output: "unpinned README.md: the model may forget it again")
      expect(session.working_set_pins).to be_empty
      expect(commands.run("/working-set unpin README.md").output)
        .to eq("unpin README.md: #{Samagotchi::WorkingSetSteer::Refused.text(:not_pinned)}")
    end

    it "says which other names a memory_read of several holds: the op acts on that read whole" do
      session.messages += [{ role: "model", content: "", tool_calls: [{ id: "c2", name: "memory_read", arguments: { "name" => "style, tone" } }] },
                           { role: "tool_response", content: "[memory_read]\nbe brief\n\n---\n\nbe kind", tool_call_id: "c2",
                             tool_ids: ["t2"] }]

      expect(commands.run("/working-set drop memory:style").output)
        .to start_with("dropped memory style (t2): ").and end_with("; the same memory_read holds memory tone: dropped with it (that read only)")
      expect(commands.run("/working-set").output).to match(/memory:tone +read · dropped/)
    end

    it "takes a quoted KEY with spaces and lists it quoted" do
      session.messages += [{ role: "model", content: "", tool_calls: [{ id: "c2", name: "read", arguments: { "path" => "my notes/a b.md" } }] },
                           { role: "tool_response", content: "[read]\n#{"note line\n" * 40}", tool_call_id: "c2", tool_ids: ["t2"] }]

      expect(commands.run("/working-set").output).to include(%(  "my notes/a b.md"  read · ~))
      expect(commands.run(%(/working-set drop "my notes/a b.md" README.md)))
        .to have_attributes(status: :ok, output: a_string_starting_with("dropped my notes/a b.md (t2): ").and(include("dropped README.md (t1)")))
      expect(commands.run(%(/working-set undrop "my notes/x y.md")).output).to eq(%(undrop "my notes/x y.md": not in the working set))
    end

    it "goes out again after an /llm-context change (the next turn's strategy), not after a look" do
      announced = []
      allow(engine).to receive(:announce_working_set) { announced << engine.working_set_strategy }

      commands.run("/llm-context")
      expect(announced).to be_empty
      # Turning forget on asks first here (the session has a reply): nothing goes out until it applies.
      commands.run("/llm-context strategy stale forget")
      expect(announced).to be_empty
      commands.run("/llm-context strategy stale forget --yes")
      expect(announced).to eq([%i[stale forget]])
    end

    it "lists an item whose drop holds on some reads only as part dropped, and undrop takes it back" do
      stale = { "kind" => "stale", "note" => "README.md: superseded by a later read", "by" => "chi", "staged_at" => "x", "applied_at" => "x" }
      session.messages[-2] = session.messages[-2].merge(edits: { "t1" => stale })
      session.messages += [{ role: "model", content: "", tool_calls: [{ id: "c2", name: "read", arguments: { "path" => "README.md" } }] },
                           { role: "tool_response", content: "[read]\n#{"readme line\n" * 40}", tool_call_id: "c2", tool_ids: ["t2"] }]
      allow(engine).to receive(:working_set_strategy).and_return(%i[stale])

      expect(commands.run("/working-set drop README.md").output).to start_with("dropped README.md (t2): ")
      expect(commands.run("/working-set").output).to include("README.md  read · ×2 · forgotten · part dropped · ~")
      expect(commands.run("/working-set undrop README.md").output).to start_with("undropped README.md (t2)")
    end

    it "answers a bad line with its usage" do
      expect(commands.run("/working-set pinch README.md")).to have_attributes(status: :error, output: Samagotchi::WorkingSetCommand::USAGE)
    end
  end

  describe "/context" do
    let(:state) { Dir.mktmpdir("cmd-context") }
    let(:state_dir) { File.join(state, "samagotchi", "sessions") }

    before { engine.guardrail_state_dir = state_dir }
    after { FileUtils.rm_rf(state) }

    it "lists the session's attached context, as context_read without a name does, mid-turn too" do
      own = Samagotchi::ContextSources.session_location(engine.session.id, state_dir: state_dir)
      expect(commands.run("/context").output).to eq("No attached context in this session.")

      own.add(Samagotchi::ContextSources::Source.new(name: "notes", cmd: nil, every_seconds: nil, why: "spec", hint: nil,
                                                     scope: "session", added_by: "cli", created_at: nil))
      expect(commands.run("/context").output).to eq("Attached context (1):\n- notes; why: spec; no text yet")
      expect(engine.command_registry.lookup("/context").anytime).to be(true)
    end

    it "lists the session's candidates after it, and answers an argument with its usage" do
      own = Samagotchi::ContextSources.session_location(engine.session.id, state_dir: state_dir)
      own.add_candidate(Samagotchi::ContextSources::Candidate.new(name: "pr-412", url: nil, cmd: "printf x", title: "#412 Fix",
                                                                  describe: nil, mentions: [], proposed_by: nil, at: nil))

      expect(commands.run("/context").output).to eq("No attached context in this session.\n\n" \
                                                    "Candidates (attached when a prompt of yours mentions one):\n" \
                                                    "- pr-412 · proposed · #412 Fix")
      expect(commands.run("/context attach pr-412")).to have_attributes(status: :error, output: "usage: /context")
    end
  end

  describe "/guardrails" do
    let(:state) { Dir.mktmpdir("cmd-guard") }
    let(:repo) { File.join(state, "repo").tap { |d| FileUtils.mkdir_p(d) } }

    before { engine.guardrail_state_dir = File.join(state, "sessions") }
    after { FileUtils.rm_rf(state) }

    def store_approval(scope, command)
      ctx = Samagotchi::Guardrails::Context.new(cwd: repo, session_id: "abcdef123456")
      v = Samagotchi::Guardrails::Verdict.new(call: { name: "execute", content: command })
      v.ask!("pushes", rule: "git-push", source: "config")
      v.context = ctx
      v.targets = Samagotchi::Guardrails::Targets.for(v.call, ctx)
      engine.guardrail_approvals.add(v, scope)
    end

    def system_one_log
      Samagotchi::SystemOne::Log.new(dir: File.join(state, "guardrails"))
    end

    def auto_allow(rule, call, p: 0.97, session_id: session.id)
      system_one_log.judgment(session_id: session_id, rule: rule, tool: "execute", call: call, p: p, decision: "auto")
    end

    it "lists the rules, the core checks and no approvals" do
      rules = Samagotchi::Guardrails::Rules.parse(
        [{ "id" => "git-push", "tool" => "shell", "command" => "git push", "verdict" => "ask", "reason" => "publishes" }],
        source: "bundle guardrails"
      )
      allow(engine).to receive(:guardrail_rules).and_return(Samagotchi::Guardrails::Rules.new(rules))
      out = commands.run("/guardrails").output
      expect(out).to include("guardrails: on", "rules (1):",
                             "  1. git-push: ask (tool execute,task_create, command /git push/) — publishes [bundle guardrails]",
                             "  core: deny writes", "approvals (0):\n  (none)")
      expect(out).not_to include("System 1")
    end

    it "lists this session's recent auto-allows and a Record summary for each rule" do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("guardrails.system_one.mode").and_return("on")
      log = system_one_log
      accepted = log.judgment(session_id: session.id, rule: "git-push", call: "git push", p: 0.97, decision: "asked")
      log.label(accepted, "allow_once")
      auto_allow("git-push", "git push origin main")
      auto_allow("git-rebase", "git rebase main")
      auto_allow("git-push", "git push from another session", session_id: "another-session")

      out = commands.run("/guardrails").output

      expect(out).to include("System 1 (on):",
                             "  auto-allows (this session, newest first; /guardrails wrong N):",
                             "    1. git-rebase: git rebase main (p=0.97)",
                             "    2. git-push: git push origin main (p=0.97)",
                             "  records:",
                             "    git-push: asks=3, labelled=1, allow_once=1, allow_wide=0, deny=0, should_have_asked=0, none=0, no_label=2, no_p=0",
                             "    git-rebase: asks=1, labelled=0, allow_once=0, allow_wide=0, deny=0, should_have_asked=0, none=0, no_label=1, no_p=0")
      expect(out).not_to include("another session")
    end

    it "shows System 1 history in off mode when entries exist, but hides an empty off-mode section" do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("guardrails.system_one.mode").and_return("off")
      expect(commands.run("/guardrails").output).not_to include("System 1")

      auto_allow("git-push", "git push")
      expect(commands.run("/guardrails").output).to include("System 1 (off):", "git-push: git push (p=0.97)")
    end

    it "says whether the model is small, and which models: rules are on for it" do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("guardrails.small_models").and_return("auto")
      rules = Samagotchi::Guardrails::Rules.parse(
        [{ "id" => "discard", "tool" => "shell", "command" => "git restore", "models" => "small", "verdict" => "ask", "reason" => "discards" },
         { "id" => "big", "tool" => "shell", "command" => "x", "models" => %w[Llama-* gpt-*], "verdict" => "ask", "reason" => "big" }],
        source: "bundle guardrails"
      )
      allow(engine).to receive(:guardrail_rules).and_return(Samagotchi::Guardrails::Rules.new(rules))
      out = commands.run("/guardrails").output
      expect(engine.model_key).to eq("qwen3-14b")
      expect(out).to include("model: Qwen3-14B — small (auto, 14B)",
                             "  1. discard: ask (tool execute,task_create, command /git restore/, models small) — discards [bundle guardrails]",
                             "  2. big: off for this model — ask (tool execute,task_create, command /x/, models Llama-*,gpt-*) — big [bundle guardrails]")

      allow(Samagotchi::Config).to receive(:get).with("guardrails.small_models").and_return("")
      out = commands.run("/guardrails").output
      expect(out).to include("model: Qwen3-14B — not small (small_models: [])", "  1. discard: off for this model — ask")
    end

    it "lists a git: outside_repo rule" do
      rules = Samagotchi::Guardrails::Rules.parse(
        [{ "id" => "git-outside-repo", "tool" => "shell", "git" => "outside_repo", "verdict" => "ask", "reason" => "elsewhere" }],
        source: "bundle guardrails"
      )
      allow(engine).to receive(:guardrail_rules).and_return(Samagotchi::Guardrails::Rules.new(rules))
      expect(commands.run("/guardrails").output).to include(
        "  1. git-outside-repo: ask (tool execute,task_create, git outside_repo) — elsewhere [bundle guardrails]"
      )
    end

    it "shows the mode, and marks the rules it leaves out strict only" do
      rules = Samagotchi::Guardrails::Rules.parse(
        [{ "id" => "git-rebase", "tool" => "shell", "command" => "git rebase", "modes" => ["strict"], "verdict" => "ask", "reason" => "rewrites" },
         { "id" => "shell-touches-chi", "tool" => "shell", "touches" => "chi_dirs", "skip_read_only" => true, "verdict" => "ask", "reason" => "chi" },
         { "id" => "rm-rf-wide", "tool" => "shell", "command" => "rm", "rm" => "outside_tmp", "verdict" => "ask", "reason" => "wide" },
         { "id" => "memory-remove", "tool" => "memory_write", "memory" => "remove", "verdict" => "ask", "reason" => "removes" }],
        source: "bundle guardrails"
      )
      allow(engine).to receive(:guardrail_rules).and_return(Samagotchi::Guardrails::Rules.new(rules))
      out = commands.run("/guardrails").output
      expect(out.lines[1]).to start_with("mode: auto")
      expect(out).to include(
        "  1. git-rebase: (strict only) — ask (tool execute,task_create, command /git rebase/, modes strict) — rewrites [bundle guardrails]",
        "  2. shell-touches-chi: ask (tool execute,task_create, touches chi_dirs, skip_read_only) — chi [bundle guardrails]",
        "  3. rm-rf-wide: ask (tool execute,task_create, command /rm/, rm outside_tmp) — wide [bundle guardrails]",
        "  4. memory-remove: ask (tool memory_write, memory remove) — removes [bundle guardrails]"
      )

      allow(engine).to receive(:guardrail_rules).and_return(Samagotchi::Guardrails::Rules.new(rules, mode: "strict"))
      out = commands.run("/guardrails").output
      expect(out.lines[1]).to start_with("mode: strict")
      expect(out).to include("  1. git-rebase: ask (tool execute,task_create, command /git rebase/, modes strict)")
    end

    it "lists a tool glob as given" do
      rules = Samagotchi::Guardrails::Rules.parse(
        [{ "id" => "mcp-ask", "tool" => "mcp_*", "verdict" => "ask", "reason" => "an MCP tool" }], source: "config"
      )
      allow(engine).to receive(:guardrail_rules).and_return(Samagotchi::Guardrails::Rules.new(rules))
      expect(commands.run("/guardrails").output).to include("  1. mcp-ask: ask (tool mcp_*) — an MCP tool [config]")
    end

    it "lists disabled rules as such, and disable entries that match nothing" do
      rules = Samagotchi::Guardrails::Rules.parse(
        [{ "id" => "git-push", "tool" => "shell", "command" => "git push", "verdict" => "ask", "reason" => "publishes" }],
        source: "bundle guardrails"
      )
      allow(engine).to receive(:guardrail_rules)
        .and_return(Samagotchi::Guardrails::Rules.new(rules, disable: %w[guardrails:git-push typo]))
      out = commands.run("/guardrails").output
      expect(out).to include("rules (1, 1 disabled):",
                             "  1. git-push: disabled (guardrails.disable) — ask (tool execute,task_create, command /git push/) " \
                             "— publishes [bundle guardrails]",
                             "  guardrails.disable: typo matches no rule")
    end

    it "cuts a command pattern longer than 80 characters with …" do
      long = "(?:#{%w[alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron].join("|")})\\s+--force"
      rules = Samagotchi::Guardrails::Rules.parse(
        [{ "id" => "long", "tool" => "shell", "command" => long, "verdict" => "ask", "reason" => "long" },
         { "id" => "short", "tool" => "shell", "command" => "x" * 80, "verdict" => "ask", "reason" => "short" }],
        source: "config"
      )
      allow(engine).to receive(:guardrail_rules).and_return(Samagotchi::Guardrails::Rules.new(rules))
      out = commands.run("/guardrails").output
      expect(long.length).to be > 80
      expect(out).to include("command /#{long[0, 79]}…/)", "command /#{"x" * 80}/)")
      expect(out).not_to include(long)
    end

    it "lists what failed to load" do
      engine.guardrail_failures.add("hook g.rb (config)", "LoadError: x", required: true)
      expect(commands.run("/guardrails").output).to include("failed to load:\n  hook g.rb (config): LoadError: x (required: every tool call is denied)")
    end

    it "numbers the approvals and revokes by number" do
      store_approval("repo", "git push origin main")
      store_approval("session", "git push")
      out = commands.run("/guardrails").output
      expect(out).to include("approvals (2):", "  1. repo: execute:git push origin main — in #{repo} (rule git-push, config)",
                             "  2. session: execute:git push — session abcdef12", "revoke one with /guardrails revoke N")
      result = commands.run("/guardrails revoke 1")
      expect(result.output).to start_with("revoked approval 1: repo: execute:git push origin main")
      expect(engine.guardrail_approvals.entries.map { |e| e["scope"] }).to eq(%w[session])
    end

    it "refuses a bad revoke or argument" do
      expect(commands.run("/guardrails revoke 3").to_h).to include(status: :error, output: "no approval 3 (see /guardrails)")
      expect(commands.run("/guardrails revoke x").status).to eq(:error)
      expect(commands.run("/guardrails nope").output).to eq("usage: /guardrails [revoke N | wrong [N]]")
    end

    it "labels this session's newest auto-allows with /guardrails wrong [N], appending a label" do
      first = auto_allow("git-push", "git push origin main")
      other_session = auto_allow("git-rebase", "git rebase main", session_id: "another-session")
      latest = auto_allow("git-rebase", "git rebase --onto base")
      before = File.readlines(system_one_log.path)

      result = commands.run("/guardrails wrong 2")

      expect(result.output).to include("labelled auto-allow 2: git-push", "git push origin main", "p=0.97",
                                       "the rule will ask again until its record is rebuilt")
      after = File.readlines(system_one_log.path)
      expect(after[0...before.size]).to eq(before)
      expect(system_one_log.entries.find { |entry| entry["id"] == first }["answer"]).to eq("should_have_asked")
      expect(system_one_log.entries.find { |entry| entry["id"] == latest }["answer"]).to be_nil
      expect(system_one_log.entries.find { |entry| entry["id"] == other_session }["answer"]).to be_nil
    end

    it "defaults /guardrails wrong to the newest unlabelled auto-allow and reports when there are none" do
      id = auto_allow("git-push", "git push")

      expect(commands.run("/guardrails wrong").output).to include("labelled auto-allow 1: git-push")
      expect(system_one_log.entries.find { |entry| entry["id"] == id }["answer"]).to eq("should_have_asked")
      expect(commands.run("/guardrails wrong").output).to eq("no unlabelled System 1 auto-allows in this session (see /guardrails)")
    end

    it "rejects an invalid wrong index" do
      expect(commands.run("/guardrails wrong 0").output).to eq("usage: /guardrails wrong [N] (N from /guardrails)")
      expect(commands.run("/guardrails wrong nope").status).to eq(:error)
    end
  end

  # P3: the session's own parent_answers. Tightening from anyone; loosening
  # only from a user at a UI (user_ui:), passed per call.
  describe "/parent-answers" do
    before do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("guardrails.parent_answers").and_return("soft")
    end

    it "shows the effective level, the session's own and config.yml's" do
      result = commands.run("/parent-answers")
      expect(result.output).to eq("parent answers: soft (this session: none; config.yml guardrails.parent_answers: soft)")
      expect(result.changed).to eq([])
      session.parent_answers = "standard"
      expect(commands.run("/parent-answers").output)
        .to eq("parent answers: standard (this session: standard; config.yml guardrails.parent_answers: soft)")
    end

    it "says a value it can't read is read as hard" do
      session.parent_answers = "loose"
      expect(commands.run("/parent-answers").output)
        .to eq("parent answers: hard (this session: loose (unreadable value, read as hard); " \
               "config.yml guardrails.parent_answers: soft)")
    end

    it "lists a hand-edited level in another case as that level, and parses the argument case-blind" do
      session.instance_variable_set(:@parent_answers, " SOFT ")
      expect(commands.run("/parent-answers").output).not_to include("unreadable")
      expect(Samagotchi::ParentAnswersCommand.parse("Standard")).to eq([:set, "standard"])
      expect(Samagotchi::ParentAnswersCommand.parse("DEFAULT")).to eq([:set, nil])
      expect(Samagotchi::ParentAnswersCommand.parse("loose")).to eq([:usage])
    end

    it "tightens from anyone, saved; the same level again changes nothing" do
      result = commands.run("/parent-answers standard")
      expect(result).to have_attributes(status: :ok, changed: [:parent_answers])
      expect(session.parent_answers).to eq("standard")
      expect(saved.size).to eq(1)
      expect(commands.run("/parent-answers HARD", as_parent: true).changed).to eq([:parent_answers])
      expect(session.parent_answers).to eq("hard")
      expect(commands.run("/parent-answers hard").changed).to eq([])
      expect(saved.size).to eq(2)
    end

    it "refuses a loosening without user_ui, and takes it from a user at a UI" do
      session.parent_answers = "hard"
      result = commands.run("/parent-answers soft")
      expect(result.status).to eq(:error)
      expect(result.output).to include("loosening parent_answers is the user's")
      expect(session.parent_answers).to eq("hard")
      expect(commands.run("/parent-answers default").status).to eq(:error)
      expect(saved).to be_empty

      expect(commands.run("/parent-answers standard", user_ui: true).changed).to eq([:parent_answers])
      expect(session.parent_answers).to eq("standard")
      expect(commands.run("/parent-answers default", user_ui: true).changed).to eq([:parent_answers])
      expect(session.parent_answers).to be_nil
      # From none, default is no change.
      expect(commands.run("/parent-answers default").status).to eq(:ok)
    end

    it "says when config.yml's caps a looser level, and answers a bad word with the usage" do
      allow(Samagotchi::Config).to receive(:get).with("guardrails.parent_answers").and_return("standard")
      result = commands.run("/parent-answers soft")
      expect(result.output).to include("soft is looser than config.yml's guardrails.parent_answers: standard; standard applies")
      expect(commands.run("/parent-answers loose")).to have_attributes(status: :error,
                                                                       output: "usage: /parent-answers [hard|standard|soft|default]")
    end

    # H2: the auth is the call's own; another run in between (an anytime
    # command on its thread) doesn't change it.
    it "keeps each call's own auth when another run comes in between" do
      registry = described_class.register_builtins(Samagotchi::Commands::Registry.new)
      cmds = described_class.new(engine: engine, turn_flow: turn_flow, default_model: "alpha:gemma-small",
                                 save: ->(s) { saved << s.model_name }, registry: registry)
      # Another run (an anytime /help on its thread) right after the line is
      # looked up, before its handler runs.
      inner = false
      allow(registry).to receive(:lookup).and_wrap_original do |original, line|
        entry = original.call(line)
        unless inner || line.start_with?("/help")
          inner = true
          cmds.run("/help", as_parent: !line.start_with?("/continue"), user_ui: false)
          inner = false
        end
        entry
      end
      allow(Samagotchi::Config).to receive(:get).with("guardrails.parent_answers").and_return("hard")
      offered_continue
      expect(cmds.run("/continue yes", as_parent: true).decision).to eq(:invalid)

      session.parent_answers = "hard"
      expect(cmds.run("/parent-answers soft", user_ui: true).changed).to eq([:parent_answers])
    end
  end
end
