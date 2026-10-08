# frozen_string_literal: true

require "yaml"
require "samagotchi/config"
require "samagotchi/host_model"
require "samagotchi/llm/openai_chat"

# hosts.<name>.models: the ids a host serves whatever its /v1/models lists.
RSpec.describe Samagotchi::HostModel do
  def parse(yaml) = described_class.parse_map(YAML.safe_load(yaml), "work")

  it "reads the map form: bare keys and empty maps, by downcased id, kept as written" do
    models = parse("{rr/DeepSeek-v4.1: , rr/qwen3.8-27b: {}}")

    expect(models.keys).to eq(%w[rr/deepseek-v4.1 rr/qwen3.8-27b])
    expect(models["rr/deepseek-v4.1"].id).to eq("rr/DeepSeek-v4.1")
  end

  it "reads the list form as the map with no settings" do
    expect(parse("[rr/a, rr/b]")).to eq(parse("{rr/a: , rr/b: }"))
  end

  it "reads an entry's price, by host, nil without one" do
    models = parse("{rr/a: {price: {input: 0.27, cache_read: 0.07, output: 1.1}}, rr/b: }")

    expect(models["rr/a"].price).to eq(Samagotchi::ModelPrice.new(input: 0.27, cache_read: 0.07, cache_write: 0.27, output: 1.1))
    expect(models["rr/b"].price).to be_nil
    expect(models["rr/a"].to_config).to eq("price" => { "input" => 0.27, "cache_read" => 0.07, "cache_write" => 0.27, "output" => 1.1 })
    expect(models["rr/b"].to_config).to be_nil
  end

  it "reads served: as exact ids or any, and says whether a served model is one of them" do
    models = parse("{rr/a: {served: [fireworks/A, baseten/a]}, rr/b: {served: any}, rr/c: }")

    expect(models["rr/a"].serves?("FIREWORKS/a")).to be(true)
    expect(models["rr/a"].serves?("together/a")).to be(false)
    expect(models["rr/b"].serves?("anything/at-all")).to be(true)
    expect(models["rr/c"].serves?("rr/c")).to be(false)
    expect(models["rr/a"].to_config).to eq("served" => %w[fireworks/A baseten/a])
    expect(models["rr/b"].to_config).to eq("served" => "any")
  end

  it "warns once and drops a served: that is neither a list of ids nor any" do
    expect(Samagotchi::ConfigFile).to receive(:warn_once)
      .with("Warning: hosts.work.models.rr/a.served must be a list of model ids or any; ignored").twice

    expect(parse("{rr/a: {served: fireworks/a}}")["rr/a"].served).to be_nil
    expect(parse("{rr/a: {served: [1, x]}}")["rr/a"].served).to be_nil
  end

  it "is empty when unset" do
    expect(described_class.parse_map(nil, "work")).to eq({})
  end

  it "warns once and skips a non-string id or an entry that is neither empty nor a mapping" do
    expect(Samagotchi::ConfigFile).to receive(:warn_once).with("Warning: hosts.work.models: 42 is not a model id; ignored")
    expect(Samagotchi::ConfigFile).to receive(:warn_once).with("Warning: hosts.work.models.rr/b must be empty or a mapping; ignored")

    expect(parse("{42: , rr/b: cheap, rr/c: }").keys).to eq(%w[rr/c])
  end

  it "warns once and ignores a value that is neither a map nor a list" do
    expect(Samagotchi::ConfigFile).to receive(:warn_once)
      .with("Warning: hosts.work.models must be a map or a list of model ids; ignored")

    expect(parse("rr/a")).to eq({})
  end

  describe ".rows" do
    def info(id) = Samagotchi::LLM::ModelInfo.new(id: id, context_window: nil, supports_tools: nil, raw: {})
    def entry(*ids) = Struct.new(:models).new(described_class.parse_map(ids, "spec"))

    it "puts a host's declared ids first, one row in the host's spelling for an id it also lists, and the listed rest after" do
      rows = described_class.rows({ "work" => { models: [info("a"), info("rr/x"), info("b")], error: nil } },
                                  { "work" => entry("RR/x", "rr/y") })

      expect(rows["work"].map { |r| [r.id, r.configured, r.info&.id] })
        .to eq([["rr/x", true, "rr/x"], ["rr/y", true, nil], ["a", false, "a"], ["b", false, "b"]])
    end

    it "shows a host that lists nothing its declared ids, and an errored host nothing" do
      rows = described_class.rows({ "work" => { models: [], error: nil }, "down" => { models: [], error: "refused" } },
                                  { "work" => entry("rr/x"), "down" => entry("rr/z") })

      expect(rows.transform_values { |rs| rs.map(&:id) }).to eq("work" => ["rr/x"])
    end
  end

  it "keeps the first of two ids that differ only by case" do
    expect(parse("[rr/A, rr/a]").values.map(&:id)).to eq(%w[rr/A])
  end
end
