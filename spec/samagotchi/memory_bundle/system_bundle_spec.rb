# frozen_string_literal: true

require "spec_helper"
require "digest"
require "samagotchi/memory_bundle/system_bundle"

RSpec.describe Samagotchi::MemoryBundle::SystemBundle do
  describe "shipped bundle manifest" do
    let(:dir) { described_class::GEM_BUNDLE_DIR }
    let(:manifest) { Samagotchi::MemoryBundle::Manifest.read(dir: dir) }

    it "lists every bundled memory file" do
      shipped = Dir.glob(File.join(dir, "*.md")).map { |p| File.basename(p) }.sort
      expect(manifest.files.keys.map(&:to_s).sort).to eq(shipped)
    end

    it "has checksums matching the bundled files (edit a file → refresh its sha256 and bump the version)" do
      manifest.files.each_key do |file_key|
        actual = Digest::SHA256.hexdigest(File.read(File.join(dir, file_key.to_s)))
        expect(manifest.checksum_for(file_key.to_s)).to eq(actual), "stale checksum for #{file_key}"
      end
    end
  end
end
