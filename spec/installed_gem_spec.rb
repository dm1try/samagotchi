# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "samagotchi/installed_gem"

RSpec.describe Samagotchi::InstalledGem do
  let(:gem_dir) { Dir.mktmpdir("gem-dir") }
  let(:spec) do
    Gem::Specification.new { |s| s.name = "samagotchi"; s.version = "9.9.9" }.tap do |s|
      s.loaded_from = File.join(Dir.tmpdir, "specifications", "samagotchi-9.9.9.gemspec")
      allow(s).to receive(:full_gem_path).and_return(gem_dir)
    end
  end

  after { FileUtils.rm_rf(gem_dir) }

  describe ".spec" do
    it "is nil from a source checkout (this suite runs from one)" do
      expect(described_class.spec).to be_nil
    end

    it "is the activated installed spec when its directory is this code's" do
      allow(Gem).to receive(:loaded_specs).and_return("samagotchi" => spec)
      expect(described_class.spec(gem_dir)).to be(spec)
      expect(described_class.spec(Dir.tmpdir)).to be_nil
    end

    it "is nil for Bundler's path gem (the checkout's own gemspec)" do
      spec.loaded_from = File.join(gem_dir, "samagotchi.gemspec")
      allow(Gem).to receive(:loaded_specs).and_return("samagotchi" => spec)
      expect(described_class.spec(gem_dir)).to be_nil
    end
  end
end
