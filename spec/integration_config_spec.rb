# frozen_string_literal: true

require "samagotchi/config"
require "yaml"

# The config :integration examples run under: built from
# SAMAGOTCHI_INTEGRATION_* (spec/support/integration_server.rb), never the
# developer's ~/.config/samagotchi.
RSpec.describe IntegrationServer do
  let(:tmp) { Dir.mktmpdir("integration-config-spec") }

  after { FileUtils.remove_entry(tmp) }

  describe ".settings_from" do
    it "defaults to chi's own server default and no api" do
      settings = described_class.settings_from({})

      expect(settings.host).to eq("localhost")
      expect(settings.port).to eq(8080)
      expect(settings.api).to eq("")
      expect(settings.transport).to eq("")
      expect(settings).not_to be_model
    end

    it "reads host, port, model and api from SAMAGOTCHI_INTEGRATION_*" do
      settings = described_class.settings_from(
        "SAMAGOTCHI_INTEGRATION_HOST" => "192.0.2.10", "SAMAGOTCHI_INTEGRATION_PORT" => "8081",
        "SAMAGOTCHI_INTEGRATION_MODEL" => "org/Model-GGUF:Q4_K_M", "SAMAGOTCHI_INTEGRATION_API" => "openai"
      )

      expect(settings).to have_attributes(host: "192.0.2.10", port: 8081, model: "org/Model-GGUF:Q4_K_M", api: "openai")
      expect(settings.openai_base_url).to eq("http://192.0.2.10:8081/v1")
    end
  end

  describe ".write_config_home" do
    let(:settings) do
      described_class.settings_from("SAMAGOTCHI_INTEGRATION_HOST" => "192.0.2.10", "SAMAGOTCHI_INTEGRATION_PORT" => "8081",
                                    "SAMAGOTCHI_INTEGRATION_MODEL" => "live-model")
    end

    it "holds only the server and model, whatever the developer's own config says" do
      home = File.join(tmp, "home")
      FileUtils.mkdir_p(File.join(home, ".config", "samagotchi"))
      File.write(File.join(home, ".config", "samagotchi", "config.yml"), <<~YAML)
        default:
          model: the-developers-model
        memories:
        - user_preferences
        model_aliases:
          moe: some/other-model
      YAML

      config_home = with_env("HOME" => home, "XDG_CONFIG_HOME" => nil) { described_class.write_config_home(settings, parent: tmp) }
      data = YAML.safe_load_file(File.join(config_home, "samagotchi", "config.yml"))

      expect(data).to eq(
        "default" => { "model" => "live-model" },
        "server" => { "host" => "192.0.2.10", "port" => 8081 },
        "hosts" => { "integration" => { "host" => "192.0.2.10", "port" => 8081 } }
      )
    end

    it "gives chi the model and host through its own config reader" do
      config_home = described_class.write_config_home(settings, parent: tmp)

      with_env("XDG_CONFIG_HOME" => config_home) do
        expect(Samagotchi::Config.get("default.model")).to eq("live-model")
        expect(Samagotchi::Config.get("server.host")).to eq("192.0.2.10")
        expect(Samagotchi::Config.get("server.port")).to eq(8081)
        expect(Samagotchi::ConfigFile.hosts_config.keys).to eq(["integration"])
      end
    end

    it "sets api: openai on the host when asked" do
      openai = described_class.settings_from("SAMAGOTCHI_INTEGRATION_MODEL" => "m", "SAMAGOTCHI_INTEGRATION_API" => "openai")
      data = YAML.safe_load(openai.config_yaml)

      expect(data.dig("hosts", "integration", "api")).to eq("openai")
    end

    it "sets the transport on the server and the host when asked" do
      omlx = described_class.settings_from("SAMAGOTCHI_INTEGRATION_MODEL" => "m", "SAMAGOTCHI_INTEGRATION_TRANSPORT" => "omlx")
      data = YAML.safe_load(omlx.config_yaml)

      expect(data.dig("server", "transport")).to eq("omlx")
      expect(data.dig("hosts", "integration", "transport")).to eq("omlx")
    end
  end

  # Runs only under SAMAGOTCHI_INTEGRATION=1: the switch the spec_helper
  # makes for every :integration example.
  it "points :integration examples at the integration fixture config", :integration do
    expect(ENV.fetch("XDG_CONFIG_HOME")).to eq(SPEC_INTEGRATION_XDG_CONFIG_HOME)
    expect(Samagotchi::ConfigFile.global_path).to start_with(SPEC_INTEGRATION_XDG_CONFIG_HOME)
    expect(Samagotchi::Config.get("default.model")).to eq(described_class.model)
    expect(ENV.fetch("XDG_STATE_HOME")).to eq(SPEC_XDG_STATE_HOME)
  end
end
