# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/config"
require "samagotchi/host_registry"

# hosts.<name>.url is an alternative to host/port (http or https, with an
# optional path such as /v1), and api_key_env names the variable holding the
# host's API key. The key itself never leaves the environment.
RSpec.describe "hosts: url and api_key_env" do
  def hosts(yaml_hosts)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, { "hosts" => yaml_hosts }.to_yaml)
      Samagotchi::ConfigFile.hosts_config(env: {}, path: path)
    end
  end

  it "takes host, port and scheme from url, keeping the url as given" do
    result = hosts("fw" => { "url" => "https://api.fireworks.ai/inference/v1/", "api" => "openai",
                             "api_key_env" => "FIREWORKS_API_KEY" })

    expect(result["fw"]).to have_attributes(host: "api.fireworks.ai", port: 443, scheme: "https",
                                            url: "https://api.fireworks.ai/inference/v1", api: :openai,
                                            api_key_env: "FIREWORKS_API_KEY")
  end

  it "reads a plain http url with a port" do
    expect(hosts("box" => { "url" => "http://10.0.0.5:8081" })["box"])
      .to have_attributes(host: "10.0.0.5", port: 8081, scheme: "http", url: "http://10.0.0.5:8081")
  end

  it "ignores an entry with both url and host/port, a bad url, or a bad variable name" do
    result = nil
    expect do
      result = hosts("both" => { "url" => "http://a:1", "host" => "a" },
                     "ftp" => { "url" => "ftp://a/v1" },
                     "junk" => { "url" => "not a url" },
                     "key" => { "host" => "h", "api_key_env" => "has space" },
                     "ok" => { "host" => "h" })
    end.to output(/'both'.*url or host.*\n.*'ftp'.*\n.*'junk'.*\n.*'key'.*api_key_env/).to_stderr
    expect(result.keys).to eq(["ok"])
  end

  it "reads first_token_timeout in seconds (0 = off) and ignores a bad one with a warning" do
    result = nil
    expect do
      result = hosts("or" => { "url" => "https://or.test/v1", "first_token_timeout" => 90 },
                     "off" => { "host" => "h", "first_token_timeout" => 0 },
                     "bad" => { "host" => "h", "first_token_timeout" => "soon" })
    end.to output(/'bad'.*first_token_timeout/).to_stderr
    expect(result["or"].first_token_timeout).to eq(90)
    expect(result["off"].first_token_timeout).to eq(0)
    expect(result["bad"].first_token_timeout).to be_nil
  end

  it "reads remote: true/false, ignores anything else with a warning, and passes it to workers" do
    result = nil
    expect do
      result = hosts("lan" => { "url" => "https://lan.example/v1", "remote" => false },
                     "far" => { "host" => "box", "remote" => true },
                     "bad" => { "host" => "h", "remote" => "maybe" })
    end.to output(/'bad'.*remote must be true or false/).to_stderr
    expect(result.transform_values(&:remote)).to eq("lan" => false, "far" => true, "bad" => nil)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, { "hosts" => { "lan" => { "url" => "https://lan.example/v1", "remote" => false } } }.to_yaml)
      json = Samagotchi::ConfigFile.hosts_json_for_env(env: {}, path: path)
      worker = Samagotchi::ConfigFile.hosts_config(env: { "SAMAGOTCHI_HOSTS_JSON" => json }, path: File.join(dir, "none.yml"))
      expect(worker["lan"].remote).to be(false)
    end
  end

  it "passes url and api_key_env to workers, never the key" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, { "hosts" => { "fw" => { "url" => "https://api.example.test/v1", "api" => "openai",
                                                "api_key_env" => "EXAMPLE_KEY", "first_token_timeout" => 45 } } }.to_yaml)
      json = Samagotchi::ConfigFile.hosts_json_for_env(env: { "EXAMPLE_KEY" => "sk-secret" }, path: path)
      worker = Samagotchi::ConfigFile.hosts_config(env: { "SAMAGOTCHI_HOSTS_JSON" => json }, path: File.join(dir, "none.yml"))

      expect(json).not_to include("sk-secret")
      expect(worker["fw"]).to have_attributes(url: "https://api.example.test/v1", host: "api.example.test", port: 443,
                                              api_key_env: "EXAMPLE_KEY", api: :openai, first_token_timeout: 45)
    end
  end

  describe Samagotchi::HostRegistry::HostEntry do
    def entry(config)
      Samagotchi::HostRegistry.new(hosts_config: { "x" => config }).entries["x"]
    end

    it "uses the url as the OpenAI base url, and scheme://host:port as the root" do
      remote = entry(name: "x", host: "api.example.test", port: 443, scheme: "https",
                     url: "https://api.example.test/inference/v1", api: :openai, api_key_env: "K")

      expect(remote.openai_base_url).to eq("https://api.example.test/inference/v1")
      expect(remote.root_url).to eq("https://api.example.test:443")
      expect(remote.api_key_env).to eq("K")
    end

    it "keeps root_url/v1 for a host/port entry" do
      local = entry(name: "x", host: "box", port: 8081)

      expect(local.openai_base_url).to eq("http://box:8081/v1")
      expect(local.root_url).to eq("http://box:8081")
    end

    describe "#remote?" do
      it "is decided by the address: https, or an http IP address that isn't loopback, private or link-local" do
        expect(entry(name: "x", host: "openrouter.ai", port: 443, scheme: "https", api_key_env: "K")).to be_remote
        expect(entry(name: "x", host: "203.0.113.7", port: 8080, scheme: "http")).to be_remote
        expect(entry(name: "x", host: "2001:db8::1", port: 8080, scheme: "http")).to be_remote
        %w[localhost 127.0.0.1 ::1 10.1.2.3 172.20.0.5 192.168.1.29 169.254.1.1 fd00::5 fe80::1 box mac.local].each do |host|
          expect(entry(name: "x", host: host, port: 8080, scheme: "http")).not_to be_remote, host
        end
      end

      it "calls an http name with a public-looking suffix remote, and keeps local names local" do
        %w[gpu.example.com api.provider.io GPU.Example.COM.].each do |host|
          expect(entry(name: "x", host: host, port: 8080, scheme: "http")).to be_remote, host
        end
        %w[box LOCALHOST mac.local gpu.lan nas.home router.home.arpa llm.corp.internal pc.tail1234.ts.net
           srv.localdomain fritz.box ml.test].each do |host|
          expect(entry(name: "x", host: host, port: 8080, scheme: "http")).not_to be_remote, host
        end
        expect(entry(name: "x", host: "gpu.example.com", port: 8080, scheme: "http", remote: false)).not_to be_remote
      end

      it "doesn't count an API key: a keyed llama.cpp on the LAN stays local (/props, its timeouts and list cache)" do
        lan = entry(name: "x", host: "192.168.1.29", port: 8080, scheme: "http", api_key_env: "BOX_KEY")
        expect(lan).not_to be_remote
        expect(lan.models_ttl).to eq(Samagotchi::HostRegistry::CACHE_TTL_SECONDS)
        expect(lan.first_token_limit).to be_nil
      end

      it "follows hosts.<name>.remote when it is set" do
        expect(entry(name: "x", host: "192.168.1.29", port: 8080, remote: true)).to be_remote
        expect(entry(name: "x", host: "lan.example", port: 443, scheme: "https", remote: false)).not_to be_remote
      end
    end

    it "gives the raw client the entry's scheme" do
      raw = entry(name: "x", host: "box", port: 443, scheme: "https", url: "https://box")

      expect(raw.client.instance_variable_get(:@scheme)).to eq("https")
    end
  end
end

RSpec.describe "window_tokens on hosts: and models: entries" do
  it "reads a positive integer and ignores anything else with a warning; hosts pass it to workers" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, { "hosts" => { "box" => { "host" => "box", "window_tokens" => 65_536 },
                                      "bad" => { "host" => "h", "window_tokens" => "big" } },
                         "models" => { "Qwen3" => { "window_tokens" => 32_768 }, "odd" => { "window_tokens" => -1 } } }.to_yaml)
      hosts = models = nil
      expect do
        hosts = Samagotchi::ConfigFile.hosts_config(env: {}, path: path)
        models = Samagotchi::ConfigFile.model_settings(env: {}, path: path)
      end.to output(/'bad'.*window_tokens must be a positive number of tokens.*\n.*odd.*window_tokens/m).to_stderr
      expect(hosts.transform_values(&:window_tokens)).to eq("box" => 65_536, "bad" => nil)
      expect(models["qwen3"].window_tokens).to eq(32_768)
      expect(models["odd"]).to have_attributes(window_tokens: nil)
      expect(Samagotchi::HostRegistry.new(hosts_config: hosts).entries["box"].window_tokens).to eq(65_536)

      json = Samagotchi::ConfigFile.hosts_json_for_env(env: {}, path: path)
      worker = Samagotchi::ConfigFile.hosts_config(env: { "SAMAGOTCHI_HOSTS_JSON" => json }, path: File.join(dir, "none.yml"))
      expect(worker["box"].window_tokens).to eq(65_536)
    end
  end
end

RSpec.describe "llm_context_strategy on hosts: entries" do
  it "passes a host's layers and apply rule to workers, none included" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, { "hosts" => { "box" => { "host" => "box", "llm_context_strategy" => %w[stale forget],
                                                 "llm_context_apply" => "turn_end", "llm_context_budget_tokens" => 64_000 },
                                      "off" => { "host" => "off", "llm_context_strategy" => "none" },
                                      "plain" => { "host" => "plain" } } }.to_yaml)

      json = Samagotchi::ConfigFile.hosts_json_for_env(env: {}, path: path)
      worker = Samagotchi::ConfigFile.hosts_config(env: { "SAMAGOTCHI_HOSTS_JSON" => json }, path: File.join(dir, "none.yml"))

      expect(worker.transform_values(&:llm_context_strategy)).to eq("box" => %i[stale forget], "off" => [],
                                                                    "plain" => nil)
      expect(worker.transform_values(&:llm_context_apply)).to eq("box" => :turn_end, "off" => nil, "plain" => nil)
      expect(worker.transform_values(&:llm_context_budget_tokens)).to eq("box" => 64_000, "off" => nil, "plain" => nil)
    end
  end
end
