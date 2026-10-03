# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "samagotchi/installed_versions"

RSpec.describe Samagotchi::InstalledVersions do
  let(:root) { Dir.mktmpdir("installed-versions") }
  let(:specs_a) { File.join(root, "a", "specifications").tap { |d| FileUtils.mkdir_p(d) } }
  let(:specs_b) { File.join(root, "b", "specifications").tap { |d| FileUtils.mkdir_p(d) } }
  let(:gem_spec) { Gem::Specification.new { |s| s.name = "samagotchi"; s.version = "0.18.1" } }
  let(:env) { {} }

  after { FileUtils.rm_rf(root) }

  def touch(dir, name)
    File.write(File.join(dir, name), "")
  end

  def detector(**opts)
    described_class.new(env: env, gem_spec: gem_spec, dirs: -> { [specs_a, specs_b] }, **opts)
  end

  describe "#newest from an installed gem" do
    it "is the highest samagotchi gemspec across the specification dirs" do
      touch(specs_a, "samagotchi-0.17.0.gemspec")
      touch(specs_a, "samagotchi-0.18.1.gemspec")
      touch(specs_b, "samagotchi-0.18.10.gemspec")
      expect(detector.newest).to eq("0.18.10")
    end

    it "counts prereleases, as the `>= 0.a` a new worker activates does" do
      touch(specs_a, "samagotchi-0.18.1.gemspec")
      touch(specs_a, "samagotchi-0.19.0.pre1.gemspec")
      expect(detector.newest).to eq("0.19.0.pre1")
    end

    it "ignores other gems and files that only start with the name" do
      touch(specs_a, "samagotchi-0.18.1.gemspec")
      touch(specs_a, "samagotchi-plugins-9.0.0.gemspec")
      touch(specs_a, "samagotchi-9.0.0.gemspec.bak")
      touch(specs_a, "reline-0.6.3.gemspec")
      expect(detector.newest).to eq("0.18.1")
    end

    it "is nil when nothing is installed, and skips a missing dir" do
      FileUtils.rm_rf(specs_b)
      expect(detector.newest).to be_nil
    end

    it "lists a dir again only when its mtime changed" do
      touch(specs_a, "samagotchi-0.18.1.gemspec")
      allow(Dir).to receive(:children).and_call_original
      versions = detector
      expect(versions.newest).to eq("0.18.1")
      expect(versions.newest).to eq("0.18.1")
      expect(Dir).to have_received(:children).with(specs_a).once
    end

    it "sees a version installed after the first look" do
      touch(specs_a, "samagotchi-0.18.1.gemspec")
      versions = detector
      expect(versions.newest).to eq("0.18.1")
      touch(specs_b, "samagotchi-0.19.0.gemspec")
      File.utime(Time.now + 5, Time.now + 5, specs_b)
      expect(versions.newest).to eq("0.19.0")
    end
  end

  describe "#newest from a source checkout" do
    let(:gem_spec) { nil }
    let(:version_file) { File.join(root, "version.rb") }

    it "is the VERSION in version.rb on disk now" do
      File.write(version_file, %(module Samagotchi\n  VERSION = "0.19.0"\nend\n))
      versions = detector(version_file: version_file)
      expect(versions.newest).to eq("0.19.0")
      File.write(version_file, %(module Samagotchi\n  VERSION = "0.20.0"\nend\n))
      File.utime(Time.now + 5, Time.now + 5, version_file)
      expect(versions.newest).to eq("0.20.0")
    end

    it "is nil without the file" do
      expect(detector(version_file: version_file).newest).to be_nil
    end

    it "reads this checkout's own version.rb by default" do
      expect(described_class.new(env: env, gem_spec: nil).newest).to eq(Samagotchi::VERSION)
    end
  end

  it "answers SAMAGOTCHI_INSTALLED_VERSION when set" do
    env["SAMAGOTCHI_INSTALLED_VERSION"] = "99.0.0"
    expect(detector.newest).to eq("99.0.0")
  end

  describe ".newer?" do
    it "compares as Gem::Version does" do
      expect(described_class.newer?("0.18.10", "0.18.9")).to be(true)
      expect(described_class.newer?("0.18.1", "0.18.1")).to be(false)
      expect(described_class.newer?("0.19.0.pre1", "0.18.1")).to be(true)
      expect(described_class.newer?(nil, "0.18.1")).to be(false)
      expect(described_class.newer?("junk junk", "0.18.1")).to be(false)
    end
  end
end
