# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "yaml"
require "samagotchi/memory_bundle/installer"
require "samagotchi/memory_bundle/manifest_standing"

RSpec.describe Samagotchi::MemoryBundle::ManifestStanding do
  let(:tmp) { Dir.mktmpdir("manifest-standing") }
  let(:shipped) { Samagotchi::MemoryBundle::SourceNormalizer::SHIPPED_DIR }
  let(:provenance) { Samagotchi::MemoryBundle::Provenance.new(name: "known-names") }

  around { |example| with_config_home(File.join(tmp, "config")) { example.run } }
  after { FileUtils.remove_entry(tmp) }

  # known-names as another gem shipped it at this version (its own shipped dir),
  # installed from there by a chi that didn't keep the manifest.
  def install_legacy_from_another_gem(memory_text: nil)
    dest = File.join(tmp, "gems", "samagotchi-x", "lib", "samagotchi", "bundles", "known-names")
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp_r(File.join(shipped, "known-names"), dest)
    if memory_text
      data = YAML.load_file(File.join(dest, "manifest.yml"))
      key = data["files"].keys.first
      File.write(File.join(dest, key), memory_text)
      data["files"][key] = "sha256:#{Digest::SHA256.hexdigest(memory_text)}"
      File.write(File.join(dest, "manifest.yml"), YAML.dump(data))
    end
    Samagotchi::MemoryBundle::Installer.new(source: dest, name: "known-names", scope: "system", strict: true,
                                            shipped_dir: File.dirname(dest)).run
    path = File.join(provenance.bundle_dir, "manifest.json")
    File.write(path, JSON.generate(JSON.parse(File.read(path)).except("manifest_sha", "installed_by")))
    FileUtils.rm_f(provenance.kept_manifest_path)
    provenance.record
  end

  describe ".status_line for a bundle chi ships" do
    it "says chi update keeps it when this chi's shipped copy is what's installed" do
      expect(described_class.status_line(install_legacy_from_another_gem))
        .to eq("installed by an older chi, which didn't keep its manifest: chi update keeps it")
    end

    it "checks this chi's shipped copy, which chi update reads, not the recorded one" do
      line = described_class.status_line(install_legacy_from_another_gem(memory_text: "another gem's text\n"))
      expect(line).to start_with("installed by an older chi, which didn't keep its manifest: chi bundle upgrade known-names (")
        .and end_with("isn't the installed one)")
    end
  end
end
