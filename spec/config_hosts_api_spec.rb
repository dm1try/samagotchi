# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/config"
require "samagotchi/host_registry"

# hosts.<name>.api picks how chi talks to a host: a raw-prompt api
# (llama_cpp/mlx/omlx, which is also the Client transport) or openai (the chat
# loop). Absent, the entry stays as before: no api, transport as configured.
RSpec.describe "hosts: api" do
  def hosts(yaml_hosts)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, { "hosts" => yaml_hosts }.to_yaml)
      Samagotchi::ConfigFile.hosts_config(env: {}, path: path)
    end
  end

  it "reads api: openai and keeps the transport as given" do
    result = hosts("oai" => { "host" => "h", "port" => 8000, "api" => "openai" })
    expect(result["oai"]).to include(api: :openai, transport: nil)
  end

  it "uses an explicit raw api as the transport when none is set" do
    expect(hosts("m" => { "host" => "h", "api" => "mlx" })["m"]).to include(api: :mlx, transport: :mlx)
  end

  it "leaves api and transport nil when neither is set (the global transport still applies)" do
    expect(hosts("box" => { "host" => "h" })["box"]).to include(api: nil, transport: nil)
  end

  it "allows api: openai with a transport (the transport only affects listing/probing)" do
    expect(hosts("oai" => { "host" => "h", "api" => "openai", "transport" => "omlx" })["oai"])
      .to include(api: :openai, transport: :omlx)
  end

  it "ignores an entry whose raw api and transport disagree, and an unknown api" do
    result = nil
    expect do
      result = hosts("a" => { "host" => "h", "api" => "mlx", "transport" => "omlx" },
                     "b" => { "host" => "h", "api" => "grpc" },
                     "c" => { "host" => "h" })
    end.to output(/ignoring hosts entry 'a'.*\n.*ignoring hosts entry 'b'/).to_stderr
    expect(result.keys).to eq(["c"])
  end

  it "prints each warning once per process, however often the hosts are read" do
    bad = { "a" => { "host" => "h", "api" => "grpc" } }

    expect { 3.times { hosts(bad) } }.to output(/\A[^\n]*ignoring hosts entry 'a'[^\n]*\n\z/).to_stderr
    expect { hosts("b" => { "host" => "h", "api" => "grpc" }) }.to output(/ignoring hosts entry 'b'/).to_stderr
  end

  it "passes api to workers through SAMAGOTCHI_HOSTS_JSON" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, { "hosts" => { "oai" => { "host" => "h", "port" => 8000, "api" => "openai" },
                                      "box" => { "host" => "b" } } }.to_yaml)
      json = Samagotchi::ConfigFile.hosts_json_for_env(env: {}, path: path)
      worker = Samagotchi::ConfigFile.hosts_config(env: { "SAMAGOTCHI_HOSTS_JSON" => json }, path: File.join(dir, "none.yml"))

      expect(worker["oai"]).to include(host: "h", port: 8000, api: :openai)
      expect(worker["box"]).to include(host: "b", api: nil, transport: nil)
    end
  end

  describe "enabled: false" do
    let(:yaml_hosts) do
      { "main" => { "host" => "h" }, "Box" => { "host" => "b", "enabled" => "FALSE" },
        "spare" => { "host" => "s", "enabled" => false }, "on" => { "host" => "o", "enabled" => true } }
    end

    it "leaves the entry out of hosts_config and lists it in disabled_host_names" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "config.yml")
        File.write(path, { "hosts" => yaml_hosts }.to_yaml)

        expect(Samagotchi::ConfigFile.hosts_config(env: {}, path: path).keys).to eq(%w[main on])
        expect(Samagotchi::ConfigFile.disabled_host_names(env: {}, path: path)).to eq(%w[box spare])
      end
    end

    it "carries the disabled names to a worker that has no config.yml" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "config.yml")
        File.write(path, { "hosts" => yaml_hosts }.to_yaml)
        worker_env = { "SAMAGOTCHI_HOSTS_JSON" => Samagotchi::ConfigFile.hosts_json_for_env(env: {}, path: path) }
        none = File.join(dir, "none.yml")

        expect(Samagotchi::ConfigFile.hosts_config(env: worker_env, path: none).keys).to eq(%w[main on])
        expect(Samagotchi::ConfigFile.disabled_host_names(env: worker_env, path: none)).to eq(%w[box spare])
      end
    end
  end

  describe Samagotchi::HostRegistry do
    it "marks openai hosts as chat hosts, everything else (and entries without api) as raw" do
      registry = described_class.new(hosts_config: {
        "oai" => { host: "h", port: 1, api: :openai },
        "box" => { host: "b", port: 2 }
      })
      expect(registry.entries["oai"]).to be_chat
      expect(registry.entries["box"]).not_to be_chat
      expect(registry.resolve("oai:m").entry.api).to eq(:openai)
    end
  end
end
