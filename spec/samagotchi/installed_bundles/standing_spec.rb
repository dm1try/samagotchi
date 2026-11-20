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

    it "warns once per process per bundle of a record that doesn't read, whichever reader asks (D4)" do
      record("b-broken", "{")
      record("c-list", "[]")
      notices = []
      allow(Samagotchi::Log).to receive(:warn) { |tag, event, fields| notices << [tag, event, fields] }

      3.times { Samagotchi::InstalledBundles.standings(dir: dir).to_a }
      Samagotchi::InstalledBundles.claimants("a.md", scope: "system", dir: dir)
      expect(notices.map { |tag, event, fields| [tag, event, fields[:bundle]] })
        .to eq([[:memory, "bundle_unreadable", "b-broken"], [:memory, "bundle_unreadable", "c-list"]])
      expect(notices.last[2][:msg]).to eq("manifest.json is not an object")
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

    # One order and one wording for every kind (the plan's D6): no sha
    # recorded, then missing, then changed (both shas kept); a dev link passes.
    { plugin: "plugin", scripts: "scripts", guardrails: "guardrails" }.each do |kind, folder|
      it "checks #{folder}/: not recorded, then missing, then changed" do
        what = "bundle demo's #{folder}/f.rb"
        expect(bundle.file_refusal(kind, "f.rb", nil).to_h)
          .to eq(kind: :file_unrecorded, text: "#{what} isn't recorded (reinstall the bundle)", actual: nil, expected: nil)
        expect(bundle.file_refusal(kind, "f.rb", "").kind).to eq(:file_unrecorded)
        expect(bundle.file_refusal(kind, "f.rb", "sha256:#{"0" * 64}").to_h)
          .to eq(kind: :file_missing, text: "#{what} is missing (reinstall the bundle)", actual: nil, expected: nil)
        file("demo", "#{folder}/f.rb", "x\n")
        expect(bundle.file_refusal(kind, "f.rb", "")&.kind).to eq(:file_unrecorded)
        expect(bundle.file_refusal(kind, "f.rb", "sha256:#{sha("x\n")}")).to be_nil
        expect(bundle.file_refusal(kind, "f.rb", sha("x\n"))).to be_nil
        expect(bundle.file_refusal(kind, "f.rb", Samagotchi::InstalledBundles::Sha::DEV)).to be_nil
        expect(bundle.file_refusal(kind, "f.rb", "0" * 64).to_h)
          .to eq(kind: :file_changed, text: "#{what} differs from the installed one (reinstall the bundle)",
                 actual: sha("x\n"), expected: "0" * 64)
      end
    end

    it "says a plugin the record names no file of is missing" do
      expect(bundle.file_refusal(:plugin, nil, "sha256:#{"0" * 64}").to_h)
        .to include(kind: :file_missing, text: "bundle demo's plugin is missing (reinstall the bundle)")
    end

    it "knows only those three kinds" do
      expect { bundle.file_refusal(:hooks, "x.rb", nil) }.to raise_error(ArgumentError)
    end
  end
end
