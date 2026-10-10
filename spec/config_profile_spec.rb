# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/config"
require "samagotchi/host_registry"

# The prompt profile can be set for one process (SAMAGOTCHI_MODEL_PROFILE,
# --model-profile), per host (hosts.<name>.profile) and per model (the
# top-level models: map). Config only carries the values; ModelProfile.resolve
# validates them.
RSpec.describe "prompt profile config" do
  def with_config(data)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, data.to_yaml)
      yield path, dir
    end
  end

  describe "model.profile" do
    it "comes from SAMAGOTCHI_MODEL_PROFILE and --model-profile, not the config file" do
      entry = Samagotchi::Config.find_by_key("model.profile")

      expect(entry.env_key).to eq("SAMAGOTCHI_MODEL_PROFILE")
      expect(entry.cli_flag).to eq("--model-profile")
      expect(entry).not_to be_config_exposed
      expect(Samagotchi::Config.resolve_with_origin("model.profile", env: { "SAMAGOTCHI_MODEL_PROFILE" => "Qwen36" }))
        .to eq(["qwen36", :env])
      expect(Samagotchi::Config.resolve_with_origin("model.profile", env: {}, cli_overrides: { "model.profile" => "gemma4" }))
        .to eq(["gemma4", :cli])
      expect(Samagotchi::Config.resolve("model.profile", file_data: { "model" => { "profile" => "gemma4" } }, env: {}))
        .to be_nil
    end

    it "warns about an unknown value and leaves it unset" do
      value = :unset
      expect { value = Samagotchi::Config.resolve("model.profile", env: { "SAMAGOTCHI_MODEL_PROFILE" => "llama" }) }
        .to output(/invalid value for model.profile.*qwen36, gemma4/).to_stderr
      expect(value).to be_nil
    end
  end

  describe "hosts.<name>.profile" do
    it "is kept on the host (as written; ModelProfile.resolve validates it)" do
      with_config("hosts" => { "mlx" => { "host" => "box", "transport" => "mlx", "profile" => " Qwen36 " },
                               "plain" => { "host" => "h" } }) do |path|
        hosts = Samagotchi::ConfigFile.hosts_config(env: {}, path: path)

        expect(hosts["mlx"].profile).to eq("qwen36")
        expect(hosts["plain"].profile).to be_nil
      end
    end

    it "travels to a worker in SAMAGOTCHI_HOSTS_JSON and reaches the HostEntry" do
      with_config("hosts" => { "mlx" => { "host" => "box", "port" => 8081, "profile" => "qwen36" } }) do |path, dir|
        json = Samagotchi::ConfigFile.hosts_json_for_env(env: {}, path: path)
        worker = Samagotchi::ConfigFile.hosts_config(env: { "SAMAGOTCHI_HOSTS_JSON" => json }, path: File.join(dir, "none.yml"))
        registry = Samagotchi::HostRegistry.new(hosts_config: worker)

        expect(JSON.parse(json)["mlx"]).to include("profile" => "qwen36")
        expect(registry.find_entry("mlx").profile).to eq("qwen36")
      end
    end
  end

  describe "ConfigFile.model_settings" do
    it "reads the models: map, keyed by id or alias, case-insensitively" do
      with_config("models" => { "ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M" => { "profile" => "qwen36" },
                                "Ista" => { "profile" => "Gemma4" } }) do |path|
        expect(Samagotchi::ConfigFile.model_settings(env: {}, path: path)).to eq(
          "ornith-ai/ornith-1.5-35b-a3b-gguf:q4_k_m" => Samagotchi::ModelSettings.new(profile: "qwen36"),
          "ista" => Samagotchi::ModelSettings.new(profile: "gemma4")
        )
      end
    end

    it "skips entries that are not maps and gives {} without a models: section" do
      with_config("models" => { "a" => "qwen36", "b" => { "profile" => "" }, "c" => { "profile" => "qwen36" } }) do |path|
        expect(Samagotchi::ConfigFile.model_settings(env: {}, path: path)).to eq("b" => Samagotchi::ModelSettings.new, "c" => Samagotchi::ModelSettings.new(profile: "qwen36"))
      end
      with_config("default" => { "model" => "m" }) do |path|
        expect(Samagotchi::ConfigFile.model_settings(env: {}, path: path)).to eq({})
      end
    end

    it "is not flagged as an unknown section" do
      expect(Samagotchi::Config.validate_yaml_sections("models" => { "a" => { "profile" => "qwen36" } })).to eq([])
    end
  end
end
