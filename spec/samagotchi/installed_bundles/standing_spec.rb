# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "digest"
require "samagotchi/installed_bundles"

RSpec.describe "InstalledBundles' usability verdict" do
  let(:dir) { Dir.mktmpdir("samagotchi-standing-") }

  after { FileUtils.rm_rf(dir) }

  def record(name, body)
    FileUtils.mkdir_p(File.join(dir, name))
    File.write(File.join(dir, name, "manifest.json"), body.is_a?(String) ? body : JSON.generate(body))
  end

  def file(name, rel, content)
    path = File.join(dir, name, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def sha(content) = Digest::SHA256.hexdigest(content)

  describe ".standings" do
    it "says why chi won't use a bundle: a record that doesn't read, then requires_chi; nothing for the rest" do
      record("a-ok", "version" => "1.0.0")
      record("b-broken", "{")
      record("c-list", "[]")
      record("d-too-new", "version" => "1.0.0", "requires_chi" => ">= 999.0")

      standings = Samagotchi::InstalledBundles.standings(dir: dir).to_a
      expect(standings.map(&:name)).to eq(%w[a-ok b-broken c-list d-too-new])
      expect(standings.map { |s| s.refusal&.kind }).to eq([nil, :unreadable, :unreadable, :too_new])
      expect(standings[0]).to be_usable
      expect(standings[1].refusal.text).to start_with("manifest.json is unreadable: ")
      expect(standings[2].refusal.text).to eq("manifest.json is not an object")
      expect(standings[3]).to be_too_new
      expect(standings[3].refusal.text).to eq("it requires chi >= 999.0 (this is chi #{Samagotchi::VERSION})")
    end

    it "walks as .each does with holding:" do
      record("a-plain", "version" => "1.0.0")
      record("b-plug", "version" => "1.0.0", "plugin" => { "file" => "plugin.rb" })
      expect(Samagotchi::InstalledBundles.standings(holding: :plugin, dir: dir).map(&:name)).to eq(["b-plug"])
    end
  end

  describe ".standing" do
    it "reads one record: nil when not installed, its Standing otherwise" do
      record("one", "version" => "1.0.0", "requires_chi" => ">= 999.0")
      expect(Samagotchi::InstalledBundles.standing("none", dir: dir)).to be_nil
      expect(Samagotchi::InstalledBundles.standing("one", dir: dir)).to be_too_new
    end

    it "lets a record that doesn't parse raise, as Dir#record does (kept for the plan's D7)" do
      record("broken", "{")
      expect { Samagotchi::InstalledBundles.standing("broken", dir: dir) }.to raise_error(JSON::ParserError)
    end
  end

  describe "Dir#file_refusal" do
    let(:bundle) { Samagotchi::InstalledBundles::Dir.new(name: "demo", dir: dir) }

    it "checks a plugin: missing, then no sha recorded, then changed (both shas kept); a dev link passes" do
      expect(bundle.file_refusal(:plugin, nil, nil).kind).to eq(:file_missing)
      expect(bundle.file_refusal(:plugin, "plugin.rb", "").to_h).to eq(kind: :file_missing, text: "the file is missing", actual: nil, expected: nil)
      file("demo", "plugin/plugin.rb", "x\n")
      expect(bundle.file_refusal(:plugin, "plugin.rb", "").to_h)
        .to eq(kind: :file_unrecorded, text: "no sha256 recorded for it (reinstall the bundle)", actual: nil, expected: nil)
      expect(bundle.file_refusal(:plugin, "plugin.rb", "sha256:#{sha("x\n")}")).to be_nil
      expect(bundle.file_refusal(:plugin, "plugin.rb", sha("x\n"))).to be_nil
      expect(bundle.file_refusal(:plugin, "plugin.rb", Samagotchi::InstalledBundles::Sha::DEV)).to be_nil
      changed = bundle.file_refusal(:plugin, "plugin.rb", "0" * 64)
      expect(changed).to have_attributes(kind: :file_changed, actual: sha("x\n"), expected: "0" * 64)
      expect(changed.text).to eq("its sha256 #{sha("x\n")[0, 12]}… differs from the installed 000000000000… " \
                                 "(edited after install? reinstall the bundle)")
    end

    it "checks a script: no sha recorded, then missing, then changed" do
      expect(bundle.file_refusal(:scripts, "s.rb", nil).to_h)
        .to include(kind: :file_unrecorded, text: "bundle demo's scripts/s.rb isn't among its installed scripts (reinstall the bundle)")
      expect(bundle.file_refusal(:scripts, "s.rb", "sha256:#{"0" * 64}").to_h)
        .to include(kind: :file_missing, text: "bundle demo's scripts/s.rb is missing (reinstall the bundle)")
      file("demo", "scripts/s.rb", "s\n")
      expect(bundle.file_refusal(:scripts, "s.rb", "sha256:#{sha("s\n")}")).to be_nil
      expect(bundle.file_refusal(:scripts, "s.rb", Samagotchi::InstalledBundles::Sha::DEV)).to be_nil
      expect(bundle.file_refusal(:scripts, "s.rb", "sha256:#{"0" * 64}").to_h)
        .to include(kind: :file_changed, text: "bundle demo's scripts/s.rb differs from the installed one (reinstall the bundle)")
    end

    it "checks a rule: missing, then changed, an empty recorded sha reading as changed" do
      expect(bundle.file_refusal(:guardrails, "r.yml", "").to_h).to include(kind: :file_missing, text: "the file is missing")
      file("demo", "guardrails/r.yml", "rules: []\n")
      expect(bundle.file_refusal(:guardrails, "r.yml", "sha256:#{sha("rules: []\n")}")).to be_nil
      expect(bundle.file_refusal(:guardrails, "r.yml", "").to_h)
        .to include(kind: :file_changed, text: "its sha256 differs from the installed one (edited after install? reinstall the bundle)")
    end

    it "knows only those three kinds" do
      expect { bundle.file_refusal(:hooks, "x.rb", nil) }.to raise_error(ArgumentError)
    end
  end
end
