# frozen_string_literal: true

require "samagotchi/terminal_ui"

# The TUI reaches the Engine only through its public API; these pin the
# behaviour that used to rely on instance_variable_get/set.
RSpec.describe "TerminalUI ↔ Engine public API" do
  # /model and the first turn resolve the prompt profile; no /props probe here.
  before { allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil) }

  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "alpha" => { host: "alpha.test", port: 1111 },
      "beta" => { host: "beta.test", port: 2222 }
    })
  end
  let(:alpha_client) { registry.entries["alpha"].client }
  let(:beta_client) { registry.entries["beta"].client }

  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "alpha:gemma-small") { example.run } }

  def engine_of(ui) = ui.engine
  def kernel_of(ui) = ui.engine.instance_variable_get(:@kernel)

  describe "guardrail interface" do
    it "is :repl for the REPL and -p without --non-interactive, :non_interactive with it" do
      expect(engine_of(Samagotchi::TerminalUI.new(host_registry: registry)).interface).to eq(:repl)
      expect(engine_of(Samagotchi::TerminalUI.new(host_registry: registry, prompt: "hi")).interface)
        .to eq(:repl)
      ui = Samagotchi::TerminalUI.new(host_registry: registry, prompt: "hi", non_interactive: true)
      expect(engine_of(ui).interface).to eq(:non_interactive)
    end
  end

  describe "a default.model whose host isn't configured" do
    before { ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "nosuch:org/model" }

    it "starts on a valid --model without a word about the default" do
      ui = Samagotchi::TerminalUI.new(host_registry: registry, model_name: "beta:Qwen3-14B")

      expect(engine_of(ui).effective_model_name).to eq("beta:Qwen3-14B")
      expect(kernel_of(ui).client).to be(beta_client)
    end

    it "refuses to start on it without --model" do
      expect { Samagotchi::TerminalUI.new(host_registry: registry) }
        .to raise_error(Samagotchi::ModelProfile::UnknownHost, /unknown host 'nosuch' in model 'nosuch:org\/model'/)
    end

    it "lets an Engine (a worker's) start on its session's model" do
      engine = Samagotchi::Engine.new(host_registry: registry, model_name: "beta:Qwen3-14B")

      expect(engine.effective_model_name).to eq("beta:Qwen3-14B")
    end
  end

  describe "runtime /model across hosts" do
    it "moves the Engine, kernel client and profile to the new host's model" do
      ui = Samagotchi::TerminalUI.new(host_registry: registry)
      expect(kernel_of(ui).client).to be(alpha_client)

      expect { ui.send(:run_input_line, nil, "/model beta:Qwen3-14B") }
        .to output(/model> runtime model set to beta:Qwen3-14B \(profile=qwen36, name\)/).to_stdout

      engine = engine_of(ui)
      expect(ui.instance_variable_get(:@effective_model_name)).to eq("beta:Qwen3-14B")
      expect(engine.effective_model_name).to eq("beta:Qwen3-14B")
      expect(engine.default_model_name).to eq("alpha:gemma-small")
      expect(engine.client).to be(beta_client)
      expect(kernel_of(ui).client).to be(beta_client)
      expect(engine.profile.name).to eq("qwen36")
      expect(kernel_of(ui).profile.name).to eq("qwen36")
    end

    it "persists the default exactly once with --default" do
      ui = Samagotchi::TerminalUI.new(host_registry: registry)
      expect(Samagotchi::ConfigFile).to receive(:write_default_model!).with("beta:Qwen3-14B").once

      expect { ui.send(:run_input_line, nil, "/model beta:Qwen3-14B --default") }.to output.to_stdout

      expect(engine_of(ui).default_model_name).to eq("beta:Qwen3-14B")
      expect(ui.instance_variable_get(:@default_model_name)).to eq("beta:Qwen3-14B")
    end

    it "starts on the --model host without changing the default" do
      ui = Samagotchi::TerminalUI.new(host_registry: registry, model_name: "beta:Qwen3-14B")

      expect(kernel_of(ui).client).to be(beta_client)
      expect(engine_of(ui).effective_model_name).to eq("beta:Qwen3-14B")
      expect(engine_of(ui).default_model_name).to eq("alpha:gemma-small")
    end
  end

  describe "due-reminder queue" do
    it "is filled by the IdleReminders callback and read through Engine" do
      ui = Samagotchi::TerminalUI.new(host_registry: registry)
      engine = engine_of(ui)
      engine.instance_variable_get(:@auto_turn_callback).call(%w[health])

      expect(engine.due_reminder_names).to eq(%w[health])
      expect(ui.send(:poll_input_with_reminder_check, awaiting_continue: false)).to eq(:due)
    end
  end
end
