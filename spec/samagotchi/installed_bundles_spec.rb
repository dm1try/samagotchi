# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "json"
require "digest"
require "samagotchi/installed_bundles"
require "samagotchi/memory_bundle/provenance"
require "support/legacy_hooks_record"

RSpec.describe Samagotchi::InstalledBundles do
  let(:tmpdir) { Dir.mktmpdir("samagotchi-installed-") }
  let(:bundles_dir) { Samagotchi::MemoryPaths.bundles_dir }

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

  after do
    FileUtils.rm_rf(tmpdir)
  end

  def make_file(base_dir, name, content)
    path = File.join(base_dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  describe "the walk and the shas" do
    it ".each(holding: :hooks) yields only hook-bearing bundles" do
      LegacyHooksRecord.legacy_hooks_record("with-hooks", hooks: { "a.rb" => "# a\n" })
      p2 = Samagotchi::MemoryBundle::Provenance.new(name: "without-hooks")
      p2.write(files: {}, scope: "system", version: "1.0", source_path: "/src")
      names = []
      described_class.each(holding: :hooks) { |n, _d| names << n }
      expect(names).to include("with-hooks")
      expect(names).not_to include("without-hooks")
    end

    it ".each(holding: :hooks) yields a corrupt manifest as one with error set and keeps going" do
      FileUtils.mkdir_p(File.join(bundles_dir, "a-broken", "hooks"))
      File.write(File.join(bundles_dir, "a-broken", "manifest.json"), '{"hooks": {"x.rb": {}}, "hooks": ')
      FileUtils.mkdir_p(File.join(bundles_dir, "a-broken-nohooks"))
      File.write(File.join(bundles_dir, "a-broken-nohooks", "manifest.json"), "{")
      FileUtils.mkdir_p(File.join(bundles_dir, "a-list"))
      File.write(File.join(bundles_dir, "a-list", "manifest.json"), "[]")
      LegacyHooksRecord.legacy_hooks_record("b-valid", hooks: { "k.rb" => "# k\n" })
      seen = described_class.each(holding: :hooks).to_a
      expect(seen.map(&:first)).to eq(%w[a-broken b-valid])
      expect(seen.first.last.error).to start_with("manifest.json is unreadable")
      expect(seen.last.last.hooks).to include("k.rb")
    end

    it ".each with holding: :plugin or :guardrails yield a corrupt manifest (error set) only when the bundle has that dir" do
      { "a-plug" => "plugin", "b-rules" => "guardrails", "c-plain" => nil }.each do |name, sub|
        FileUtils.mkdir_p(File.join(bundles_dir, name, *sub))
        File.write(File.join(bundles_dir, name, "manifest.json"), "{")
      end
      FileUtils.mkdir_p(File.join(bundles_dir, "d-list", "plugin"))
      FileUtils.mkdir_p(File.join(bundles_dir, "d-list", "guardrails"))
      File.write(File.join(bundles_dir, "d-list", "manifest.json"), "[]")
      FileUtils.mkdir_p(File.join(bundles_dir, "e-none"))
      File.write(File.join(bundles_dir, "e-none", "manifest.json"), JSON.generate("plugin" => "x", "guardrails" => {}))
      FileUtils.mkdir_p(File.join(bundles_dir, "f-nomanifest", "plugin"))
      File.write(File.join(bundles_dir, "g-both", "manifest.json").tap { |f| FileUtils.mkdir_p(File.dirname(f)) },
                 JSON.generate("plugin" => { "file" => "p.rb" }, "guardrails" => { "r.yml" => { "sha256" => "sha256:x" } }))

      plugins = described_class.each(holding: :plugin).to_a
      expect(plugins.map(&:first)).to eq(%w[a-plug g-both])
      expect(plugins.first.last.error).to start_with("manifest.json is unreadable: ")
      expect(plugins.last.last.plugin).to eq(Samagotchi::InstalledBundles::PluginRef.new(file: "p.rb"))
      rules = described_class.each(holding: :guardrails).to_a
      expect(rules.map(&:first)).to eq(%w[b-rules g-both])
      expect(rules.first.last).to have_attributes(error: start_with("manifest.json is unreadable: "), version: nil, files: {})
    end

    it ".each yields every bundle by name, a manifest that doesn't parse or isn't an object with error set" do
      { "a" => "{}", "a-b" => JSON.generate("version" => "1"), "bad" => "{", "list" => "[]" }.each do |name, body|
        make_file(bundles_dir, "#{name}/manifest.json", body)
      end
      FileUtils.mkdir_p(File.join(bundles_dir, "no-manifest"))
      make_file(bundles_dir, ".hidden/manifest.json", "{}")
      File.write(File.join(bundles_dir, "samagotchi-system.lock"), "")
      seen = described_class.each.to_a
      expect(seen.map(&:first)).to eq(%w[a a-b bad list])
      expect(seen[1].last).to eq(Samagotchi::InstalledBundles::Record.new(name: "a-b", version: "1", dir: File.join(bundles_dir, "a-b")))
      expect(seen[2].last.error).to start_with("manifest.json is unreadable: ")
      expect(seen[3].last).to eq(Samagotchi::InstalledBundles::Record.unreadable("list", "manifest.json is not an object"))
    end

    it "matches a file against a recorded sha in either format" do
      path = make_file(tmpdir, "f.rb", "x\n")
      hex = Digest::SHA256.hexdigest("x\n")
      expect([Samagotchi::InstalledBundles::Sha.matches?(path, hex), Samagotchi::InstalledBundles::Sha.matches?(path, "sha256:#{hex}")]).to eq([true, true])
      expect([Samagotchi::InstalledBundles::Sha.matches?(path, "sha256:0"), Samagotchi::InstalledBundles::Sha.matches?(path, nil)]).to eq([false, false])
      expect(Samagotchi::InstalledBundles::Sha.recorded(nil)).to eq("")
    end

    it ".each(holding: :hooks) is no-op for empty/absent dir" do
      FileUtils.rm_rf(bundles_dir)
      expect { |b| described_class.each(holding: :hooks, &b) }.not_to yield_control
      expect(described_class.each(holding: :hooks).to_a).to be_empty
    end

    it ".each(holding: :hooks) returns enum when no block" do
      enum = described_class.each(holding: :hooks)
      expect(enum).to be_a(Enumerator)
    end
  end

  # The read side loads none of the install machinery: the runtime readers
  # (the plugin loader, guardrails, context providers, renderers…) reach the
  # installed bundles through this, never through MemoryBundle.
  it "loads no file under memory_bundle/, a record's manifest read included" do
    lib = File.expand_path("../../lib", __dir__)
    script = <<~RUBY
      require "tmpdir"
      require "json"
      require "samagotchi/installed_bundles"
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "demo"))
        File.write(File.join(dir, "demo", "manifest.json"), JSON.generate(
          "name" => "demo", "version" => "1.0.0", "scope" => "system", "source" => "/s", "installed_at" => "now",
          "files" => { "a.md" => { "checksum" => "0" * 64, "conflict" => true } }, "hooks" => {},
          "plugin" => { "file" => "plugin.rb", "sha256" => "sha256:dev" },
          "context_providers" => [{ "match" => "\\Ahttps://x/", "name" => "x", "cmd" => "true" }],
          "block_renderers" => [{ "language" => "demo", "load" => ["draw.js"] }]
        ))
        Samagotchi::InstalledBundles.each(dir: dir) do |name, bundle|
          bundle.manifest.context_providers
          bundle.behind_files(dir)
          Samagotchi::InstalledBundles::Dir.new(name: name, dir: dir).plugin_path(bundle)
        end
        Samagotchi::InstalledBundles.claimants("a.md", scope: "system", dir: dir)
      end
      loaded = $LOADED_FEATURES.grep(%r{/samagotchi/memory_bundle(/|.rb)})
      abort loaded.inspect unless loaded.empty?
    RUBY
    _out, err, status = Open3.capture3(RbConfig.ruby, "-w", "-I", lib, "-r", "fileutils", "-e", script)

    expect(status).to be_success, err
    expect(err).not_to include("circular require")
  end
end
