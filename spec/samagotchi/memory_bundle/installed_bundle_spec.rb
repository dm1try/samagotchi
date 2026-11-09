# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "samagotchi/memory_bundle/installed_bundle"

RSpec.describe Samagotchi::MemoryBundle::InstalledBundle do
  let(:hook) { Samagotchi::MemoryBundle::BundleHook }

  describe ".parse" do
    it "reads a full record (string keys, as manifest.json holds them)" do
      raw = {
        "name" => "full", "version" => "1.2.0", "scope" => "project", "source" => "/src/full",
        "installed_at" => "2026-10-10T10:00:00+02:00", "trust_level" => "reviewed", "source_commit" => "abc123",
        "requires_chi" => ">= 0.50", "files" => { "a.md" => { "checksum" => "aa", "conflict" => true, "description" => "A" } },
        "hooks" => { "g.rb" => { "sha256" => "sha256:hh", "event" => "before_tool_call", "on_error" => "fail_closed", "priority" => 10 } },
        "guardrails" => { "r.yml" => { "sha256" => "sha256:rr" } }, "scripts" => { "s.rb" => { "sha256" => "sha256:ss" } },
        "plugin" => { "file" => "p.rb", "sha256" => "sha256:pp" }, "needs" => [{ "command" => "gh" }],
        "includes" => %w[a b], "context_providers" => [{ "match" => "x" }], "session_settings" => ["cap"]
      }
      bundle = described_class.parse("full", JSON.parse(JSON.generate(raw)))
      expect(bundle).to have_attributes(
        name: "full", version: "1.2.0", scope: "project", source: "/src/full", installed_at: "2026-10-10T10:00:00+02:00",
        source_commit: "abc123", error: nil,
        files: { "a.md" => { checksum: "aa", conflict: true, description: "A" } },
        hooks: { "g.rb" => hook.new(sha256: "sha256:hh") },
        guardrails: { "r.yml" => "sha256:rr" }, scripts: { "s.rb" => "sha256:ss" },
        plugin: Samagotchi::MemoryBundle::PluginRef.new(file: "p.rb", sha256: "sha256:pp"), includes: %w[a b],
        mirror: { "trust_level" => "reviewed", "requires_chi" => ">= 0.50", "needs" => [{ "command" => "gh" }],
                  "context_providers" => [{ "match" => "x" }], "session_settings" => ["cap"] }
      )
      expect([bundle.effective_scope, bundle.profile?]).to eq(["project", true])
      expect([bundle.owns?("a.md"), bundle.owns?(:"a.md"), bundle.owns?("b.md")]).to eq([true, true, false])
    end

    it "reads symbol keys too (a record read with symbolize_names)" do
      bundle = described_class.parse("s", { version: "1", files: { "x.md": { checksum: "c" } }, hooks: { "k.rb": { event: "e" } } })
      expect(bundle.files).to eq("x.md" => { checksum: "c" })
      expect(bundle.hooks).to eq("k.rb" => hook.new)
    end

    it "reads a minimal record: empty mappings, nil for the rest, system scope, experimental" do
      bundle = described_class.parse("min", {})
      expect(bundle).to eq(described_class.new(name: "min"))
      expect(bundle).to have_attributes(version: nil, scope: nil, files: {}, hooks: {}, guardrails: {}, scripts: {},
                                        plugin: nil, includes: nil, mirror: {}, error: nil)
      expect([bundle.effective_scope, bundle.profile?, bundle.error?]).to eq(["system", false, false])
    end

    it "reads a legacy record: bare checksums, hooks without sha256, odd shapes as empty" do
      raw = { "version" => 3, "scope" => " ", "files" => { "old.md" => "not-a-mapping" },
              "hooks" => { "h.rb" => { "event" => "before_turn" }, "odd.rb" => "x" },
              "guardrails" => { "r.yml" => "bare" }, "plugin" => { "sha256" => "x" }, "includes" => "core",
              "needs" => "gh", "context_providers" => {} }
      bundle = described_class.parse("old", raw)
      expect(bundle).to have_attributes(version: "3", files: { "old.md" => {} }, guardrails: { "r.yml" => "" },
                                        plugin: nil, includes: nil, mirror: { "needs" => "gh", "context_providers" => {} })
      expect(bundle.hooks).to eq("h.rb" => hook.new, "odd.rb" => hook.new)
      expect(bundle.effective_scope).to eq("system")
    end

    it "reads a record that isn't an object as unreadable" do
      expect(described_class.parse("list", [])).to eq(described_class.unreadable("list", "manifest.json is not an object"))
      expect(described_class.unreadable("x", "why")).to have_attributes(error?: true, files: {}, hooks: {})
    end

    it "mirrors only the manifest keys it knows, string keys, whatever .new is given" do
      expect(described_class.parse("m", { "requires_chi" => ">= 1", "later_key" => [1], "needs" => nil }).mirror)
        .to eq("requires_chi" => ">= 1")
      expect(described_class.new(name: "m", mirror: { trust_level: "reviewed", other: 1 }).mirror).to eq("trust_level" => "reviewed")
    end
  end

  describe ".read" do
    it "reads the file, nil when there is none, raising when it doesn't parse" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "manifest.json")
        expect(described_class.read("b", path)).to be_nil
        File.write(path, JSON.generate("version" => "1.0"))
        expect(described_class.read("b", path)).to have_attributes(name: "b", version: "1.0")
        File.write(path, "{")
        expect { described_class.read("b", path) }.to raise_error(JSON::ParserError)
      end
    end
  end
end

RSpec.describe Samagotchi::MemoryBundle::PluginRef do
  it "parses the plugin mapping, nil without a file" do
    expect(described_class.parse("file" => "p.rb", "sha256" => "sha256:x")).to eq(described_class.new(file: "p.rb", sha256: "sha256:x"))
    expect(described_class.parse(file: "p.rb")).to eq(described_class.new(file: "p.rb", sha256: ""))
    expect([described_class.parse(nil), described_class.parse("p.rb"), described_class.parse("file" => "")]).to eq([nil, nil, nil])
  end
end
