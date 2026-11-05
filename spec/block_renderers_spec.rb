# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "digest"
require "yaml"
require "samagotchi/block_renderers"
require "samagotchi/memory_bundle/installer"
require "samagotchi/memory_bundle/builder"
require "samagotchi/memory_bundle/installed_copy"
require "samagotchi/version"

# A bundle's manifest maps a fence's language to the scripts/ files the page
# loads to draw it. Nothing runs them here: Ruby routes and serves.
RSpec.describe Samagotchi::BlockRenderers do
  let(:tmpdir) { Dir.mktmpdir("block-renderers") }
  let(:bundles_dir) { File.join(Samagotchi::MemoryPaths.system_dir, ".bundles") }
  let(:js) { "chi.defineRenderer({});\n" }
  let(:entry) { { "lang" => "mermaid", "load" => %w[lib.js draw.js] } }

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }
  after { FileUtils.rm_rf(tmpdir) }

  def source(name: "drawer", renderers: [entry], scripts: %w[lib.js draw.js], requires_chi: nil)
    dir = File.join(tmpdir, "src-#{rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(dir, "scripts"))
    scripts.each { |file| File.write(File.join(dir, "scripts", file), js) }
    manifest = { "name" => name, "version" => "1.0.0", "files" => {},
                 "scripts" => scripts.to_h { |file| [file, "sha256:#{Digest::SHA256.hexdigest(js)}"] } }
    manifest["block_renderers"] = renderers if renderers
    manifest["requires_chi"] = requires_chi if requires_chi
    File.write(File.join(dir, "manifest.yml"), YAML.dump(manifest))
    dir
  end

  def install(src, name: "drawer", **opts)
    installer = Samagotchi::MemoryBundle::Installer.new(source: src, name: name, scope: "system", strict: true, **opts)
    installer.run
    installer
  end

  describe ".parse_list" do
    it "reads the list, [] when absent" do
      expect(described_class.parse_list(nil)).to eq([])
      expect(described_class.parse_list([entry]).map(&:to_h)).to eq([entry])
    end

    it "refuses what isn't a list of mappings" do
      expect { described_class.parse_list("x") }.to raise_error(described_class::Invalid, /must be a list/)
      expect { described_class.parse_list(["x"]) }.to raise_error(described_class::Invalid, /must be a mapping/)
    end

    it "refuses a language listed twice" do
      twice = [entry, { "lang" => "mermaid", "load" => ["other.js"] }]
      expect { described_class.parse_list(twice) }.to raise_error(described_class::Invalid, /mermaid listed more than once/)
    end

    it "refuses a language the page could never route to" do
      ["", "Mermaid", "a b", "x" * 33, nil].each do |lang|
        expect { described_class.parse("lang" => lang, "load" => ["a.js"]) }.to raise_error(described_class::Invalid, /lang/), lang.inspect
      end
    end

    it "refuses an empty load, or one that isn't plain file names" do
      [nil, [], "a.js", ["../a.js"], ["a/b.js"], [""], [1]].each do |load|
        expect { described_class.parse("lang" => "x", "load" => load) }.to raise_error(described_class::Invalid, /load/), load.inspect
      end
    end
  end

  describe "the manifest" do
    it "reads block_renderers:" do
      manifest = Samagotchi::MemoryBundle::Manifest.read(dir: source)

      expect(manifest.block_renderers).to eq([described_class::Renderer.new(lang: "mermaid", load: %w[lib.js draw.js])])
    end

    it "refuses a load that isn't a scripts: key" do
      expect { Samagotchi::MemoryBundle::Manifest.read(dir: source(scripts: %w[lib.js])) }
        .to raise_error(Samagotchi::MemoryBundle::Manifest::ValidationError, /block_renderers: .*draw\.js.*scripts:/)
    end

    it "takes an unparseable list as a validation error" do
      expect { Samagotchi::MemoryBundle::Manifest.read(dir: source(renderers: "x")) }
        .to raise_error(Samagotchi::MemoryBundle::Manifest::ValidationError, /block_renderers:/)
    end

    it "writes them back" do
      dir = File.join(tmpdir, "written")
      Samagotchi::MemoryBundle::Manifest.write(dir: dir, name: "x", version: "1", files: {},
                                               block_renderers: [described_class::Renderer.new(lang: "a", load: ["b.js"])])

      expect(YAML.load_file(File.join(dir, "manifest.yml"))["block_renderers"]).to eq([{ "lang" => "a", "load" => ["b.js"] }])
    end
  end

  describe "install" do
    it "records them, and an upgrade that drops them forgets them" do
      install(source)
      record = Samagotchi::MemoryBundle::Provenance.new(name: "drawer").record
      expect(record.block_renderers?).to be(true)
      expect(described_class.parse_list(record.block_renderers).map(&:to_h)).to eq([entry])

      install(source(renderers: nil), upgrade: true)
      expect(Samagotchi::MemoryBundle::Provenance.new(name: "drawer").record.block_renderers?).to be(false)
    end

    it "doesn't warn that a --dev script a page loads isn't executable (it isn't run)" do
      src = source
      Dir[File.join(src, "scripts", "*")].each { |file| FileUtils.chmod(0o644, file) }

      expect(install(src, dev: true).warnings.grep(/not executable/)).to be_empty
    end

    it "still warns of a --dev script a provider's command runs, even when a page loads it too" do
      src = source
      manifest = YAML.load_file(File.join(src, "manifest.yml"))
      manifest["context_providers"] = [{ "match" => "x", "name" => "y", "cmd" => "{bundle_dir}/scripts/draw.js" }]
      File.write(File.join(src, "manifest.yml"), YAML.dump(manifest))
      Dir[File.join(src, "scripts", "*")].each { |file| FileUtils.chmod(0o644, file) }

      warnings = install(src, dev: true).warnings.grep(/not executable/)
      expect(warnings.size).to eq(1)
      expect(warnings.first).to include("draw.js")
    end

    it "survives a bundle build and the installed copy" do
      src = source
      File.write(File.join(src, "identity.md"), "# Id\n")
      manifest = YAML.load_file(File.join(src, "manifest.yml"))
      manifest["files"] = { "identity.md" => "sha256:#{Digest::SHA256.hexdigest("# Id\n")}" }
      File.write(File.join(src, "manifest.yml"), YAML.dump(manifest))
      install(src)
      out = File.join(tmpdir, "out")
      Samagotchi::MemoryBundle::Builder.new(scope: "system", name: "drawer", out: out).run
      expect(Samagotchi::MemoryBundle::Manifest.read(dir: out).block_renderers.map(&:to_h)).to eq([entry])

      record = Samagotchi::MemoryBundle::Provenance.new(name: "drawer").record
      Samagotchi::MemoryBundle::InstalledCopy.with(record) do |dir|
        expect(Samagotchi::MemoryBundle::Manifest.read(dir: dir).block_renderers.map(&:to_h)).to eq([entry])
      end
    end
  end

  describe ".for_installed" do
    it "lists what the installed bundles draw" do
      install(source)

      expect(described_class.for_installed.map(&:to_h)).to eq([{ lang: "mermaid", bundle: "drawer", files: %w[lib.js draw.js] }])
    end

    it "is empty with nothing installed" do
      expect(described_class.for_installed).to eq([])
    end

    it "gives a language to the first bundle by name" do
      install(source(name: "zz"), name: "zz")
      install(source(name: "aa"), name: "aa")

      expect(described_class.for_installed.map(&:bundle)).to eq(["aa"])
    end

    it "skips a bundle whose requires_chi this chi doesn't meet" do
      install(source(requires_chi: ">= 999.0"))

      expect(described_class.for_installed).to eq([])
    end

    it "skips a record that doesn't read" do
      install(source)
      File.write(File.join(bundles_dir, "drawer", "manifest.json"), "{nope")

      expect(described_class.for_installed).to eq([])
    end

    it "skips and logs a record whose list doesn't parse" do
      install(source)
      path = File.join(bundles_dir, "drawer", "manifest.json")
      File.write(path, JSON.generate(JSON.parse(File.read(path)).merge("block_renderers" => [{ "lang" => "BAD" }])))
      expect(Samagotchi::Log).to receive(:warn).with(:web, "block_renderers_unreadable", hash_including(bundle: "drawer"))
      expect(described_class.for_installed).to eq([])
    end
  end

  describe "a record with bytes that aren't UTF-8" do
    def corrupt(field, bytes)
      path = File.join(bundles_dir, "drawer", "manifest.json")
      File.binwrite(path, File.binread(path).gsub(field, bytes))
    end

    it "is skipped, in a renderer's lang, and the other bundles still list" do
      install(source)
      install(source(name: "other", renderers: [entry.merge("lang" => "dot")]), name: "other")
      corrupt('"mermaid"'.b, "\"mer\xFFmaid\"".b)

      expect(described_class.for_installed.map(&:lang)).to eq(["dot"])
    end

    it "is skipped, in a load" do
      install(source)
      corrupt('"draw.js"'.b, "\"dr\xFFaw.js\"".b)

      expect(described_class.for_installed).to eq([])
    end
  end

  describe ".script_path" do
    before { install(source) }

    it "is the installed file, for a file its renderer loads" do
      expect(described_class.script_path("drawer", "draw.js")).to eq(File.join(bundles_dir, "drawer", "scripts", "draw.js"))
    end

    it "is nil for a bundle or a file that isn't a renderer's" do
      expect(described_class.script_path("nope", "draw.js")).to be_nil
      expect(described_class.script_path("drawer", "other.js")).to be_nil
      expect(described_class.script_path("..", "draw.js")).to be_nil
      expect(described_class.script_path("drawer", "../manifest.json")).to be_nil
    end

    it "is nil for a file on disk the bundle's load doesn't name, though it is a script" do
      install(source(renderers: [{ "lang" => "mermaid", "load" => ["draw.js"] }]), upgrade: true)

      expect(described_class.script_path("drawer", "lib.js")).to be_nil
    end

    it "refuses a file that changed since the install" do
      File.write(File.join(bundles_dir, "drawer", "scripts", "draw.js"), "evil()")

      expect { described_class.script_path("drawer", "draw.js") }.to raise_error(described_class::Invalid, /draw\.js.*reinstall/)
    end

    it "refuses a file the record has no sha for" do
      path = File.join(bundles_dir, "drawer", "manifest.json")
      File.write(path, JSON.generate(JSON.parse(File.read(path)).merge("scripts" => {})))

      expect { described_class.script_path("drawer", "draw.js") }.to raise_error(described_class::Invalid)
    end

    it "refuses a file that is gone" do
      FileUtils.rm_f(File.join(bundles_dir, "drawer", "scripts", "draw.js"))
      expect { described_class.script_path("drawer", "draw.js") }.to raise_error(described_class::Invalid)
    end

    it "doesn't check a --dev install's links" do
      src = source(name: "linked", renderers: [entry.merge("lang" => "dot")])
      install(src, name: "linked", dev: true)
      File.write(File.join(src, "scripts", "draw.js"), "edited()")

      expect(described_class.script_path("linked", "draw.js")).to eq(File.join(bundles_dir, "linked", "scripts", "draw.js"))
    end
  end
end
