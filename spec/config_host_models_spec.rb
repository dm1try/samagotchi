# frozen_string_literal: true

require "json"
require "tmpdir"
require "yaml"
require "samagotchi/config"
require "samagotchi/host_registry"

# hosts.<name>.models: the model ids a host serves whatever its /v1/models
# says, parsed into each host's entry and passed to workers.
RSpec.describe "hosts.<name>.models" do
  def with_config(yaml_hosts)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, { "hosts" => yaml_hosts }.to_yaml)
      yield path, dir
    end
  end

  def hosts(yaml_hosts)
    with_config(yaml_hosts) { |path| Samagotchi::ConfigFile.hosts_config(env: {}, path: path) }
  end

  it "parses each host's models by downcased id, {} when unset" do
    result = hosts("work" => { "url" => "https://gateway.example/v1", "models" => { "rr/DeepSeek" => nil } },
                   "box" => { "host" => "box.test" })

    expect(result["work"][:models].transform_values(&:id)).to eq("rr/deepseek" => "rr/DeepSeek")
    expect(result["box"][:models]).to eq({})
  end

  it "drops a disabled host's models with it" do
    result = hosts("work" => { "host" => "w", "enabled" => false, "models" => ["rr/x"] }, "box" => { "host" => "b" })

    expect(result.keys).to eq(["box"])
  end

  it "passes the declared ids to workers through SAMAGOTCHI_HOSTS_JSON" do
    with_config("work" => { "url" => "https://gateway.example/v1", "models" => %w[rr/A rr/b] }) do |path, dir|
      json = Samagotchi::ConfigFile.hosts_json_for_env(env: {}, path: path)
      worker = Samagotchi::ConfigFile.hosts_config(env: { "SAMAGOTCHI_HOSTS_JSON" => json },
                                                   path: File.join(dir, "none.yml"))

      expect(worker["work"][:models].transform_values(&:id)).to eq("rr/a" => "rr/A", "rr/b" => "rr/b")
    end
  end

  it "warns once when two hosts declare the same id, naming where a bare one goes" do
    expect(Samagotchi::ConfigFile).to receive(:warn_once)
      .with("Warning: hosts.a.models and hosts.b.models both declare rr/dup; a bare rr/dup goes to a")

    hosts("a" => { "host" => "a", "models" => ["rr/dup"] }, "b" => { "host" => "b", "models" => ["RR/dup"] })
  end

  it "names the default host as the winner of a duplicate when it declares the id" do
    expect(Samagotchi::ConfigFile).to receive(:warn_once)
      .with("Warning: hosts.a.models and hosts.default.models both declare rr/dup2; a bare rr/dup2 goes to default")

    hosts("a" => { "host" => "a", "models" => ["rr/dup2"] }, "default" => { "host" => "d", "models" => ["rr/dup2"] })
  end

  describe "validation" do
    def problems(yaml) = Samagotchi::Config.validate_yaml_sections(YAML.safe_load(yaml))

    it "takes models: on a host and checks each entry's keys" do
      expect(problems(<<~YAML)).to eq(["config: unknown key 'hosts.work.models.rr/b.prise'"])
        hosts:
          work:
            url: "https://gateway.example/v1"
            models:
              rr/a:
              rr/b: {prise: 1}
          box:
            host: box.test
            models: [rr/c]
      YAML
    end
  end
end
