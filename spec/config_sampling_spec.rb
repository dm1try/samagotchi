# frozen_string_literal: true

require "json"
require "tmpdir"
require "yaml"
require "samagotchi/config"
require "samagotchi/host_registry"

# `sampling:` under hosts.<name> and models.<key>: request parameters passed
# through to the provider (keys symbolized, reserved keys dropped).
RSpec.describe "sampling config" do
  def with_config(data)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, data.to_yaml)
      yield path, dir
    end
  end

  before { Samagotchi::ConfigFile.reset_warnings! }

  it "reads a host's sampling map with symbol keys, nested maps included" do
    with_config("hosts" => { "work" => { "url" => "https://w.example/v1", "api" => "openai",
                                         "sampling" => { "temperature" => 0.6, "presence_penalty" => 1.5,
                                                         "chat_template_kwargs" => { "enable_thinking" => false } } },
                             "plain" => { "host" => "h" } }) do |path|
      hosts = Samagotchi::ConfigFile.hosts_config(env: {}, path: path)

      expect(hosts["work"][:sampling]).to eq(temperature: 0.6, presence_penalty: 1.5,
                                             chat_template_kwargs: { enable_thinking: false })
      expect(hosts["plain"][:sampling]).to be_nil
    end
  end

  it "reads a models: entry's sampling map" do
    with_config("models" => { "Qwen3.6-35B" => { "sampling" => { "temperature" => 0.6, "top_p" => 0.95 } },
                              "other" => { "profile" => "qwen36" } }) do |path|
      models = Samagotchi::ConfigFile.model_settings(env: {}, path: path)

      expect(models["qwen3.6-35b"]).to eq(profile: nil, sampling: { temperature: 0.6, top_p: 0.95 })
      expect(models["other"]).not_to have_key(:sampling)
    end
  end

  it "keeps a null value (don't send the key)" do
    with_config("hosts" => { "work" => { "host" => "h", "sampling" => { "temperature" => nil } } }) do |path|
      expect(Samagotchi::ConfigFile.hosts_config(env: {}, path: path)["work"][:sampling]).to eq(temperature: nil)
    end
  end

  it "drops reserved keys with one warning each" do
    with_config("hosts" => { "work" => { "host" => "h", "sampling" => { "temperature" => 0.6, "max_tokens" => 10, "stream" => false } } }) do |path|
      hosts = nil
      expect { hosts = Samagotchi::ConfigFile.hosts_config(env: {}, path: path) }
        .to output(/hosts entry 'work': sampling.max_tokens is set by chi; ignored.*sampling.stream is set by chi/m).to_stderr
      expect(hosts["work"][:sampling]).to eq(temperature: 0.6)
      expect { Samagotchi::ConfigFile.hosts_config(env: {}, path: path) }.not_to output.to_stderr
    end
  end

  it "drops id_slot: a pin on every request skips the server's prompt cache after a pause" do
    with_config("hosts" => { "work" => { "host" => "h", "sampling" => { "temperature" => 0.6, "id_slot" => 0 } } }) do |path|
      hosts = nil
      expect { hosts = Samagotchi::ConfigFile.hosts_config(env: {}, path: path) }
        .to output(/sampling.id_slot is set by chi; ignored/).to_stderr
      expect(hosts["work"][:sampling]).to eq(temperature: 0.6)
    end
  end

  it "warns about a sampling that is not a map and skips it" do
    with_config("models" => { "m" => { "sampling" => "hot" } }) do |path|
      models = nil
      expect { models = Samagotchi::ConfigFile.model_settings(env: {}, path: path) }
        .to output(/models: m: sampling must be a map of request parameters; ignored/).to_stderr
      expect(models["m"]).to eq(profile: nil)
    end
  end

  it "travels to a worker in SAMAGOTCHI_HOSTS_JSON and reaches the HostEntry" do
    with_config("hosts" => { "work" => { "host" => "box", "sampling" => { "temperature" => 0.6, "min_p" => 0.05,
                                                                          "chat_template_kwargs" => { "enable_thinking" => false } } } }) do |path, dir|
      json = Samagotchi::ConfigFile.hosts_json_for_env(env: {}, path: path)
      worker = Samagotchi::ConfigFile.hosts_config(env: { "SAMAGOTCHI_HOSTS_JSON" => json }, path: File.join(dir, "none.yml"))
      registry = Samagotchi::HostRegistry.new(hosts_config: worker)

      expect(JSON.parse(json)["work"]["sampling"]).to eq("temperature" => 0.6, "min_p" => 0.05,
                                                         "chat_template_kwargs" => { "enable_thinking" => false })
      expect(registry.find_entry("work").sampling).to eq(temperature: 0.6, min_p: 0.05, chat_template_kwargs: { enable_thinking: false })
    end
  end

  it "is a known key of hosts and models entries (no unknown-key warning)" do
    data = { "hosts" => { "work" => { "host" => "h", "sampling" => { "temperature" => 0.6 } } },
             "models" => { "m" => { "sampling" => { "top_p" => 0.95 } } } }

    expect(Samagotchi::Config.validate_yaml_sections(data)).to eq([])
  end
end
