# frozen_string_literal: true

require "samagotchi/degrade"
require "fileutils"
require "tmpdir"

RSpec.describe Samagotchi::Degrade do
  let(:dir) { Dir.mktmpdir("samagotchi-degrade") }
  let(:path) { File.join(dir, "samagotchi.log") }

  before { Samagotchi::Log.configure(path: path, level: :debug) }
  after { FileUtils.remove_entry(dir) if File.directory?(dir) }

  def records
    return [] unless File.exist?(path)

    File.open(path) { |io| Samagotchi::LogLine.each_record(io).to_a }
  end

  it "returns the block's value and logs nothing when it succeeds" do
    expect(described_class.call(:prompt, "section_failed", fallback: nil) { "text" }).to eq("text")
    expect(records).to eq([])
  end

  it "returns the fallback on a StandardError and logs one WARN with the error, then DEBUG" do
    3.times do
      value = described_class.call(:prompt, "section_failed", fallback: [], name: "notes") { raise IOError, "gone" }
      expect(value).to eq([])
    end

    expect(records.map(&:level)).to eq(%w[WARN DEBUG DEBUG])
    expect(records.first.to_h).to include(tag: "prompt", event: "section_failed")
    expect(records.first.fields).to eq("error" => "IOError", "msg" => "gone", "name" => "notes")
  end

  it "keys the once-per-process WARN by [area, event] only" do
    described_class.call(:prompt, "a_failed") { raise "one" }
    described_class.call(:prompt, "a_failed") { raise "two" }
    described_class.call(:prompt, "b_failed") { raise "three" }
    described_class.call(:bridge, "a_failed") { raise "four" }

    expect(records.map { |r| [r.level, r.tag, r.event] }).to eq(
      [%w[WARN prompt a_failed], %w[DEBUG prompt a_failed], %w[WARN prompt b_failed], %w[WARN bridge a_failed]]
    )
  end

  it "warns again after reset!" do
    described_class.call(:prompt, "a_failed") { raise "one" }
    described_class.reset!
    described_class.call(:prompt, "a_failed") { raise "two" }

    expect(records.map(&:level)).to eq(%w[WARN WARN])
  end

  it "rescues only the classes given in rescue:" do
    value = described_class.call(:prompt, "a_failed", fallback: :gone, rescue: [Errno::ENOENT]) { raise Errno::ENOENT }
    expect(value).to eq(:gone)
    expect { described_class.call(:prompt, "a_failed", rescue: Errno::ENOENT) { raise ArgumentError } }
      .to raise_error(ArgumentError)
  end

  it "never rescues an Exception that isn't a StandardError" do
    expect { described_class.call(:prompt, "a_failed") { raise Interrupt } }.to raise_error(Interrupt)
    expect(records).to eq([])
  end

  it "truncates the message to 500 characters" do
    described_class.call(:prompt, "a_failed") { raise "x" * 900 }

    expect(records.first.fields["msg"].size).to eq(500)
  end

  it "checks the tag and event on every call in strict mode, the happy path too" do
    expect { described_class.call(:nope, "a_failed") { 1 } }.to raise_error(ArgumentError, /unknown log tag nope/)
    expect { described_class.call(:prompt, "Bad Event") { 1 } }.to raise_error(ArgumentError, /bad log event/)
  end

  it "logs a degradation its caller handled with note" do
    expect(described_class.note(:bridge, "event_dropped", RuntimeError.new("boom"), kind: "x")).to be_nil
    described_class.note(:bridge, "event_dropped", RuntimeError.new("again"))

    expect(records.map(&:level)).to eq(%w[WARN DEBUG])
    expect(records.first.fields).to eq("error" => "RuntimeError", "msg" => "boom", "kind" => "x")
  end

  it "writes nothing to stderr" do
    expect { described_class.call(:prompt, "a_failed") { raise "boom" } }.not_to output.to_stderr
  end
end
