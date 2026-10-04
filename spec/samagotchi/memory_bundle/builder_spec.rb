# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "json"
require "digest"
require "samagotchi/memory_bundle/installer"
require "samagotchi/memory_bundle/provenance"
require "samagotchi/memory_bundle/builder"

RSpec.describe Samagotchi::MemoryBundle::Builder do
  let(:tmpdir) { Dir.mktmpdir("builder-") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
  let(:bundles_dir) { File.join(system_dir, ".bundles") }

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

  before do
    FileUtils.mkdir_p(system_dir)
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  def write_bundle_with_hooks(files = {}, hooks = {}, name: "test-bundle", version: "1.0.0", trust_level: "reviewed")
    src = File.join(tmpdir, "src_#{name}_#{rand(1000)}")
    FileUtils.mkdir_p(src)
    FileUtils.mkdir_p(File.join(src, "hooks"))
    files.each { |k, v| File.write(File.join(src, k), v) }
    hooks.each { |k, v| File.write(File.join(src, "hooks", k), v) }
    manifest = { "name" => name, "version" => version, "files" => {}, "hooks" => {} }
    files.each { |k, v| manifest["files"][k] = "sha256:#{Digest::SHA256.hexdigest(v)}" }
    hooks.each { |k, v| manifest["hooks"][k] = { "sha256" => "sha256:#{Digest::SHA256.hexdigest(v)}", "event" => "before_tool_call", "on_error" => "fail_closed", "priority" => 10 } }
    manifest["trust_level"] = trust_level if trust_level
    File.write(File.join(src, "manifest.yml"), YAML.dump(manifest))
    src
  end

  describe "memories other installed bundles own" do
    before do
      src = write_bundle_with_hooks({ "identity.md" => "# Id\n", "guide.md" => "# Guide\n" }, {}, name: "system-ish")
      Samagotchi::MemoryBundle::Installer.new(source: src, name: "system-ish", scope: "system", strict: true).run
      File.write(File.join(system_dir, "work.md"), "# work\n")
    end

    it "are left out, each with a line saying which bundle has it" do
      out = File.join(tmpdir, "out")
      builder = described_class.new(scope: "system", out: out)
      result = builder.run

      expect(result[:files]).to eq(["work.md"])
      expect(Dir.children(out).sort).to eq(%w[manifest.yml work.md])
      expect(builder.warnings).to eq([
        "Left out guide.md: installed by bundle system-ish (name it to include it)",
        "Left out identity.md: installed by bundle system-ish (name it to include it)"
      ])
    end

    it "are included when named" do
      builder = described_class.new(scope: "system", out: File.join(tmpdir, "out"), files: %w[identity work])
      expect(builder.run[:files]).to eq(%w[identity.md work.md])
      expect(builder.warnings).to eq([])
    end

    it "are the bundle's own when it rebuilds itself" do
      builder = described_class.new(scope: "system", name: "system-ish", out: File.join(tmpdir, "out"))
      expect(builder.run[:files]).to eq(%w[guide.md identity.md work.md])
    end

    it "fail the build when nothing else is left" do
      File.delete(File.join(system_dir, "work.md"))
      builder = described_class.new(scope: "system", out: File.join(tmpdir, "out"))
      expect { builder.run }.to raise_error(described_class::BuildError,
                                            "No memories to build in system scope: every one belongs to an installed bundle " \
                                            "(guide.md, identity.md); name the ones to include")
    end
  end

  it "builds hooks/*.rb and hooks: manifest round-trip" do
    src = write_bundle_with_hooks({ "identity.md" => "# Id\n" }, { "guardrails.rb" => "class Guardrails; def call(e); end; end" }, name: "build-hook", trust_level: "reviewed")
    inst = Samagotchi::MemoryBundle::Installer.new(source: src, name: "build-hook", scope: "system", force: false, strict: true)
    inst.run
    out = File.join(tmpdir, "out")
    builder = described_class.new(scope: "system", name: "build-hook", version: "1.0.0", out: out)
    result = builder.run
    expect(File.exist?(File.join(out, "hooks", "guardrails.rb"))).to be true
    manifest = YAML.load_file(File.join(out, "manifest.yml"))
    expect(manifest["hooks"]).to include("guardrails.rb")
    expect(manifest["trust_level"]).to eq("reviewed")
    expect(result[:files]).to include("identity.md")
  end

  it "build without hooks still succeeds" do
    src = write_bundle_with_hooks({ "identity.md" => "# Id\n" }, {}, name: "no-hook-build")
    inst = Samagotchi::MemoryBundle::Installer.new(source: src, name: "no-hook-build", scope: "system", force: false, strict: true)
    inst.run
    out = File.join(tmpdir, "out2")
    builder = described_class.new(scope: "system", name: "no-hook-build", version: "1.0.0", out: out)
    expect { builder.run }.not_to raise_error
    manifest = YAML.load_file(File.join(out, "manifest.yml"))
    expect(manifest["hooks"]).to be_nil
  end

  it "keeps the installed bundle's needs (symbol-keyed provenance) in the built manifest" do
    fixture = File.expand_path("../../fixtures/sample_needs_bundle", __dir__)
    Samagotchi::MemoryBundle::Installer.new(source: fixture, name: "sample-needs", scope: "system", strict: true).run
    out = File.join(tmpdir, "out-needs")
    described_class.new(scope: "system", name: "sample-needs", version: "1.0.0", out: out).run
    expect(YAML.load_file(File.join(out, "manifest.yml"))["needs"]).to eq([
      { "command" => "chi-surely-missing-cmd", "why" => "stands in for gh in specs and smoke runs",
        "hint" => "put an executable chi-surely-missing-cmd on PATH" },
      { "command" => "sh" }
    ])
  end

  it "names a project bundle after the repository, also from a linked worktree" do
    repo = File.join(File.realpath(tmpdir), "My Repo")
    FileUtils.mkdir_p(repo)
    git = %w[git -c user.name=x -c user.email=x@x -c init.defaultBranch=main]
    system(*git, "-C", repo, "init", "-q", exception: true)
    system(*git, "-C", repo, "commit", "-q", "--allow-empty", "-m", "init", exception: true)
    tree = File.join(File.realpath(tmpdir), "my-repo-feature")
    system(*git, "-C", repo, "worktree", "add", "-q", "-b", "feature", tree, exception: true)

    builder = described_class.new(scope: "project", version: "1.0.0")
    names = [repo, tree].map { |dir| Dir.chdir(dir) { builder.send(:default_name, "project") } }
    expect(names).to eq(%w[chi_my-repo_memories chi_my-repo_memories])
  end

  describe "model overlays with --files" do
    before do
      { "tips.md" => "Base\n", "tips.qwen3.md" => "Qwen\n", "tips.deepseek.md" => "DeepSeek\n",
        "notes.v2.md" => "dotted\n", "other.md" => "x\n" }.each { |f, body| File.write(File.join(system_dir, f), body) }
    end

    it "a named base brings its overlays, with a note; a dotted memory without a base isn't one" do
      builder = described_class.new(scope: "system", out: File.join(tmpdir, "out"), files: %w[tips other])
      expect(builder.run[:files]).to eq(%w[tips.md tips.deepseek.md tips.qwen3.md other.md])
      expect(builder.warnings).to eq(["Included the model overlays of tips.md: tips.deepseek.md, tips.qwen3.md"])
    end

    it "warns about an overlay named without its base" do
      builder = described_class.new(scope: "system", out: File.join(tmpdir, "out"), files: %w[tips.qwen3 other])
      expect(builder.run[:files]).to eq(%w[tips.qwen3.md other.md])
      expect(builder.warnings).to eq(["tips.qwen3.md is a model overlay of tips.md, which the bundle leaves out; " \
                                      "it loads only where tips.md exists"])
    end

    it "an unfiltered build is unchanged" do
      builder = described_class.new(scope: "system", out: File.join(tmpdir, "out"))
      expect(builder.run[:files]).to eq(%w[notes.v2.md other.md tips.deepseek.md tips.md tips.qwen3.md])
      expect(builder.warnings).to eq([])
    end
  end
end
