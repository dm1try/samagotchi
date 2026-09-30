# frozen_string_literal: true

require "spec_helper"
require "samagotchi/memory_bundle/manifest"
require "samagotchi/memory_bundle/source"
require "samagotchi/memory_bundle/system_bundle"

# The profiles chi ships (lib/samagotchi/bundles/core and dev): meta
# bundles whose manifest names members in includes: (docs/memory.md).
RSpec.describe "The shipped bundle profiles" do
  shipped_dir = Samagotchi::MemoryBundle::SourceNormalizer::SHIPPED_DIR
  manifests = Dir.children(shipped_dir).sort.filter_map do |dir|
    path = File.join(shipped_dir, dir)
    next unless File.file?(File.join(path, "manifest.yml"))

    [dir, Samagotchi::MemoryBundle::Manifest.read(dir: path)]
  end.to_h
  metas = manifests.select { |_, m| m.meta? }
  plain = manifests.reject { |_, m| m.meta? || m.name == Samagotchi::MemoryBundle::SystemBundle::BUNDLE_NAME }

  it "ships core and dev" do
    expect(metas.keys).to eq(%w[core dev])
    expect(metas.transform_values(&:name)).to eq("core" => "core", "dev" => "dev")
  end

  it "core is the safety set" do
    expect(metas["core"].includes).to eq(%w[loop-guard check-in guardrails])
  end

  it "puts every shipped bundle but the system bundle and the profiles in exactly one profile" do
    members = metas.values.flat_map(&:includes)
    expect(members.tally.select { |_, n| n > 1 }).to eq({})
    expect(members.sort).to eq(plain.keys.sort)
  end

  it "names only shipped bundles that aren't metas, by the name their manifest gives" do
    metas.each_value do |meta|
      meta.includes.each do |member|
        expect(plain).to have_key(member), "#{meta.name} includes #{member}, which chi doesn't ship as a plain bundle"
        expect(plain[member].name).to eq(member)
      end
    end
  end

  it "keeps a profile's dir to its manifest.yml: no files, hooks or plugin" do
    metas.each do |dir, meta|
      expect(Dir.children(File.join(shipped_dir, dir))).to eq(["manifest.yml"])
      expect([meta.files, meta.hooks, meta.plugin]).to eq([{}, {}, nil])
      expect(meta.scope).to eq("system")
    end
  end
end
