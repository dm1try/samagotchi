# frozen_string_literal: true

require "samagotchi/session_commands"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/turn_flow"
require "samagotchi/kernel_loop"

RSpec.describe Samagotchi::SessionCommands do
  # /model and the first turn resolve the prompt profile; no /props probe here.
  before { allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil) }

  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "alpha" => { host: "alpha.test", port: 1111 },
      "beta" => { host: "beta.test", port: 2222 },
      "chat" => { host: "chat.test", port: 3333, api: :openai }
    })
  end
  # A worker's Engine starts on the session's model, which isn't the
  # config default the commands are given.
  let(:engine) { Samagotchi::Engine.new(mode: :assist, host_registry: registry, model_name: "beta:Qwen3-14B") }
  let(:turn_flow) { Samagotchi::TurnFlow.new(engine: engine) }
  let(:saved) { [] }
  let(:commands) do
    described_class.new(engine: engine, turn_flow: turn_flow, default_model: "alpha:gemma4-small",
                        save: ->(session) { saved << session.model_name })
  end
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "beta:Qwen3-14B", working_directory: Dir.pwd).tap do |s|
      s.messages = [{ role: "system", content: "sys" }, { role: "user", content: "old" }]
    end
  end

  before { engine.session = session }

  def cancelled_turn
    turn_flow.before_prompt_turn
    engine.append_messages([{ role: "user", content: "go" }, { role: "model", content: "Partial\n[interrupted]" }])
    turn_flow.after_turn(Samagotchi::KernelLoop::Result.new(output: "", conversation: session.messages, exhausted: false,
                                                             pending_tool_calls: false, tool_activity: [], canceled: true))
  end

  def offered_continue
    turn_flow.before_prompt_turn
    engine.append_messages([{ role: "user", content: "the task" }, { role: "tool_response", content: "r1" }])
    turn_flow.after_turn(Samagotchi::KernelLoop::Result.new(output: "", conversation: session.messages, exhausted: true,
                                                             pending_tool_calls: true, tool_activity: [], canceled: false))
  end

  describe ".command?" do
    it "knows the commands a worker runs, and nothing else" do
      expect(%w[/model /models !rollback /continue].map { |c| described_class.command?(c) }).to all(be(true))
      expect(described_class.command?("/model beta:x --default")).to be(true)
      expect(described_class.command?("/continue no, too slow")).to be(true)
      expect(described_class.command?("!ls -la")).to be(true)
      expect(%w[/stats /recap /exit hello ! /modelx].map { |c| described_class.command?(c) }).to all(be(false))
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
      expect(result.output).to eq("runtime model: beta:Qwen3-14B (default: alpha:gemma4-small, profile=qwen36, name)")
      expect(result.changed).to eq([])
    end

    it "names the served model when the server serves another one" do
      allow(engine).to receive(:served_model).and_return(["ornith-1.5", "Qwen3-14B"])

      expect(commands.run("/model").output)
        .to eq("runtime model: beta:Qwen3-14B (default: alpha:gemma4-small, profile=qwen36, name); served: ornith-1.5")
    end

    it "switches the Engine's model and saves it on the session" do
      result = commands.run("/model alpha:gemma4-small")

      expect(result.output).to eq("runtime model set to alpha:gemma4-small (profile=gemma4, name)")
      expect(result.changed).to eq([:model])
      expect(result.model_name).to eq("alpha:gemma4-small")
      expect(engine.effective_model_name).to eq("alpha:gemma4-small")
      expect(session.model_name).to eq("alpha:gemma4-small")
      expect(saved).to eq(["alpha:gemma4-small"])
    end

    # A chat host's loop doesn't use a prompt profile: naming one misleads.
    it "names no profile for a chat host's model" do
      expect(commands.run("/model chat:some/model:free").output).to eq("runtime model set to chat:some/model:free")
      expect(commands.run("/model").output).to eq("runtime model: chat:some/model:free (default: alpha:gemma4-small)")

      commands.run("/model chat:some/model:free --default")
      expect(commands.run("/model").output).to eq("runtime model: chat:some/model:free")
    end

    it "resets to the given default on clear" do
      expect(commands.run("/model clear").output).to eq("runtime model reset to alpha:gemma4-small (profile=gemma4, name)")
      expect(engine.effective_model_name).to eq("alpha:gemma4-small")
    end

    it "moves its default along with --default" do
      expect(Samagotchi::ConfigFile).to receive(:write_default_model!).with("beta:Qwen3-14B").once

      commands.run("/model beta:Qwen3-14B --default")

      expect(commands.default_model).to eq("beta:Qwen3-14B")
      expect(commands.run("/model").output).to eq("runtime model: beta:Qwen3-14B (profile=qwen36, name)")
    end

    it "refuses a bad alias before switching" do
      result = commands.run("/model alpha:gemma4-small --alias bad/name")

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
      expect(described_class.command?("/models qwen")).to be(true)
      expect(described_class.command?("/modelsx")).to be(false)
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
      allow(Samagotchi::Tools::Execute).to receive(:call).with("echo hi").and_return("hi\n")
      cancelled_turn

      result = commands.run("!echo hi")

      expect(result).to have_attributes(status: :ok, output: "hi\n", shell: true, changed: [:messages])
      expect(session.messages.last).to eq(role: "user", content: "!(echo hi)\nhi\n")
      expect(commands.run("!rollback").output).to eq("nothing to rollback")
      # As in the REPL, the next turn saves it.
      expect(saved).to be_empty
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

    it "discards the interrupted turn on no" do
      offered_continue

      result = commands.run("/continue no")

      expect(result.output).to eq("interrupted turn cancelled; enter your next prompt")
      expect(result.changed).to eq([:messages])
      expect(session.messages.map { |m| m[:content] }).to eq(%w[sys old])
      expect(turn_flow.awaiting_continue?).to be(false)
      expect(saved.size).to eq(1)
    end

    it "notes the reason on no, <reason>" do
      offered_continue

      expect(commands.continue_answer("no, too slow").output).to eq("interrupted turn cancelled; noted your explanation")
      expect(session.messages.last[:content]).to start_with("I chose not to continue the interrupted turn because: too slow")
    end

    it "asks again on anything else" do
      offered_continue

      result = commands.continue_answer("maybe")

      expect(result).to have_attributes(status: :error, output: "answer yes, no, or no, <reason>")
      expect(turn_flow.awaiting_continue?).to be(true)
    end
  end
end
