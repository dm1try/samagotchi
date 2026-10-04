# frozen_string_literal: true

require "samagotchi/memory_bundle/trash"
require "fileutils"
require "tmpdir"

RSpec.describe Samagotchi::MemoryBundle::Trash do
  # -- instance methods (unchanged) --

  describe "#move" do
    it "moves a file into the trash dir" do
      Dir.mktmpdir do |bundles_dir|
        File.join(bundles_dir, ".trash")
        file = File.join(bundles_dir, "original.md")
        File.write(file, "hello")

        trash = described_class.new("test-bundle", bundles_dir: bundles_dir)
        dest = trash.move(file)

        expect(File.exist?(file)).to be false
        expect(File.exist?(dest)).to be true
        expect(File.read(dest)).to eq("hello")
        expect(trash.dir).to match(%r{\.trash/test-bundle-\d{8}-\d{6}})
      end
    end
  end

  # -- class methods --

  describe ".entries" do
    it "returns [] when the trash dir doesn't exist" do
      Dir.mktmpdir do |bundles_dir|
        expect(described_class.entries(bundles_dir: bundles_dir)).to eq([])
      end
    end

    it "returns [] when the trash dir is empty" do
      Dir.mktmpdir do |bundles_dir|
        FileUtils.mkdir_p(File.join(bundles_dir, ".trash"))
        expect(described_class.entries(bundles_dir: bundles_dir)).to eq([])
      end
    end

    it "returns entries sorted oldest first" do
      Dir.mktmpdir do |bundles_dir|
        trash_dir = File.join(bundles_dir, ".trash")
        FileUtils.mkdir_p(trash_dir)

        # Create dirs with timestamps
        d_b = File.join(trash_dir, "bundle-b-20260102-120000")
        FileUtils.mkdir_p(d_b)
        File.write(File.join(d_b, "x.md"), "b")
        d_a = File.join(trash_dir, "bundle-a-20260101-120000")
        FileUtils.mkdir_p(d_a)
        File.write(File.join(d_a, "x.md"), "a")

        entries = described_class.entries(bundles_dir: bundles_dir)
        expect(entries.map(&:name)).to eq([
          "bundle-a-20260101-120000",
          "bundle-b-20260102-120000"
        ])
      end
    end

    it "uses mtime fallback when name has no timestamp" do
      Dir.mktmpdir do |bundles_dir|
        trash_dir = File.join(bundles_dir, ".trash")
        FileUtils.mkdir_p(trash_dir)

        old_dir = File.join(trash_dir, "old-stuff")
        FileUtils.mkdir_p(old_dir)
        File.write(File.join(old_dir, "x.md"), "x")
        old_time = Time.now - (86_400 * 10)
        File.utime(old_time, old_time, old_dir)

        new_dir = File.join(trash_dir, "new-stuff")
        FileUtils.mkdir_p(new_dir)
        File.write(File.join(new_dir, "x.md"), "x")

        entries = described_class.entries(bundles_dir: bundles_dir)
        expect(entries.map(&:name)).to eq(%w[old-stuff new-stuff])
        expect(entries[0].time).to be_within(1).of(old_time)
      end
    end

    it "counts files recursively" do
      Dir.mktmpdir do |bundles_dir|
        trash_dir = File.join(bundles_dir, ".trash")
        FileUtils.mkdir_p(trash_dir)

        dir = File.join(trash_dir, "bundle-20260101-120000")
        FileUtils.mkdir_p(File.join(dir, "sub"))
        File.write(File.join(dir, "a.md"), "aaa")
        File.write(File.join(dir, "sub", "b.md"), "bbb")
        File.write(File.join(dir, "sub", "c.md"), "cccc")

        entries = described_class.entries(bundles_dir: bundles_dir)
        expect(entries.first.files).to eq(3)
        expect(entries.first.bytes).to eq(3 + 3 + 4) # 10
      end
    end

    it "skips symlinks" do
      Dir.mktmpdir do |bundles_dir|
        trash_dir = File.join(bundles_dir, ".trash")
        FileUtils.mkdir_p(trash_dir)

        real_dir = File.join(trash_dir, "bundle-20260101-120000")
        FileUtils.mkdir_p(real_dir)
        File.write(File.join(real_dir, "x.md"), "x")

        # Create a symlink to the real dir
        symlink_dir = File.join(trash_dir, "bundle-20260102-120000")
        File.symlink(real_dir, symlink_dir)

        entries = described_class.entries(bundles_dir: bundles_dir)
        expect(entries.map(&:name)).to eq(["bundle-20260101-120000"])
      end
    end

    it "skips plain files in .trash" do
      Dir.mktmpdir do |bundles_dir|
        trash_dir = File.join(bundles_dir, ".trash")
        FileUtils.mkdir_p(trash_dir)

        real_dir = File.join(trash_dir, "bundle-20260101-120000")
        FileUtils.mkdir_p(real_dir)
        File.write(File.join(real_dir, "x.md"), "x")
        File.write(File.join(trash_dir, "random-file.txt"), "not a dir")

        entries = described_class.entries(bundles_dir: bundles_dir)
        expect(entries.map(&:name)).to eq(["bundle-20260101-120000"])
      end
    end
  end

  describe ".empty!" do
    it "deletes all entries" do
      Dir.mktmpdir do |bundles_dir|
        trash_dir = File.join(bundles_dir, ".trash")
        FileUtils.mkdir_p(trash_dir)

        d1 = File.join(trash_dir, "bundle-a-20260101-120000")
        FileUtils.mkdir_p(d1)
        File.write(File.join(d1, "x.md"), "x")
        d2 = File.join(trash_dir, "bundle-b-20260102-120000")
        FileUtils.mkdir_p(d2)
        File.write(File.join(d2, "y.md"), "y")

        deleted = described_class.empty!(bundles_dir: bundles_dir)
        expect(deleted.map(&:name)).to eq(["bundle-a-20260101-120000", "bundle-b-20260102-120000"])
        expect(Dir.exist?(d1)).to be false
        expect(Dir.exist?(d2)).to be false
      end
    end

    it "keeps newer entries when older_than_days is set" do
      now = Time.local(2026, 1, 10, 12, 0, 0)
      Dir.mktmpdir do |bundles_dir|
        trash_dir = File.join(bundles_dir, ".trash")
        FileUtils.mkdir_p(trash_dir)

        old_dir = File.join(trash_dir, "bundle-old-20260101-120000")
        FileUtils.mkdir_p(old_dir)
        File.write(File.join(old_dir, "x.md"), "x")
        new_dir = File.join(trash_dir, "bundle-new-20260109-120000")
        FileUtils.mkdir_p(new_dir)
        File.write(File.join(new_dir, "y.md"), "y")

        deleted = described_class.empty!(bundles_dir: bundles_dir, older_than_days: 5, now: now)
        expect(deleted.map(&:name)).to eq(["bundle-old-20260101-120000"])
        expect(Dir.exist?(old_dir)).to be false
        expect(Dir.exist?(new_dir)).to be true
      end
    end

    it "deletes nothing when all entries are newer than older_than_days" do
      now = Time.local(2026, 1, 10, 12, 0, 0)
      Dir.mktmpdir do |bundles_dir|
        trash_dir = File.join(bundles_dir, ".trash")
        FileUtils.mkdir_p(trash_dir)

        dir = File.join(trash_dir, "bundle-20260109-120000")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "x.md"), "x")

        deleted = described_class.empty!(bundles_dir: bundles_dir, older_than_days: 5, now: now)
        expect(deleted).to eq([])
        expect(Dir.exist?(dir)).to be true
      end
    end

    it "dry_run deletes nothing" do
      Dir.mktmpdir do |bundles_dir|
        trash_dir = File.join(bundles_dir, ".trash")
        FileUtils.mkdir_p(trash_dir)

        dir = File.join(trash_dir, "bundle-20260101-120000")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "x.md"), "x")

        deleted = described_class.empty!(bundles_dir: bundles_dir, dry_run: true)
        expect(deleted.map(&:name)).to eq(["bundle-20260101-120000"])
        expect(Dir.exist?(dir)).to be true
      end
    end

    it "returns [] for a missing trash" do
      Dir.mktmpdir do |bundles_dir|
        deleted = described_class.empty!(bundles_dir: bundles_dir)
        expect(deleted).to eq([])
      end
    end

    it "skips symlinks and files when emptying" do
      Dir.mktmpdir do |bundles_dir|
        trash_dir = File.join(bundles_dir, ".trash")
        FileUtils.mkdir_p(trash_dir)

        real_dir = File.join(trash_dir, "bundle-20260101-120000")
        FileUtils.mkdir_p(real_dir)
        File.write(File.join(real_dir, "x.md"), "x")

        symlink_dir = File.join(trash_dir, "bundle-20260102-120000")
        File.symlink(real_dir, symlink_dir)
        File.write(File.join(trash_dir, "random.txt"), "data")

        deleted = described_class.empty!(bundles_dir: bundles_dir)
        expect(deleted.map(&:name)).to eq(["bundle-20260101-120000"])
        expect(File.symlink?(symlink_dir)).to be true
        expect(File.exist?(File.join(trash_dir, "random.txt"))).to be true
      end
    end
  end
end
