# frozen_string_literal: true

require "spec_helper"
require "digest"
require "fileutils"
require "tmpdir"
require "samagotchi/memory_bundle/file_digest"

# The one way to digest a file on disk: hex for a comparison, sha256:<hex> for
# what a record writes.
RSpec.describe Samagotchi::MemoryBundle::FileDigest do
  let(:tmp) { Dir.mktmpdir("file-digest-") }

  after { FileUtils.rm_rf(tmp) }

  def write(rel, text)
    path = File.join(tmp, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end

  describe ".hex" do
    it "is the SHA256 of the file's bytes, binary" do
      path = write("a.md", "hello\n")
      expect(described_class.hex(path)).to eq(Digest::SHA256.hexdigest("hello\n"))

      bin = write("bin.dat", "\u0000\u00FF\x00\xFF".b)
      expect(described_class.hex(bin)).to eq(Digest::SHA256.hexdigest(File.binread(bin)))
    end

    it "is nil for a path that isn't a file: missing or a directory" do
      expect(described_class.hex(File.join(tmp, "nope.md"))).to be_nil

      dir = File.join(tmp, "a dir")
      FileUtils.mkdir_p(dir)
      expect(described_class.hex(dir)).to be_nil
    end

    it "raises for a file that is there but can't be read" do
      skip "root reads a 000 file anyway" if Process.uid.zero?

      path = write("locked.bin", "x")
      FileUtils.chmod(0, path)
      expect { described_class.hex(path) }.to raise_error(SystemCallError)
    end
  end

  describe ".sha256" do
    it "is the hex with the sha256: prefix the records write" do
      path = write("h.rb", "class Hook; end\n")
      expect(described_class.sha256(path)).to eq("sha256:#{Digest::SHA256.hexdigest("class Hook; end\n")}")
    end

    it "is nil for a missing file" do
      expect(described_class.sha256(File.join(tmp, "nope.rb"))).to be_nil
    end
  end
end
