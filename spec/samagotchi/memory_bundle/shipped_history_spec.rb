# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "json"
require "yaml"

require "samagotchi/memory_bundle/shipped_history"

RSpec.describe Samagotchi::MemoryBundle::ShippedHistory do
  let(:tmp) { File.realpath(Dir.mktmpdir("samagotchi-shipped-history-")) }
  let(:gem_home) { File.join(tmp, "home-gems") }
  let(:asked) { File.join(tmp, "asked.md").tap { |path| File.write(path, "shipped text\n") } }
  let(:lib) { File.expand_path("../../../lib", __dir__) }

  after { FileUtils.rm_rf(tmp) }

  def ship(root, version: "0.2.0", name: "demo", dir: "renamed-dir", file: "a.md", text: "shipped text\n")
    bundle = File.join(root, "gems", "samagotchi-#{version}", "lib", "samagotchi", "bundles", dir)
    FileUtils.mkdir_p(bundle)
    File.write(File.join(bundle, file), text)
    File.write(File.join(bundle, "manifest.yml"), YAML.dump({ "name" => name, "version" => "1.0.0", "scope" => "system" }))
  end

  # A fresh process, as a chi launch is: no Bundler, none of this suite's gem path.
  # BUNDLER_SETUP too: RubyGems requires what it names at boot, whatever RUBYOPT
  # says, and a bundle with a `path` (CI's) then replaces GEM_HOME and GEM_PATH.
  def ask(prelude: "", env: {})
    script = "raise 'under Bundler' if defined?(Bundler); #{prelude}; require 'samagotchi/memory_bundle/shipped_history'; " \
             "print Samagotchi::MemoryBundle::ShippedHistory.shipped?('demo', 'a.md', #{asked.inspect})"
    clean = { "GEM_HOME" => nil, "GEM_PATH" => nil, "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil,
              "BUNDLE_BIN_PATH" => nil, "BUNDLER_SETUP" => nil, "XDG_CONFIG_HOME" => File.join(tmp, "config") }
    out, err, status = Open3.capture3(clean.merge(env), RbConfig.ruby, "-I", lib, "-e", script)
    expect(status).to be_success, err
    out
  end

  def record_home(gem_path)
    dir = File.join(tmp, "config", "samagotchi")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "home.json"),
               JSON.generate("ruby" => RbConfig.ruby, "gem_home" => gem_path, "gem_path" => gem_path))
  end

  it "finds it under a chi home's boot string, as a worker runs" do
    ship(gem_home)

    expect(ask).to eq("false")
    expect(ask(prelude: "Gem.paths = {'GEM_HOME' => #{gem_home.inspect}, 'GEM_PATH' => #{gem_home.inspect}}")).to eq("true")
  end

  it "finds it in the chi home's gems from a plain ruby on other gems: a checkout, a chruby shell" do
    ship(gem_home)
    record_home(gem_home)

    expect(ask).to eq("true")
    expect(ask(env: { "GEM_PATH" => File.join(tmp, "elsewhere") })).to eq("true")
  end

  it "finds it on a stray GEM_PATH without a chi home" do
    ship(gem_home)

    expect(ask(env: { "GEM_PATH" => gem_home })).to eq("true")
  end

  it "answers false, not an error, on a home.json it can't use" do
    ship(gem_home)
    FileUtils.mkdir_p(File.join(tmp, "config", "samagotchi"))
    File.write(File.join(tmp, "config", "samagotchi", "home.json"), "not json")

    expect(ask).to eq("false")
  end

  it "answers false when the file asked about can't be read, or the gem path holds a file" do
    ship(gem_home)
    allow(Gem).to receive(:path).and_return([gem_home])
    expect(described_class.shipped?("demo", "a.md", File.join(tmp, "missing"))).to be false

    allow(Gem).to receive(:path).and_return([asked])
    expect(described_class.shipped?("demo", "a.md", asked)).to be false
  end

  it "answers false on a manifest it can't decode, and on a home.json that isn't valid UTF-8" do
    allow(Gem).to receive(:path).and_return([gem_home])
    ship(gem_home)
    manifest = File.join(gem_home, "gems", "samagotchi-0.2.0", "lib", "samagotchi", "bundles", "renamed-dir", "manifest.yml")
    File.binwrite(manifest, "\xFF\xFEn\x00a\x00m\x00e\x00".b)
    expect(described_class.shipped?("demo", "a.md", asked)).to be false

    File.binwrite(manifest, "name: \xE9\xFF\n".b)
    expect(described_class.shipped?("demo", "a.md", asked)).to be false

    File.write(manifest, YAML.dump({ "name" => "demo" }))
    FileUtils.mkdir_p(File.join(tmp, "config", "samagotchi"))
    File.binwrite(File.join(tmp, "config", "samagotchi", "home.json"), "{\"ruby\": \"\xE9\xFF\"}".b)
    with_env("XDG_CONFIG_HOME" => File.join(tmp, "config")) { expect(described_class.shipped?("demo", "a.md", asked)).to be true }
  end

  it "treats the file key as a name, not a pattern or a path" do
    allow(Gem).to receive(:path).and_return([gem_home])
    ship(gem_home)
    ship(gem_home, dir: "other", file: "b.md", name: "demo", text: "other text\n")

    ["*.md", "a.m?", "[a].md", "{a,b}.md", "../renamed-dir/a.md", "x/../a.md", "/a.md", "a.md/"].each do |key|
      expect(described_class.shipped?("demo", key, asked)).to be(false), "#{key} matched"
    end
    expect(described_class.shipped?("demo", "a.md", asked)).to be true
  end

  it "finds a file under a gem dir whose path holds glob characters" do
    ["gems[1]", "gems{a,b}", "gems*"].each do |name|
      root = File.join(tmp, name)
      ship(root)
      allow(Gem).to receive(:path).and_return([root])
      expect(described_class.shipped?("demo", "a.md", asked)).to be(true), "#{name} missed"
    end
  end

  it "takes a version with a platform and a prerelease, not another gem" do
    allow(Gem).to receive(:path).and_return([gem_home])
    ship(gem_home, version: "tools-0.2.0")
    expect(described_class.shipped?("demo", "a.md", asked)).to be false

    ship(gem_home, version: "0.3.0.pre1")
    expect(described_class.shipped?("demo", "a.md", asked)).to be true
  end
end
