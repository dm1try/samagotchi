# frozen_string_literal: true
require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "digest"
require "samagotchi/memory_bundle/provenance"

RSpec.describe Samagotchi::MemoryBundle::Provenance do
  let(:tmpdir) { Dir.mktmpdir("samagotchi-prov-") }
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

  describe "#resolve_conflicts" do
    it "rebases the resolved files on the bundle's version and drops their mark, keeping the rest" do
      prov = described_class.new(name: "test-bundle")
      src = File.join(tmpdir, "sources")
      old = make_file(src, "identity.md", "old\n")
      plugin = make_file(src, "plugin.rb", "class Plugin; end\n")
      prov.write(files: { "identity.md" => old }, scope: "system", version: "2.0.0", source_path: "/s",
                 plugin_file: plugin, conflicts: ["identity.md"])
      expect(prov.read[:files][:"identity.md"]).to include(conflict: true)

      incoming = make_file(File.join(tmpdir, "incoming"), "identity.md", "new\n")
      prov.resolve_conflicts("identity.md" => { incoming: incoming, current: "/nope" })

      data = prov.read
      expect(data[:files][:"identity.md"]).to eq(checksum: Digest::SHA256.hexdigest("new\n"))
      expect(File.read(prov.base_path("identity.md"))).to eq("new\n")
      expect(data[:version]).to eq("2.0.0")
      expect(data[:plugin][:file]).to eq("plugin.rb")
    end
  end

  describe "#write" do
    it "records a meta's includes, and none for a plain bundle" do
      meta = described_class.new(name: "core")
      meta.write(files: {}, scope: "system", version: "0.1.0", source_path: "/x/core", includes: %w[loop-guard check-in])
      expect(meta.read[:includes]).to eq(%w[loop-guard check-in])
      expect(meta.read[:files]).to eq({})

      plain = described_class.new(name: "plain")
      plain.write(files: {}, scope: "system", version: "0.1.0", source_path: "/x/plain")
      expect(plain.read).not_to have_key(:includes)
    end

    it "writes manifest.json and base snapshots" do
      prov = described_class.new(name: "test-bundle")
      base_dir = File.join(tmpdir, "sources")
      f1 = make_file(base_dir, "identity.md", "# Identity\nLine 2\n")
      f2 = make_file(base_dir, "commit_preferences.md", "# Preferences\n")
      prov.write(
        files: { "identity.md" => f1, "commit_preferences.md" => f2 },
        scope: "system",
        version: "1.0.0",
        source_path: "/some/path"
      )
      manifest = JSON.parse(File.read(prov.bundle_dir + "/manifest.json"), symbolize_names: true)
      expect(manifest[:name]).to eq("test-bundle")
      expect(manifest[:version]).to eq("1.0.0")
      expect(manifest[:scope]).to eq("system")
      expect(manifest[:source]).to eq("/some/path")
      expect(manifest[:installed_at]).not_to be_nil
      expect(manifest[:files].keys).to contain_exactly(:"identity.md", :"commit_preferences.md")
      # Check base snapshots exist and match content (no double extension).
      expect(File.read(prov.base_path("identity.md"))).to eq("# Identity\nLine 2\n")
      expect(File.exist?(File.join(prov.bundle_dir, "bases", "identity.md"))).to be true
      expect(File.read(prov.base_path("commit_preferences.md"))).to eq("# Preferences\n")
    end

    it "computes SHA256 checksums" do
      prov = described_class.new(name: "test-bundle")
      f = make_file(tmpdir, "foo.md", "hello world")
      expected_sha = Digest::SHA256.hexdigest("hello world")
      prov.write(files: { "foo.md" => f }, scope: "system", version: "1.0", source_path: "/x")
      manifest = JSON.parse(File.read(prov.bundle_dir + "/manifest.json"), symbolize_names: true)
      key = :"foo.md"
      expect(manifest[:files][key][:checksum]).to eq(expected_sha)
    end

    it "merges file entries on re-install (P2: no clobber)" do
      prov = described_class.new(name: "test-bundle")
      base_dir = File.join(tmpdir, "sources")
      f1 = make_file(base_dir, "a.md", "AAA")
      f2 = make_file(base_dir, "b.md", "BBB")

      # First install with two files.
      prov.write(files: { "a.md" => f1, "b.md" => f2 }, scope: "system", version: "1.0", source_path: "/x")
      m1 = JSON.parse(File.read(prov.bundle_dir + "/manifest.json"), symbolize_names: true)
      expect(m1[:files].keys).to contain_exactly(:"a.md", :"b.md")

      # Re-install with only one file — old file entry should be pruned.
      f3 = make_file(base_dir, "a.md", "AAA v2")
      prov.write(files: { "a.md" => f3 }, scope: "system", version: "1.1", source_path: "/x")
      m2 = JSON.parse(File.read(prov.bundle_dir + "/manifest.json"), symbolize_names: true)
      expect(m2[:files].keys).to contain_exactly(:"a.md")
      expect(File.exist?(File.join(prov.bundle_dir, "bases", "b.md"))).to be false
    end

    it "lists each file once after a re-install, with the new checksum" do
      prov = described_class.new(name: "test-bundle")
      base_dir = File.join(tmpdir, "sources")
      prov.write(files: { "a.md" => make_file(base_dir, "a.md", "AAA") }, scope: "system", version: "1.0", source_path: "/x")
      prov.write(files: { "a.md" => make_file(base_dir, "a.md", "AAA v2") }, scope: "system", version: "1.1", source_path: "/x")

      # Parsing collapses duplicate keys, so count them in the raw JSON.
      raw = File.read(prov.bundle_dir + "/manifest.json")
      expect(raw.scan('"a.md"').size).to eq(1)
      expect(prov.read[:files][:"a.md"][:checksum]).to eq(Digest::SHA256.hexdigest("AAA v2"))
    end

    it "never lets a reader in another process see a half-written manifest.json" do
      prov = described_class.new(name: "test-bundle")
      source = make_file(File.join(tmpdir, "sources"), "a.md", "AAA")
      write = -> { prov.write(files: { "a.md" => source }, scope: "system", version: "1.0", source_path: "/x") }
      write.call

      writer = fork do
        200.times { write.call }
        exit!(0)
      end
      partial = 0
      until Process.waitpid(writer, Process::WNOHANG)
        begin
          prov.read
        rescue JSON::ParserError
          partial += 1
        end
      end

      expect(partial).to eq(0)
      expect(Dir.children(prov.bundle_dir)).to contain_exactly("manifest.json", "bases")
    end

    it "preserves untouched entries on merge" do
      prov = described_class.new(name: "test-bundle")
      base_dir = File.join(tmpdir, "sources")
      f1 = make_file(base_dir, "a.md", "AAA")
      f2 = make_file(base_dir, "b.md", "BBB")
      f3 = make_file(base_dir, "c.md", "CCC")

      # First install: a, b
      prov.write(files: { "a.md" => f1, "b.md" => f2 }, scope: "system", version: "1.0", source_path: "/x")

      # Re-install: a (updated), c (new) — b should be pruned
      prov.write(files: { "a.md" => f3, "c.md" => f3 }, scope: "system", version: "1.1", source_path: "/x")
      m = JSON.parse(File.read(prov.bundle_dir + "/manifest.json"), symbolize_names: true)
      expect(m[:files].keys).to contain_exactly(:"a.md", :"c.md")
    end
  end

  describe "#read" do
    it "returns nil when not installed" do
      prov = described_class.new(name: "nonexistent")
      expect(prov.read).to be_nil
    end

    it "returns parsed manifest when installed" do
      prov = described_class.new(name: "test-bundle")
      prov.write(files: {}, scope: "project", version: "2.0", source_path: "/src")
      data = prov.read
      expect(data[:name]).to eq("test-bundle")
      expect(data[:version]).to eq("2.0")
    end
  end

  describe "#installed?" do
    it "is false when not installed" do
      expect(described_class.new(name: "missing").installed?).to be false
    end

    it "is true when installed" do
      prov = described_class.new(name: "test-bundle")
      prov.write(files: {}, scope: "system", version: "1.0", source_path: "/x")
      expect(prov.installed?).to be true
    end
  end

  describe "#base_path" do
    it "returns the correct path for a file key (no double .md)" do
      prov = described_class.new(name: "my-bundle")
      # file_key is "identity.md", base should be "bases/identity.md" NOT "bases/identity.md.md"
      expect(prov.base_path("identity.md")).to include("bases", "identity.md")
      # Verify it doesn't double up
      expect(prov.base_path("identity.md")).not_to end_with(".md.md")
    end
  end

  describe "hooks" do
    it "returns hooks_dir" do
      prov = described_class.new(name: "my-bundle")
      expect(prov.hooks_dir).to eq(File.join(bundles_dir, "my-bundle", "hooks"))
    end

    it "write/read round-trips hooks map and trust_level + source_commit (experimental must survive)" do
      prov = described_class.new(name: "hook-bundle")
      prov.write(files: {}, scope: "system", version: "1.0", source_path: "/src",
                 hooks: { "guardrails.rb" => { "sha256" => "sha256:abc", "event" => "before_tool_call", "on_error" => "fail_closed", "priority" => 10 } },
                 trust_level: "experimental", source_commit: "deadbeef")
      data = prov.read
      expect(data[:hooks]).to include(:"guardrails.rb")
      expect(data[:trust_level]).to eq("experimental")
      expect(data[:source_commit]).to eq("deadbeef")
    end

    it "records the sha256 of the installed hook file, not the declared one" do
      Dir.mktmpdir do |dir|
        hook = File.join(dir, "guard.rb").tap { |p| File.write(p, "class Guard; def call(e); end; end\n") }
        prov = described_class.new(name: "sha-bundle")
        prov.write(files: {}, scope: "system", version: "1.0", source_path: "/src",
                   hooks: { "guard.rb" => { "sha256" => "sha256:wrong", "event" => "before_tool_call" },
                            "gone.rb" => { "sha256" => "abc", "event" => "before_tool_call" } },
                   hooks_files: { "guard.rb" => hook })
        hooks = prov.read[:hooks]
        expect(hooks[:"guard.rb"][:sha256]).to eq("sha256:#{Digest::SHA256.hexdigest(File.read(hook))}")
        expect(hooks[:"gone.rb"][:sha256]).to eq("sha256:abc")
      end
    end

    it "each_installed(holding: :hooks) yields only hook-bearing bundles" do
      p1 = described_class.new(name: "with-hooks")
      p1.write(files: {}, scope: "system", version: "1.0", source_path: "/src",
               hooks: { "a.rb" => { "sha256" => "sha256:x", "event" => "e", "on_error" => "skip", "priority" => 100 } })
      p2 = described_class.new(name: "without-hooks")
      p2.write(files: {}, scope: "system", version: "1.0", source_path: "/src")
      names = []
      described_class.each_installed(holding: :hooks) { |n, _d| names << n }
      expect(names).to include("with-hooks")
      expect(names).not_to include("without-hooks")
    end

    it "each_installed(holding: :hooks) yields a corrupt manifest as {error:} and keeps going" do
      FileUtils.mkdir_p(File.join(bundles_dir, "a-broken", "hooks"))
      File.write(File.join(bundles_dir, "a-broken", "manifest.json"), '{"hooks": {"x.rb": {}}, "hooks": ')
      FileUtils.mkdir_p(File.join(bundles_dir, "a-broken-nohooks"))
      File.write(File.join(bundles_dir, "a-broken-nohooks", "manifest.json"), "{")
      FileUtils.mkdir_p(File.join(bundles_dir, "a-list"))
      File.write(File.join(bundles_dir, "a-list", "manifest.json"), "[]")
      described_class.new(name: "b-valid").write(files: {}, scope: "system", version: "1.0", source_path: "/src",
                                                 hooks: { "k.rb" => { "sha256" => "sha256:x", "event" => "e" } })
      seen = described_class.each_installed(holding: :hooks).to_a
      expect(seen.map(&:first)).to eq(%w[a-broken b-valid])
      expect(seen.first.last[:error]).to start_with("manifest.json is unreadable")
      expect(seen.last.last[:hooks]).to include(:"k.rb")
    end

    it "each_installed with holding: :plugin or :guardrails yield a corrupt manifest as {error:} only when the bundle has that dir" do
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

      plugins = described_class.each_installed(holding: :plugin).to_a
      expect(plugins.map(&:first)).to eq(%w[a-plug g-both])
      expect(plugins.first.last[:error]).to start_with("manifest.json is unreadable: ")
      expect(plugins.last.last[:plugin]).to eq(file: "p.rb")
      rules = described_class.each_installed(holding: :guardrails).to_a
      expect(rules.map(&:first)).to eq(%w[b-rules g-both])
      expect(rules.first.last.keys).to eq([:error])
    end

    it "each_installed yields every bundle by name, a manifest that doesn't parse or isn't an object as {error:}" do
      { "a" => "{}", "a-b" => JSON.generate("version" => "1"), "bad" => "{", "list" => "[]" }.each do |name, body|
        make_file(bundles_dir, "#{name}/manifest.json", body)
      end
      FileUtils.mkdir_p(File.join(bundles_dir, "no-manifest"))
      make_file(bundles_dir, ".hidden/manifest.json", "{}")
      File.write(File.join(bundles_dir, "samagotchi-system.lock"), "")
      seen = described_class.each_installed.to_a
      expect(seen.map(&:first)).to eq(%w[a a-b bad list])
      expect(seen[1].last).to eq(version: "1")
      expect(seen[2].last[:error]).to start_with("manifest.json is unreadable: ")
      expect(seen[3].last).to eq(error: "manifest.json is not an object")
    end

    it "matches a file against a recorded sha in either format" do
      path = make_file(tmpdir, "f.rb", "x\n")
      hex = Digest::SHA256.hexdigest("x\n")
      expect([described_class.sha_matches?(path, hex), described_class.sha_matches?(path, "sha256:#{hex}")]).to eq([true, true])
      expect([described_class.sha_matches?(path, "sha256:0"), described_class.sha_matches?(path, nil)]).to eq([false, false])
      expect(described_class.recorded_sha(nil)).to eq("")
    end

    it "each_installed(holding: :hooks) is no-op for empty/absent dir" do
      FileUtils.rm_rf(bundles_dir)
      expect { |b| described_class.each_installed(holding: :hooks, &b) }.not_to yield_control
      expect(described_class.each_installed(holding: :hooks).to_a).to be_empty
    end

    it "each_installed(holding: :hooks) returns enum when no block" do
      enum = described_class.each_installed(holding: :hooks)
      expect(enum).to be_a(Enumerator)
    end
  end
end
