# frozen_string_literal: true

require "yaml"
require "samagotchi/config"
require "samagotchi/host_model"

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

  it "keeps the first of two ids that differ only by case" do
    expect(parse("[rr/A, rr/a]").values.map(&:id)).to eq(%w[rr/A])
  end
end
