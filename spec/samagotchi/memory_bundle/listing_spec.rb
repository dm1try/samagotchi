# frozen_string_literal: true

require "spec_helper"
require "json"
require "samagotchi/memory_bundle/listing"

RSpec.describe Samagotchi::MemoryBundle::Listing do
  let(:tmp) { Dir.mktmpdir("bundle-listing") }
  let(:shipped_dir) { File.join(tmp, "shipped") }

  def ship(source, name:, version:, description: "")
    dir = File.join(shipped_dir, source)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "manifest.yml"), { "name" => name, "version" => version, "description" => description }.to_yaml)
  end

  def install(name, version:)
    dir = File.join(tmp, "bundles", name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "manifest.json"),
               JSON.generate("version" => version, "scope" => "system", "files" => { "a.md" => {} }, "installed_at" => "2026-09-26"))
  end

  before { Samagotchi::MemoryBundle::Provenance.bundles_dir_override = File.join(tmp, "bundles") }

  after do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = nil
    FileUtils.remove_entry(tmp)
  end

  it "reads the bundles shipped with chi, keyed by the name install takes, without the system bundle" do
    shipped = described_class.shipped
    expect(shipped.map { |s| [s.source, s.name] }).to include(["guardrails", "guardrails"], ["known-names", "known-names"], ["loop-guard", "loop-guard"])
    expect(shipped.map(&:name)).not_to include("samagotchi-system")
  end

  it "skips a shipped dir without a readable manifest" do
    ship("good", name: "good", version: "1.0")
    FileUtils.mkdir_p(File.join(shipped_dir, "empty"))
    FileUtils.mkdir_p(File.join(shipped_dir, "bad"))
    File.write(File.join(shipped_dir, "bad", "manifest.yml"), "version: 1\n")

    expect(described_class.shipped(dir: shipped_dir).map(&:name)).to eq(["good"])
  end

  it "splits shipped bundles into installed (with a newer shipped version) and available" do
    ship("guardrails", name: "guardrails", version: "0.2.0", description: "rules")
    ship("btw", name: "btw", version: "0.1.1")
    ship("system", name: "samagotchi-system", version: "0.2.0")
    install("guardrails", version: "0.1.0")
    install("samagotchi-system", version: "0.1.30")
    install("mine", version: "3")

    shipped = described_class.shipped(dir: shipped_dir)
    installed = described_class.installed(shipped: shipped)

    expect(installed.map(&:name)).to eq(%w[guardrails mine samagotchi-system])
    expect(installed.first).to have_attributes(version: "0.1.0", files: 1, installed_at: "2026-09-26")
    expect(installed.first.upgrade).to have_attributes(source: "guardrails", version: "0.2.0")
    expect(installed.map(&:upgrade).drop(1)).to eq([nil, nil])
    expect(shipped.map(&:name)).not_to include("samagotchi-system")
    expect(described_class.available(shipped: shipped, installed: installed).map(&:source)).to eq(["btw"])
  end

  it "shows a bundle whose manifest.json doesn't parse as unreadable, without failing the rest" do
    install("good", version: "1.0")
    FileUtils.mkdir_p(File.join(tmp, "bundles", "broken"))
    File.write(File.join(tmp, "bundles", "broken", "manifest.json"), "{bad")
    FileUtils.mkdir_p(File.join(tmp, "bundles", "list"))
    File.write(File.join(tmp, "bundles", "list", "manifest.json"), "[1]")

    installed = described_class.installed(shipped: [])
    expect(installed.map { |b| [b.name, b.error] }).to eq([["broken", "manifest.json unreadable"], ["good", nil], ["list", "manifest.json unreadable"]])
    expect(installed[1].version).to eq("1.0")
  end

  it "has nothing installed when the bundles dir is missing" do
    expect(described_class.installed(shipped: [])).to eq([])
  end
end
