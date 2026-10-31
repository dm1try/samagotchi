# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/side_judgments"

RSpec.describe Samagotchi::SideJudgments do
  subject(:judgments) { described_class.new }

  let(:warned) { [] }
  let(:warn) { ->(error) { warned << error } }

  it "runs the block off the calling thread and hands its value to finish" do
    finished = Queue.new
    caller_thread = Thread.current

    thread = judgments.start(:demo, warn: warn, finish: ->(result) { finished << result }) do
      Thread.current == caller_thread ? :same : :other
    end
    join!(thread, "the ask")

    expect(pop!(finished, "the result")).to eq(:other)
    expect(warned).to be_empty
  end

  it "keeps one ask in flight per kind, not across kinds" do
    release = Queue.new
    first = judgments.start(:demo, warn: warn) { release.pop }

    expect(judgments.in_flight?(:demo)).to be(true)
    expect(judgments.start(:demo, warn: warn) { :second }).to be_nil
    other = judgments.start(:other, warn: warn) { :other }
    expect(other).to be_a(Thread)
    join!(other, "the other kind's ask")

    release << true
    join!(first, "the first ask")
    expect(judgments.in_flight?(:demo)).to be(false)
    expect(judgments.thread(:demo)).to eq(first)
  end

  it "warns instead of raising and still finishes with nil" do
    finished = Queue.new
    join!(judgments.start(:demo, warn: warn, finish: ->(result) { finished << result }) { raise "boom" }, "the ask")

    expect(finished.size).to eq(1)
    expect(finished.pop(true)).to be_nil
    expect(warned.map(&:message)).to eq(["boom"])
  end

  it "treats a cancelled request as no answer, without a warn" do
    finished = Queue.new
    thread = judgments.start(:demo, warn: warn, finish: ->(result) { finished << result }) do
      raise Samagotchi::LLM::RequestCancelled, "stopped"
    end
    join!(thread, "the ask")

    expect(finished.size).to eq(1)
    expect(finished.pop(true)).to be_nil
    expect(warned).to be_empty
  end

  it "joins the running asks within the given time, in all" do
    release = Queue.new
    threads = [judgments.start(:a, warn: warn) { release.pop }, judgments.start(:b, warn: warn) { release.pop }]
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    expect(judgments.join(0.2)).to be(judgments)

    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.0
  ensure
    2.times { release << true }
    threads&.each { |thread| join!(thread, "an ask") }
  end

  it "appends JSONL lines 0600 and warns under its tag when a write fails" do
    Dir.mktmpdir("side-judgments") do |dir|
      log = described_class.log(File.join(dir, "demo.jsonl"), tag: :demo, event: "demo_log_failed")
      log.entry("asked", "p" => 0.5)

      line = JSON.parse(File.read(File.join(dir, "demo.jsonl")))
      expect(line).to include("kind" => "asked", "p" => 0.5)
      expect(File.stat(File.join(dir, "demo.jsonl")).mode & 0o777).to eq(0o600)

      allow(Samagotchi::Log).to receive(:warn)
      blocked = described_class.log(File.join(dir, "demo.jsonl", "nested.jsonl"), tag: :demo, event: "demo_log_failed")
      blocked.entry("asked", {})
      expect(Samagotchi::Log).to have_received(:warn).with(:demo, "demo_log_failed", hash_including(:echo))
    end
  end
end
