# frozen_string_literal: true

require "samagotchi/debug_log"
require "fileutils"
require "tmpdir"

RSpec.describe Samagotchi::DebugLog do
  let(:dir) { Dir.mktmpdir("samagotchi-debug-log") }
  after { FileUtils.remove_entry(dir) if File.directory?(dir) }

  it "appends records, creating the directory" do
    path = File.join(dir, "nested", "chi.log")
    log = described_class.new(path: path)
    log.write("one\n")
    log.write("two\n")
    log.close

    expect(File.read(path)).to eq("one\ntwo\n")
  end

  it "does nothing without a path" do
    expect(described_class.new(path: nil).write("x\n")).to be(false)
    expect(described_class.new(path: " ")).not_to be_enabled
  end

  it "pauses after an IO error and tries again after a minute" do
    now = 0.0
    path = File.join(dir, "chi.log")
    FileUtils.mkdir_p(path) # a directory: opening it for append fails
    log = described_class.new(path: path, clock: -> { now })

    expect(log.write("a\n")).to be(false)
    FileUtils.rmdir(path)
    now = 30.0
    expect(log.write("b\n")).to be(false)
    now = 61.0
    expect(log.write("c\n")).to be(true)
    log.close

    expect(File.read(path)).to eq("c\n")
  end
end

RSpec.describe Samagotchi::DebugLog, "rotation" do
  let(:dir) { Dir.mktmpdir("samagotchi-debug-log") }
  let(:path) { File.join(dir, "chi.log") }
  after { FileUtils.remove_entry(dir) if File.directory?(dir) }

  def log(**options) = described_class.new(path: path, max_bytes: 20, **options)

  it "moves a file over the cap to .1 and goes on in a new one" do
    writer = log
    writer.write("0123456789\n")
    writer.write("0123456789\n") # 22 bytes now
    writer.write("after\n")
    writer.close

    expect(File.read("#{path}.1")).to eq("0123456789\n0123456789\n")
    expect(File.read(path)).to eq("after\n")
  end

  it "keeps one old file" do
    writer = log
    %w[aaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbb cccc].each { |line| writer.write("#{line}\n") }
    writer.close

    expect(File.read("#{path}.1")).to eq("bbbbbbbbbbbbbbbbbbbb\n")
    expect(File.read(path)).to eq("cccc\n")
    expect(Dir.children(dir).sort).to eq(%w[chi.log chi.log.1 chi.log.lock])
  end

  it "follows another process's rotation: the next record goes to the new file, not .1" do
    first = log
    second = log
    first.write("aaaaaaaaaaaaaaaaaaaaaa\n")
    second.write("from second\n") # over the cap: second rotates
    first.write("from first\n")    # first's file is .1 now: it reopens

    expect(File.read("#{path}.1")).to eq("aaaaaaaaaaaaaaaaaaaaaa\n")
    expect(File.read(path)).to eq("from second\nfrom first\n")
  ensure
    first&.close
    second&.close
  end

  it "skips rotating while another process holds the lock, and rotates on a later write" do
    writer = log
    writer.write("aaaaaaaaaaaaaaaaaaaaaa\n")
    File.open("#{path}.lock", File::RDWR | File::CREAT) do |held|
      held.flock(File::LOCK_EX)
      writer.write("while locked\n")
      expect(File.exist?("#{path}.1")).to be(false)
    end
    writer.write("later\n")
    writer.close

    expect(File.read("#{path}.1")).to eq("aaaaaaaaaaaaaaaaaaaaaa\nwhile locked\n")
    expect(File.read(path)).to eq("later\n")
  end

  it "reopens a file that was deleted" do
    writer = log(max_bytes: 1_000)
    writer.write("one\n")
    File.delete(path)
    writer.write("two\n")
    writer.close

    expect(File.read(path)).to eq("two\n")
  end

  it "never rotates what isn't a regular file" do
    writer = described_class.new(path: File::NULL, max_bytes: 1)
    3.times { expect(writer.write("x\n")).to be(true) }
    writer.close
  end
end
