# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/bundle_needs"

RSpec.describe Samagotchi::BundleNeeds do
  let(:tmpdir) { Dir.mktmpdir("samagotchi-needs-") }
  after { FileUtils.rm_rf(tmpdir) }

  def make_file(dir, name, mode)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, name)
    File.write(path, "#!/bin/sh\n")
    File.chmod(mode, path)
    path
  end

  describe ".found?" do
    it "finds an executable file in any PATH folder" do
      bin = File.join(tmpdir, "bin")
      make_file(bin, "fakecmd", 0o755)
      expect(described_class.found?("fakecmd", path: ["/nonexistent", bin].join(File::PATH_SEPARATOR))).to be(true)
    end

    it "doesn't count a file that isn't executable" do
      make_file(tmpdir, "fakecmd", 0o644)
      expect(described_class.found?("fakecmd", path: tmpdir)).to be(false)
    end

    it "doesn't count a directory with that name" do
      FileUtils.mkdir_p(File.join(tmpdir, "fakecmd"))
      File.chmod(0o755, File.join(tmpdir, "fakecmd"))
      expect(described_class.found?("fakecmd", path: tmpdir)).to be(false)
    end

    it "finds nothing on an empty or missing PATH" do
      expect(described_class.found?("sh", path: "")).to be(false)
      expect(described_class.found?("sh", path: nil)).to be(false)
    end
  end

  describe ".missing and .marker" do
    it "keeps only the needs not found and names them in the marker" do
      make_file(tmpdir, "here", 0o755)
      needs = [{ command: "here" }, { command: "gone1" }, { command: "gone2" }]
      missing = described_class.missing(needs, path: tmpdir)
      expect(missing.map { |n| n[:command] }).to eq(%w[gone1 gone2])
      expect(described_class.marker(missing)).to eq("[needs gone1, gone2: not found on PATH]")
    end

    it "has no marker when nothing is missing" do
      expect(described_class.marker([])).to be_nil
    end
  end
end
