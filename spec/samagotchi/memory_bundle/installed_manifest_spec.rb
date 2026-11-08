# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "digest"
require "samagotchi/memory_bundle/installed_bundle"
require "samagotchi/memory_bundle/installed_manifest"

RSpec.describe Samagotchi::MemoryBundle::InstalledManifest do
  let(:installed) { Samagotchi::MemoryBundle::InstalledBundle }

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
      expect(manifest).to have_attributes(requires_chi: nil, trust_level: nil, needs: [], script_names: [],
                                          context_providers: [], block_renderers: [], session_settings: [],
                                          session_setting_types: {}, settings: nil, setting_types: {},
                                          file_descriptions: {}, includes: nil, problems: {})
      expect([manifest.experimental?, manifest.needs?, manifest.context_providers?, manifest.block_renderers?])
        .to eq([true, false, false, false])
    end

    it "reads session_settings of another shape as none" do
      expect(record("session_settings" => "cap").manifest.session_settings).to eq([])
    end

    it "reads a legacy record's odd shapes as none, each with its problem" do
      manifest = record("needs" => "gh", "context_providers" => {}).manifest
      expect([manifest.needs?, manifest.context_providers?]).to eq([false, false])
      expect(manifest.problems.keys).to eq(%w[needs context_providers])
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
      expect(installed.unreadable("x", "why").manifest).to have_attributes(requires_chi: nil, problems: {})
    end
  end

  describe ".of with a kept manifest.yml" do
    let(:tmp) { Dir.mktmpdir("chi-kept-manifest-") }
    let(:kept_yml) do
      <<~YAML
        name: b
        version: 1.0.0
        description: Draws diagrams
        scripts:
          draw.js: sha256:dd
        block_renderers:
          - lang: mermaid
            load: [draw.js]
        card_layouts: [wide]
      YAML
    end
    let(:recorded) { { "version" => "1.0.0", "scripts" => { "draw.js" => { "sha256" => "sha256:dd" } } } }

    after { FileUtils.rm_rf(tmp) }

    # The record at <tmp>/b/manifest.json beside its kept manifest.yml (+yml+;
    # none when nil), read as each_installed reads it. sha: :match records the
    # kept file's sha, nil none (a chi without the kept manifest rewrote it).
    def kept_bundle(record_raw = recorded, yml = kept_yml, sha: :match)
      dir = File.join(tmp, "b")
      FileUtils.mkdir_p(dir)
      kept = File.join(dir, "manifest.yml")
      File.write(kept, yml) if yml
      raw = record_raw.dup
      raw["manifest_sha"] = sha == :match ? "sha256:#{Digest::SHA256.file(kept).hexdigest}" : sha if yml && sha
      File.write(File.join(dir, "manifest.json"), JSON.generate(raw))
      installed.read("b", File.join(dir, "manifest.json"))
    end

    it "reads a key the record lacks from the kept manifest (block_renderers: installed before chi read it)" do
      manifest = kept_bundle.manifest
      expect(manifest).to have_attributes(origin: :kept, problems: {}, description: "Draws diagrams",
                                          unknown_keys: ["card_layouts"], script_names: ["draw.js"], trust_level: "experimental")
      expect(manifest.block_renderers.map(&:to_h)).to eq([{ "lang" => "mermaid", "load" => ["draw.js"] }])
    end

    it "reads the record's mirror when no manifest.yml is kept, when its sha isn't recorded, and when it changed" do
      none = kept_bundle(recorded, nil).manifest
      expect(none).to have_attributes(origin: :record, problems: {}, block_renderers: [])

      stale = kept_bundle(recorded, kept_yml, sha: nil).manifest
      expect(stale).to have_attributes(origin: :record, block_renderers: [], unknown_keys: [])
      expect(stale.problems).to eq("manifest.yml" => :stale)
      expect(stale.standing).to eq(:stale)

      edited = kept_bundle(recorded, kept_yml, sha: "sha256:0000").manifest
      expect(edited).to have_attributes(origin: :record, block_renderers: [])
      expect(edited.problems).to eq("manifest.yml" => :edited)
      expect(edited.key_problems).to eq({})
    end

    it "says the kept file is missing when the record has its sha and no file is there (or a dir is)" do
      gone = kept_bundle(recorded.merge("manifest_sha" => "sha256:0000"), nil).manifest
      expect(gone).to have_attributes(origin: :record, standing: :missing, key_problems: {})

      FileUtils.mkdir_p(File.join(tmp, "b", "manifest.yml"))
      expect(installed.read("b", File.join(tmp, "b", "manifest.json")).manifest.standing).to eq(:missing)
    end

    it "hands out a frozen value, all the way down (callers share the cached one)" do
      manifest = kept_bundle(recorded.merge("needs" => ["jq"]), kept_yml + "needs: [gh]\n").manifest
      expect([manifest.needs, manifest.needs.first, manifest.needs.first[:command], manifest.script_names,
              manifest.unknown_keys, manifest.problems, manifest.file_descriptions, manifest.description]).to all(be_frozen)
    end

    it "takes a profile's includes from the record, never the kept manifest" do
      yml = "name: b\nversion: 1.0.0\nincludes: [x, y, z]\n"
      expect(kept_bundle({ "version" => "1.0.0", "includes" => %w[x y] }, yml).manifest.includes).to eq(%w[x y])
      expect(kept_bundle({ "version" => "1.0.0" }, yml).manifest.includes).to be_nil
    end

    it "takes a kept file that isn't YAML, or isn't a mapping, as edited" do
      expect(kept_bundle(recorded, "name: [b\n").manifest).to have_attributes(origin: :record, problems: { "manifest.yml" => :edited })
      expect(kept_bundle(recorded, "- a\n").manifest).to have_attributes(origin: :record, problems: { "manifest.yml" => :edited })
    end

    it "never checks a dev install's link, and reads its source's manifest live" do
      source = File.join(tmp, "src").tap { |dir| FileUtils.mkdir_p(dir) }
      File.write(File.join(source, "manifest.yml"), kept_yml)
      bundle = kept_bundle(recorded.merge("dev" => true, "manifest_sha" => "sha256:dev"), nil)
      File.symlink(File.join(source, "manifest.yml"), bundle.kept_manifest_path)
      expect(bundle.manifest.block_renderers.map(&:lang)).to eq(["mermaid"])

      File.write(File.join(source, "manifest.yml"), kept_yml.sub("lang: mermaid", "lang: mmd"))
      expect(bundle.manifest.block_renderers.map(&:lang)).to eq(["mmd"])
    end

    it "reads a kept key that doesn't parse as the mirror's value, with its problem, and keeps the other keys" do
      yml = kept_yml + "needs: gh\ncontext_providers: {}\nrequires_chi: \">= 0.2\"\n"
      manifest = kept_bundle(recorded.merge("needs" => ["jq"], "requires_chi" => ">= 0.1"), yml).manifest
      expect(manifest).to have_attributes(origin: :kept, needs: [{ command: "jq", why: nil, hint: nil }],
                                          context_providers: [], requires_chi: ">= 0.2")
      expect(manifest.problems.keys).to eq(%w[needs context_providers])
      expect(manifest.problems["needs"]).to eq("needs: must be a list of commands")
      expect(manifest.block_renderers.map(&:lang)).to eq(["mermaid"])
    end

    it "checks block_renderers against the record's scripts when the kept scripts: doesn't parse" do
      yml = kept_yml.sub("scripts:\n  draw.js: sha256:dd\n", "scripts: [draw.js]\n")
      manifest = kept_bundle(recorded, yml).manifest
      expect(manifest.problems.keys).to eq(["scripts"])
      expect(manifest).to have_attributes(script_names: ["draw.js"])
      expect(manifest.block_renderers.map(&:lang)).to eq(["mermaid"])

      without = kept_bundle(recorded.merge("scripts" => {}), yml).manifest
      expect(without.problems.keys).to eq(%w[scripts block_renderers])
      expect(without.block_renderers).to eq([])
    end

    it "finds no problem in an older install's kept hooks:, however it is written (class-file hooks are retired)" do
      yml = kept_yml + "hooks:\n  g.rb:\n    events: [after_turn]\n  h.rb:\n    event: x\n    events: [y]\n"
      manifest = kept_bundle(recorded.merge("hooks" => { "g.rb" => { "sha256" => "sha256:hh", "event" => "after_turn" } }), yml).manifest
      expect(manifest.problems).to eq({})
      expect(manifest.origin).to eq(:kept)
    end

    it "reads session_settings and settings with their types from the kept manifest, each falling back alone" do
      yml = kept_yml + "session_settings: {cap: number}\nsettings: {limit: nope}\n"
      manifest = kept_bundle(recorded.merge("settings" => ["old"]), yml).manifest
      expect(manifest).to have_attributes(session_settings: ["cap"], session_setting_types: { "cap" => "number" },
                                          settings: ["old"], setting_types: {})
      expect(manifest.problems.keys).to eq(["settings"])
    end

    it "reads the new manifest once the kept file is rewritten" do
      bundle = kept_bundle
      expect(bundle.manifest.block_renderers.map(&:lang)).to eq(["mermaid"])
      expect(bundle.manifest).to equal(bundle.manifest)

      rewritten = kept_bundle(recorded, kept_yml.sub("lang: mermaid", "lang: mmd"))
      expect(rewritten.manifest.block_renderers.map(&:lang)).to eq(["mmd"])
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

  # Ties the two classes together: a key Manifest reads has an answer
  # here, and the record can't hand it out past the seam.
  describe "tripwire" do
    # Identity and state stay on the record; the rest is manifest data.
    let(:identity_and_state) { %i[name version scope files plugin] }
    let(:renamed) { { scripts: :script_names } }
    # Derived values a later phase adds to Manifest, each with why it has no counterpart here.
    let(:excluded) { {} }

    # A reader counts once a minimal manifest has its ivar, so Manifest#initialize
    # must set each one unconditionally (as it does: `@x = parse_x(raw["x"])`);
    # one set only when its key is present would slip past this.
    def manifest_readers
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "manifest.yml"), "name: t\nversion: 1.0.0\n")
        manifest = Samagotchi::MemoryBundle::Manifest.read(dir: dir)
        Samagotchi::MemoryBundle::Manifest.public_instance_methods(false).select do |name|
          Samagotchi::MemoryBundle::Manifest.instance_method(name).arity.zero? && manifest.instance_variables.include?(:"@#{name}")
        end
      end
    end

    it "gives every attr_reader of Manifest, but identity and state, a counterpart" do
      readers = manifest_readers
      expect(readers).to include(:requires_chi, :block_renderers, :scripts)
      wanted = (readers - identity_and_state - excluded.keys).map { |name| renamed.fetch(name, name) }
      expect(wanted - described_class.members).to eq([])
    end

    it "keeps the mirrored keys off InstalledBundle's members" do
      expect(installed.members & installed::MIRROR_KEYS.map(&:to_sym)).to eq([])
    end
  end
end
