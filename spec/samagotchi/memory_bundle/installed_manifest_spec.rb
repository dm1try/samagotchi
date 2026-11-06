# frozen_string_literal: true

require "spec_helper"
require "json"
require "samagotchi/memory_bundle/installed_bundle"
require "samagotchi/memory_bundle/installed_manifest"

RSpec.describe Samagotchi::MemoryBundle::InstalledManifest do
  let(:installed) { Samagotchi::MemoryBundle::InstalledBundle }
  let(:hook) { Samagotchi::MemoryBundle::BundleHook }

  def record(raw) = installed.parse("b", JSON.parse(JSON.generate(raw)))

  describe ".of" do
    it "reads each manifest key from the record" do
      manifest = record(
        "version" => "1.2.0", "trust_level" => "reviewed", "requires_chi" => ">= 0.50",
        "files" => { "a.md" => { "checksum" => "aa", "description" => "A" }, "b.md" => { "checksum" => "bb" } },
        "hooks" => { "g.rb" => { "sha256" => "sha256:hh", "event" => "before_tool_call" } },
        "scripts" => { "s.rb" => { "sha256" => "sha256:ss" }, "draw.js" => { "sha256" => "sha256:dd" } },
        "needs" => [{ "command" => "gh", "why" => "reads PRs" }, "jq"],
        "context_providers" => [{ "match" => "\\Ahttps://x/(\\d+)", "name" => "x-\\1", "cmd" => "{ruby} s.rb {url}" }],
        "block_renderers" => [{ "lang" => "mermaid", "load" => ["draw.js"] }],
        "session_settings" => ["cap"], "session_setting_types" => { "cap" => "number" },
        "settings" => %w[limit], "setting_types" => { "limit" => "number" }, "includes" => %w[x y]
      ).manifest
      expect(manifest).to have_attributes(
        name: "b", version: "1.2.0", requires_chi: ">= 0.50", trust_level: "reviewed", description: nil,
        hooks: { "g.rb" => hook.new(sha256: "sha256:hh", event: "before_tool_call") },
        needs: [{ command: "gh", why: "reads PRs", hint: nil }, { command: "jq", why: nil, hint: nil }],
        script_names: %w[s.rb draw.js], session_settings: ["cap"], session_setting_types: { "cap" => "number" },
        settings: %w[limit], setting_types: { "limit" => "number" }, file_descriptions: { "a.md" => "A" },
        includes: %w[x y], unknown_keys: [], problems: {}, origin: :record
      )
      expect(manifest.context_providers.map(&:name)).to eq(["x-\\1"])
      expect(manifest.block_renderers.map(&:to_h)).to eq([{ "lang" => "mermaid", "load" => ["draw.js"] }])
      expect([manifest.experimental?, manifest.needs?, manifest.context_providers?, manifest.block_renderers?])
        .to eq([false, true, true, true])
    end

    it "reads a minimal record as empty: experimental, no settings, nothing declared" do
      manifest = record({}).manifest
      expect(manifest).to have_attributes(requires_chi: nil, trust_level: nil, hooks: {}, needs: [], script_names: [],
                                          context_providers: [], block_renderers: [], session_settings: [],
                                          session_setting_types: {}, settings: nil, setting_types: {},
                                          file_descriptions: {}, includes: nil, problems: {})
      expect([manifest.experimental?, manifest.needs?, manifest.context_providers?, manifest.block_renderers?])
        .to eq([true, false, false, false])
    end

    it "keeps a trust_level that is set, even an empty one, as not experimental" do
      expect(record("trust_level" => "").manifest.experimental?).to be(false)
      expect(record("trust_level" => "experimental").manifest.experimental?).to be(true)
    end

    it "reads a key that doesn't parse as empty, with its problem, and keeps the rest" do
      manifest = record("needs" => "gh", "context_providers" => [{ "match" => "x" }],
                        "block_renderers" => [{ "lang" => "Mermaid", "load" => ["a.js"] }], "requires_chi" => ">= 0.1").manifest
      expect(manifest).to have_attributes(needs: [], context_providers: [], block_renderers: [], requires_chi: ">= 0.1")
      expect(manifest.problems.keys).to eq(%w[needs context_providers block_renderers])
      expect(manifest.problems["needs"]).to eq("needs: must be a list of commands")
      expect(manifest.problems["context_providers"]).to eq("context_providers: an item has no name:")
      expect(manifest.problems["block_renderers"]).to start_with("block_renderers: lang \"Mermaid\" isn't a fence's language")
      expect([manifest.needs?, manifest.context_providers?, manifest.block_renderers?]).to eq([false, false, false])
    end

    it "reads a needs or a provider whose bytes aren't UTF-8 (JSON keeps them) as a problem, and keeps the rest" do
      raw = "{\"requires_chi\":\">= 0.1\",\"session_settings\":[\"cap\"],\"needs\":[{\"command\":\"gh\",\"why\":\"r\xff\"}]," \
            "\"context_providers\":[{\"match\":\"x\xff\",\"name\":\"n\",\"cmd\":\"c\"}]}"
      manifest = installed.parse("b", JSON.parse(raw.b)).manifest
      expect(manifest).to have_attributes(needs: [], context_providers: [], requires_chi: ">= 0.1", session_settings: ["cap"])
      expect(manifest.problems.keys).to eq(%w[needs context_providers])
      expect(manifest.requires_chi_failure).to be_nil
    end

    it "reads a record with no dir (one parsed alone) and an unreadable one from what they hold" do
      expect(record("requires_chi" => ">= 9").dir).to be_nil
      expect(record("requires_chi" => ">= 9").manifest.requires_chi).to eq(">= 9")
      expect(installed.unreadable("x", "why").manifest).to have_attributes(requires_chi: nil, hooks: {}, problems: {})
    end
  end

  describe "#requires_chi_failure" do
    it "says why this chi (or a given one) doesn't meet it, nil when it does or none is named" do
      manifest = record("requires_chi" => ">= 1.0").manifest
      expect(manifest.requires_chi_failure("0.9.0")).to eq("it requires chi >= 1.0 (this is chi 0.9.0)")
      expect(manifest.requires_chi_failure("1.0.0")).to be_nil
      expect(record({}).manifest.requires_chi_failure).to be_nil
      expect(record("requires_chi" => ">= 99999").manifest.requires_chi_failure).to include("this is chi #{Samagotchi::VERSION}")
    end
  end
end
