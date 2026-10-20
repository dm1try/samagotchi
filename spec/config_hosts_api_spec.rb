# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/config"
require "samagotchi/host_registry"

# hosts.<name>.api picks how chi talks to a host: llama_cpp (the raw-prompt
# loop) or a chat api: openai or anthropic (the chat loop). Absent, the entry
# talks llama.cpp's own API, as api: llama_cpp.
RSpec.describe "hosts: api" do
  def hosts(yaml_hosts)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, { "hosts" => yaml_hosts }.to_yaml)
      Samagotchi::ConfigFile.hosts_config(env: {}, path: path)
    end
  end

  it "reads api: openai and api: llama_cpp" do
    result = hosts("oai" => { "host" => "h", "port" => 8000, "api" => "openai" }, "m" => { "host" => "h", "api" => "llama_cpp" })
    expect(result["oai"].api).to eq(:openai)
    expect(result["m"].api).to eq(:llama_cpp)
  end

  it "leaves api nil when it is not set" do
    expect(hosts("box" => { "host" => "h" })["box"].api).to be_nil
  end

  it "keeps an entry with the removed transport: key (warned at start), reading only its api" do
    result = hosts("oai" => { "host" => "h", "api" => "openai", "transport" => "llama_cpp" }, "box" => { "host" => "h", "transport" => "vllm" })
    expect(result["oai"].api).to eq(:openai)
    expect(result["box"].api).to be_nil
  end

  it "ignores an entry with an unknown api" do
    result = nil
    expect do
      result = hosts("b" => { "host" => "h", "api" => "grpc" }, "c" => { "host" => "h" })
    end.to output(/ignoring hosts entry 'b': unknown api 'grpc'/).to_stderr
    expect(result.keys).to eq(["c"])
  end

  # chi's own mlx_lm.server and oMLX transports are gone: their OpenAI
  # chat endpoint is the way (api: openai).
  describe "a removed api or transport (mlx, omlx)" do
    let(:line) { "for mlx_lm.server or oMLX use url: http://HOST:PORT/v1, api: openai in a hosts: entry" }

    it "leaves the entry out, saying what to write instead" do
      result = nil
      expect do
        result = hosts("mac" => { "host" => "h", "api" => "omlx" }, "box" => { "host" => "h", "transport" => "MLX" },
                       "c" => { "host" => "h" })
      end.to output(
        "Warning: ignoring hosts entry 'mac': hosts.mac.api: omlx was removed; #{line}\n" \
        "Warning: ignoring hosts entry 'box': hosts.box.transport: MLX was removed; #{line}\n"
      ).to_stderr
      expect(result.keys).to eq(["c"])
    end

    describe "at start (ConfigFile.load!)" do
      def load_config(data, env: {})
        Dir.mktmpdir do |dir|
          path = File.join(dir, "config.yml")
          File.write(path, data.to_yaml)
          Samagotchi::ConfigFile.load!(env: env, path: path)
        end
      end

      it "raises RemovedApi with the one line for a hosts entry, server.transport and the env" do
        expect { load_config({ "hosts" => { "mac" => { "url" => "http://m:8000", "api" => "omlx" } } }) }
          .to raise_error(Samagotchi::ConfigFile::RemovedApi, "config.yml hosts.mac.api: omlx was removed; #{line}")
        expect { load_config({ "server" => { "transport" => "mlx" } }) }
          .to raise_error(Samagotchi::ConfigFile::RemovedApi, "config.yml server.transport: mlx was removed; #{line}")
        expect { load_config({}, env: { "SAMAGOTCHI_SERVER_TRANSPORT" => "omlx" }) }
          .to raise_error(Samagotchi::ConfigFile::RemovedApi, "SAMAGOTCHI_SERVER_TRANSPORT: omlx was removed; #{line}")
      end

      it "loads a config with llama_cpp and openai hosts" do
        data = { "hosts" => { "a" => { "host" => "h", "api" => "llama_cpp" }, "b" => { "url" => "http://h:8000/v1", "api" => "openai" } } }
        expect { expect(load_config(data)).to be(true) }.not_to output.to_stderr
      end

      # server.transport, hosts transport: and SAMAGOTCHI_SERVER_TRANSPORT
      # went with the mlx and omlx transports: any other value changes
      # nothing, so it warns and the config loads.
      it "warns once per removed transport key with any other value, and loads" do
        reason = "was removed: llama.cpp is chi's only raw-prompt transport " \
                 "(a hosts entry without api: is api: llama_cpp); remove it"
        data = { "server" => { "transport" => "llama_cpp" }, "hosts" => { "a" => { "host" => "h", "transport" => "llama_cpp" } } }
        expect { expect(load_config(data, env: { "SAMAGOTCHI_SERVER_TRANSPORT" => "llama_cpp" })).to be(true) }
          .to output("Warning: SAMAGOTCHI_SERVER_TRANSPORT #{reason}\n" \
                     "Warning: config: 'server.transport' #{reason}\n" \
                     "Warning: config: 'hosts.a.transport' #{reason}\n").to_stderr
      end
    end
  end

  it "prints each warning once per process, however often the hosts are read" do
    bad = { "a" => { "host" => "h", "api" => "grpc" } }

    expect { 3.times { hosts(bad) } }.to output(/\A[^\n]*ignoring hosts entry 'a'[^\n]*\n\z/).to_stderr
    expect { hosts("b" => { "host" => "h", "api" => "grpc" }) }.to output(/ignoring hosts entry 'b'/).to_stderr
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
  end

  describe "an entry that raises while it is read" do
    before do
      allow(Samagotchi::HostModel).to receive(:parse_map).and_call_original
      allow(Samagotchi::HostModel).to receive(:parse_map).with(anything, "broken").and_raise(NoMethodError, "boom")
    end

    it "drops only that entry, and says why (stderr and the log)" do
      allow(Samagotchi::Log).to receive(:warn).and_call_original
      result = nil
      expect { result = hosts("broken" => { "host" => "x" }, "fine" => { "host" => "h" }) }
        .to output(/ignoring hosts entry 'broken': NoMethodError: boom/).to_stderr
      expect(result.keys).to eq(["fine"])
      expect(Samagotchi::Log).to have_received(:warn)
        .with(:config, "config_warning", echo: a_string_including("hosts entry 'broken'"))
    end
  end

  describe "a failure outside the entries" do
    it "logs hosts_config_failed instead of answering {} silently" do
      allow(Samagotchi::ConfigFile).to receive(:warn_duplicate_host_models).and_raise(TypeError, "bad section")
      allow(Samagotchi::Log).to receive(:error)

      expect(hosts("fine" => { "host" => "h" })).to eq({})
      expect(Samagotchi::Log).to have_received(:error)
        .with(:config, "hosts_config_failed", error: "TypeError", message: "bad section")
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
