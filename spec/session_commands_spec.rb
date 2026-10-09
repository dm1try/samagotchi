# frozen_string_literal: true

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
        .to eq(%w[!<cmd> !rollback /context /continue /guardrails /help /llm-context /model /models /hello /side /archive /detach /exit /quit /recap /stats])
      expect(lines).to include("  /hello        greet  (sample-plugin)", "  /side         ask aside  (btw; mid-turn too)",
                               start_with("  /model        show or switch the model  (show: mid-turn too)"),
                               "  /detach       leave and keep the worker running  (attached only)",
                               "  /stats        show the session's stats  (terminal only)")
      expect(result.status).to eq(:ok)
      expect(engine.command_registry.lookup("/help").anytime).to be(true)
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
        .and_return("qwen3-14b" => { profile: nil, sampling: { temperature: 0.6, presence_penalty: 1.5 } })

      expect(commands.run("/model").output)
        .to eq("runtime model: beta:Qwen3-14B (default: alpha:gemma-small, profile=qwen36, name); " \
               "sampling: temperature=0.6 presence_penalty=1.5 (models: qwen3-14b)")
    end

    it "names the model's thinking level and where it came from, nothing when none is set" do
      allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return("qwen3-14b" => { profile: nil, thinking: :off })

      expect(commands.run("/model").output)
        .to eq("runtime model: beta:Qwen3-14B (default: alpha:gemma-small, profile=qwen36, name); thinking: off (models: qwen3-14b)")
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

    it "switches the Engine's model and saves it on the session" do
      result = commands.run("/model alpha:gemma-small")

      expect(result.output).to eq("runtime model set to alpha:gemma-small (profile=gemma4, name)")
      expect(result.changed).to eq([:model])
      expect(result.model_name).to eq("alpha:gemma-small")
      expect(engine.effective_model_name).to eq("alpha:gemma-small")
      expect(session.model_name).to eq("alpha:gemma-small")
      expect(saved).to eq(["alpha:gemma-small"])
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
      allow(Samagotchi::Tools::Execute).to receive(:call).with("echo hi", env: {}).and_return("hi\n")
      cancelled_turn

      result = commands.run("!echo hi")

      expect(result).to have_attributes(status: :ok, output: "hi\n", shell: true, changed: [:messages])
      expect(session.messages.last).to eq(role: "user", content: "!(echo hi)\nhi\n")
      expect(commands.run("!rollback").output).to eq("nothing to rollback")
      # As in the REPL, the next turn saves it.
      expect(saved).to be_empty
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

    it "asks again on anything else" do
      offered_continue

      result = commands.continue_answer("maybe")

      expect(result).to have_attributes(status: :error, output: "answer yes, no, or no, <reason>")
      expect(turn_flow.awaiting_continue?).to be(true)
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
      expect(commands.run("/guardrails nope").output).to eq("usage: /guardrails [revoke N]")
    end
  end
end
