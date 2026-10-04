# frozen_string_literal: true

require "samagotchi/model_catalog"

# The hosts' listings as `chi models` (and GET /api/models) shows them: one
# row per listed id, spelled so that it routes back to the host that listed it.
RSpec.describe Samagotchi::ModelCatalog do
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "default" => { host: "localhost", port: 8080 },
      "qwen3" => { host: "qwen.test", port: 8081 },
      "openai" => { host: "openai.test", port: 8082 },
      "box" => { host: "box.test", port: 8083 }
    }, env: {})
  end
  let(:aliases) { { "shadowed-id" => "box:big", "small" => "box:gemma-small", "fast" => "gemma-4" } }
  let(:lists) do
    {
      "default" => %w[gemma-4 qwen3:8b x:free x:batch openai/gpt-4o shadowed-id big],
      "qwen3" => %w[qwen3-14b],
      "openai" => [],
      "box" => %w[big other:batch]
    }
  end
  let(:results) { registry.list_all_models }

  before do
    allow(Samagotchi::ConfigFile).to receive(:model_aliases).and_return(aliases)
    lists.each do |host, ids|
      allow(registry.entries[host].client).to receive(:list_models).and_return(ids.map { |id| { "id" => id } })
    end
  end

  def info(id) = Samagotchi::LLM::ModelInfo.new(id: id, context_window: nil, supports_tools: nil, raw: {})

  describe ".listing" do
    it "orders the default host first, then the others by name, and leaves :batch ids out" do
      listing = described_class.listing(results, registry: registry)

      expect(listing.rows.map { |row| [row.host, row.id] }).to eq([
        %w[default gemma-4], %w[default qwen3:8b], %w[default x:free], %w[default openai/gpt-4o],
        %w[default shadowed-id], %w[default big], %w[box big], %w[qwen3 qwen3-14b]
      ])
      expect(listing.warnings).to eq([])
    end

    it "spells a default-host id bare unless it has a ':', and every other host's as host:id" do
      refs = described_class.listing(results, registry: registry).rows.map(&:ref)

      expect(refs).to eq(%w[gemma-4 default:qwen3:8b default:x:free openai/gpt-4o shadowed-id big box:big qwen3:qwen3-14b])
    end

    it "notes a host's error as a warning" do
      listing = described_class.listing({ "default" => { models: [info("a")], error: nil },
                                          "box" => { models: [], error: "connection refused" } }, registry: registry)

      expect(listing.rows.map(&:ref)).to eq(["a"])
      expect(listing.warnings).to eq(["box: connection refused"])
    end
  end

  describe ".payload" do
    let(:payload) { described_class.payload(results, registry: registry, default_name: "gemma-4") }

    it "routes every offered row back to the host and id that listed it" do
      offered = payload[:models].reject { |row| row[:shadowed_by] }

      expect(offered.size).to eq(7)
      offered.each do |row|
        target = registry.resolve(row[:name])
        expect([target.entry.name, target.bare_model]).to eq([row[:host], row[:id]]), row[:name]
      end
    end

    it "marks a row an alias of the same name shadows" do
      expect(payload[:models].select { |row| row[:shadowed_by] })
        .to eq([{ name: "shadowed-id", host: "default", id: "shadowed-id", shadowed_by: "shadowed-id" }])
    end

    it "lists the aliases under the host their target goes to, with the ref they resolve to" do
      expect(payload[:aliases]).to eq([
        { name: "fast", ref: "gemma-4", host: "default" },
        { name: "shadowed-id", ref: "box:big", host: "box" },
        { name: "small", ref: "box:gemma-small", host: "box" }
      ])
    end

    it "reports the default as its listed row's name, or the resolved ref; an alias default keeps its typed name" do
      expect(payload).to include(default: "gemma-4", default_typed: nil, default_host: "default")
      expect(described_class.payload(results, registry: registry, default_name: "default:GEMMA-4"))
        .to include(default: "gemma-4", default_typed: nil)
      expect(described_class.payload(results, registry: registry, default_name: "small"))
        .to include(default: "box:gemma-small", default_typed: "small")
      expect(described_class.payload(results, registry: registry, default_name: "fast"))
        .to include(default: "gemma-4", default_typed: "fast")
      expect(described_class.payload(results, registry: registry, default_name: nil)).to include(default: nil)
    end

    it "keeps the warnings as an array" do
      failing = { "default" => { models: [info("gemma-4")], error: nil }, "box" => { models: [], error: "no answer in 4 s" } }

      expect(described_class.payload(failing, registry: registry, default_name: "gemma-4")[:warnings])
        .to eq(["box: no answer in 4 s"])
    end
  end
end
