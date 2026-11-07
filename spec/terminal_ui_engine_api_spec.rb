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
    it "is :non_interactive: no one is there to answer" do
      ui = Samagotchi::TerminalUI.new(host_registry: registry, prompt: "hi")
      expect(engine_of(ui).interface).to eq(:non_interactive)
    end
  end

  # One reader for the recap settings, as for a worker's Engine: the TUI
  # passes no recap: of its own, RecapSetup resolves the config.
  describe "recap settings", :recap do
    it "are read by RecapSetup alone, from a configured recap: section too" do
      with_env("SAMAGOTCHI_RECAP_MODEL" => "alpha:small") do
        expect(Samagotchi::RecapSetup).to receive(:build).with(nil, any_args).and_call_original

        ui = Samagotchi::TerminalUI.new(host_registry: registry)

        expect(ui.engine.recap.target).to have_attributes(model: "small")
      end
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
        .to raise_error(Samagotchi::ModelProfile::UnknownHost, %r{unknown host 'nosuch' in model 'nosuch:org/model'})
    end

    it "lets an Engine (a worker's) start on its session's model" do
      engine = Samagotchi::Engine.new(host_registry: registry, model_name: "beta:Qwen3-14B")

      expect(engine.effective_model_name).to eq("beta:Qwen3-14B")
    end
  end

  describe "runtime /model across hosts" do
    it "starts on the --model host without changing the default" do
      ui = Samagotchi::TerminalUI.new(host_registry: registry, model_name: "beta:Qwen3-14B")

      expect(kernel_of(ui).client).to be(beta_client)
      expect(engine_of(ui).effective_model_name).to eq("beta:Qwen3-14B")
      expect(engine_of(ui).default_model_name).to eq("alpha:gemma-small")
    end
  end
end
