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
