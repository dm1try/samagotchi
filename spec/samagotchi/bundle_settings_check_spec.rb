# frozen_string_literal: true

require "spec_helper"
require "samagotchi/bundle_settings_check"
require "samagotchi/testing"

# config.yml `bundles:` against what's installed: warnings, never a refusal.
RSpec.describe Samagotchi::BundleSettingsCheck do
  around { |example| Samagotchi::Testing::Sandbox.with { |sandbox| @sandbox = sandbox; example.run } }

  def install(name, manifest = "")
    src = File.join(@sandbox.root, "src", name)
    FileUtils.mkdir_p(src)
    File.write(File.join(src, "manifest.yml"), "name: #{name}\nversion: 1.0.0\n#{manifest}")
    File.write(File.join(src, "notes.md"), "notes\n")
    Samagotchi::MemoryBundle::Installer.new(source: src, name: name, scope: "system", force: true).run
  end

  def warnings(section) = described_class.warnings(section)

  it "warns on a name that isn't installed, near an installed one if it is" do
    install("cost-cap")
    expect(warnings("cost-capp" => { "default" => 3 }, "zzz" => {})).to eq([
      "config.yml bundles: cost-capp: no installed bundle cost-capp (did you mean cost-cap?)",
      "config.yml bundles: zzz: no installed bundle zzz"
    ])
  end

  it "says nothing of a key while the manifest declares no settings:" do
    install("plain", "session_settings: [cap]\n")
    expect(warnings("plain" => { "anything" => 1 })).to eq([])
  end

  it "warns on a key settings: and session_settings: don't list, near a listed one if it is" do
    install("capped", "settings: [default, warn_at]\nsession_settings: [cap]\n")
    expect(warnings("capped" => { "default" => 1, "warn_at" => 1, "cap" => 1 })).to eq([])
    expect(warnings("capped" => { "defualt" => 1, "zzz" => 1 })).to eq([
      "config.yml bundles: capped.defualt: capped takes default, warn_at, cap (did you mean default?)",
      "config.yml bundles: capped.zzz: capped takes default, warn_at, cap"
    ])
  end

  it "warns on a value of another type than settings: gives, in --set's words" do
    install("typed", "settings: {limit: number, flag: boolean, name: string, free: any}\n")
    expect(warnings("typed" => { "limit" => false, "flag" => true, "name" => "x", "free" => { "a" => [1] } })).to eq([])
    expect(warnings("typed" => { "limit" => "five" })).to eq(["config.yml bundles: typed.limit: typed takes a number (or off) for limit, not \"five\""])
    expect { Samagotchi::SessionConfig.check!({ "typed" => { "limit" => "five" } }, bundles: { "typed" => ["limit"] }, types: { "typed" => { "limit" => "number" } }) }
      .to raise_error(Samagotchi::SessionConfig::Error, "--set typed.limit: typed takes a number (or off) for limit, not \"five\"")
  end

  it "takes settings: [] as none at all" do
    install("none", "settings: []\n")
    expect(warnings("none" => { "x" => 1 })).to eq(["config.yml bundles: none.x: none takes no settings"])
  end

  describe ".unshown" do
    let(:lines) { %w[one two] }
    let(:stamp) { described_class.stamp_path }

    it "lives under the state dir" do
      expect(stamp).to eq(File.join(Samagotchi::Paths.state_dir, "bundles_warned"))
    end

    it "shows the lines once, in whatever order they come" do
      expect(described_class.unshown(lines)).to eq(lines)
      expect(described_class.unshown(lines.reverse)).to eq([])
    end

    it "shows the lines when the stamp can't be written" do
      allow(Samagotchi::AtomicFile).to receive(:write).and_raise(Errno::EACCES)
      2.times { expect(described_class.unshown(lines)).to eq(lines) }
    end

    it "shows the lines when the stamp can't be read" do
      described_class.unshown(lines)
      allow(File).to receive(:read).with(stamp).and_raise(Errno::EACCES)
      expect(described_class.unshown(lines)).to eq(lines)
    end

    it "leaves no stamp with no lines" do
      expect(described_class.unshown([])).to eq([])
      expect(File.exist?(stamp)).to be(false)
    end
  end

  it "reads nothing with no bundles: section" do
    expect(Samagotchi::MemoryBundle::Provenance).not_to receive(:each_installed)
    expect(warnings({})).to eq([])
  end

  describe "the shipped bundles" do
    shipped = Dir[File.join(Samagotchi::Testing::Bundle::SHIPPED_DIR, "*", "manifest.yml")].sort.map { |path| File.dirname(path) }
    reads = /\bsettings(?:\[|\.key\?\(|\.fetch\(|\.dig\()"([a-z_]+)"/

    shipped.each do |dir|
      name = File.basename(dir)
      manifest = Samagotchi::MemoryBundle::Manifest.read(dir: dir)
      source = Dir[File.join(dir, "plugin.rb"), File.join(dir, "hooks", "*.rb")].map { |file| File.read(file) }.join("\n")
      # loop-guard's ThinkingWatch reads its own thinking: section's settings.
      source = source.sub(/^class ThinkingWatch.*?^end$/m, "") if name == "loop-guard"
      keys = source.scan(reads).flatten.uniq
      next if keys.empty?

      it "#{name} declares every setting its code reads" do
        expect(manifest.settings).not_to be_nil
        expect(keys - manifest.settings - manifest.session_settings).to eq([])
      end
    end
  end
end
