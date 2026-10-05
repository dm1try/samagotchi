# frozen_string_literal: true

require "json"
require "tmpdir"
require "spec_helper"
require "samagotchi/model_list_store"
require "samagotchi/host_registry"

# The host model ids saved between processes: `chi send --new --model` and
# delegate check a model id against them before a worker is spawned.
RSpec.describe Samagotchi::ModelListStore do
  let(:state_home) { Dir.mktmpdir("model-lists") }
  let(:file) { File.join(state_home, "samagotchi", described_class::FILE) }

  around { |example| with_env("XDG_STATE_HOME" => state_home) { example.run } }

  after { FileUtils.rm_rf(state_home) }

  describe ".path" do
    it "is <XDG_STATE_HOME>/samagotchi/model_lists.json, next to the sessions and history.json" do
      expect(described_class.path).to eq(file)
    end
  end

  describe ".save and .find" do
    it "round-trips a host's ids and the time, leaving no temporary file" do
      saved = described_class.save("box", %w[gemma-small qwen3], at: 1_700_000_000)

      expect(saved.ids).to eq(%w[gemma-small qwen3])
      expect(saved.at).to eq(1_700_000_000)
      expect(File.read(file)).to eq(<<~JSON)
        {
          "box": {
            "ids": [
              "gemma-small",
              "qwen3"
            ],
            "at": 1700000000
          }
        }
      JSON
      expect(Dir.children(File.dirname(file)).grep(/\.tmp\z/)).to be_empty
    end

    it "finds a host by name whatever the case, and says whether it lists an id" do
      described_class.save("Box", ["gemma-small"], at: 100)

      list = described_class.find("box")
      expect([list.host, list.ids, list.at]).to eq(["box", ["gemma-small"], 100])
      expect(list.known?("GEMMA-SMALL")).to be(true)
      expect(list.known?("gemma")).to be(false)
    end

    it "keeps the other hosts' entries" do
      described_class.save("box", ["a"])
      described_class.save("openrouter", ["org/model"])

      expect(described_class.find("box").ids).to eq(["a"])
      expect(described_class.find("openrouter").ids).to eq(["org/model"])
    end

    it "does not save an empty list (no evidence the host serves nothing)" do
      expect(described_class.save("box", [])).to be_nil
      expect(described_class.find("box")).to be_nil
      expect(File.exist?(file)).to be(false)
    end

    it "reads no list at all when the file is missing" do
      expect(described_class.find("box")).to be_nil
      expect(described_class.all).to eq({})
    end

    it "reads no list from bad JSON, never raising" do
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, "{not json")

      expect(described_class.find("box")).to be_nil
      expect(described_class.all).to eq({})
    end

    it "reads no list from a file that is not an object" do
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, "[]")

      expect(described_class.find("box")).to be_nil
    end

    it "skips an entry with no ids or no time" do
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, JSON.generate("box" => { "ids" => [] }, "qwen" => { "ids" => ["m"], "at" => 0 }))

      expect(described_class.find("box")).to be_nil
      expect(described_class.find("qwen")).to be_nil
    end

    it "reads an unreadable file as no list, never raising" do
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, JSON.generate("box" => { "ids" => ["m"], "at" => 100 }))
      allow(File).to receive(:read).and_raise(Errno::EACCES)

      expect(described_class.find("box")).to be_nil
    end

    it "says nothing when the store can't be written" do
      allow(File).to receive(:rename).and_raise(Errno::EACCES)

      expect(described_class.save("box", ["a"])).to be_nil
      expect(described_class.find("box")).to be_nil
    end

    describe "age" do
      it "is stale after a week and current before" do
        list = described_class.save("box", ["a"], at: 1_000_000)

        expect(list.stale?(now: 1_000_000 + described_class::TTL_SECONDS)).to be(false)
        expect(list.age(now: 1_000_000 + 3600)).to eq(3600)
        expect(list.stale?(now: 1_000_000 + described_class::TTL_SECONDS + 1)).to be(true)
      end
    end
  end

  describe "HostRegistry" do
    let(:registry) do
      Samagotchi::HostRegistry.new(hosts_config: {
        "default" => { host: "localhost", port: 8080 },
        "box" => { host: "box.test", port: 8081 }
      })
    end

    def info(id) = Samagotchi::LLM::ModelInfo.new(id: id, context_window: nil, supports_tools: nil, raw: {})

    it "saves each host's list after a successful listing" do
      allow(registry).to receive(:list_models_for) do |entry|
        entry.name == "box" ? [info("gemma-small")] : [info("qwen3"), info("m")]
      end

      registry.list_all_models

      expect(described_class.find("box").ids).to eq(["gemma-small"])
      expect(described_class.find("default").ids).to eq(%w[qwen3 m])
    end

    it "keeps the last good list when a host's listing fails" do
      described_class.save("box", ["gemma-small"], at: 100)
      allow(registry).to receive(:list_models_for).and_raise(Errno::ECONNREFUSED)

      registry.list_all_models

      expect(described_class.find("box").ids).to eq(["gemma-small"])
      expect(described_class.find("box").at).to eq(100)
      expect(described_class.find("default")).to be_nil
    end

    it "overwrites an old list with the new one" do
      described_class.save("box", ["old-model"], at: 100)
      allow(registry).to receive(:list_models_for).and_return([info("new-model")])

      registry.list_all_models

      expect(described_class.find("box").ids).to eq(["new-model"])
    end
  end
end
