# frozen_string_literal: true

require "spec_helper"
require "samagotchi/testing"

# The scale is pinned per example (CI runs the suite with SPEC_TIME_SCALE=2):
# each message is checked at the scale it names.
RSpec.describe Samagotchi::Testing::Waiting do
  include described_class

  def scale(value) = allow(described_class).to(receive(:time_scale).and_return(value))

  def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  describe ".time_scale" do
    it "reads SPEC_TIME_SCALE per call, at least 1, and 1 when unset or empty" do
      with_env("SPEC_TIME_SCALE" => nil) { expect(described_class.time_scale).to eq(1.0) }
      with_env("SPEC_TIME_SCALE" => "") { expect(described_class.time_scale).to eq(1.0) }
      with_env("SPEC_TIME_SCALE" => "2") { expect(described_class.time_scale).to eq(2.0) }
      with_env("SPEC_TIME_SCALE" => "1.5") { expect(described_class.time_scale).to eq(1.5) }
      with_env("SPEC_TIME_SCALE" => "0.5") { expect(described_class.time_scale).to eq(1.0) }
    end

    it "gives 1 for a value that isn't a number, warning once" do
      described_class.instance_variable_set(:@warned_scale, nil)
      with_env("SPEC_TIME_SCALE" => "fast") do
        expect { expect(described_class.time_scale).to eq(1.0) }.to output(/SPEC_TIME_SCALE="fast" is not a number/).to_stderr
        expect { described_class.time_scale }.not_to output.to_stderr
      end
    end
  end

  describe "#wait_until" do
    before { scale(1.0) }

    it "gives the block's truthy value, or its last falsy one at the deadline" do
      calls = 0
      expect(wait_until { (calls += 1) >= 3 && :done }).to eq(:done)
      expect(wait_until(timeout: 0.05) { nil }).to be_nil
    end

    it "waits the timeout × the scale" do
      scale(4.0)
      started = mono
      expect(wait_until(timeout: 0.05) { false }).to be(false)
      expect(mono - started).to be >= 0.2
    end
  end

  describe "#wait_for" do
    it "gives the block's truthy value" do
      scale(1.0)
      calls = 0
      expect(wait_for("the third call") { (calls += 1) >= 3 && :done }).to eq(:done)
    end

    it "raises TimedOut naming what it waited for, at scale 1 without the scale" do
      scale(1.0)
      expect { wait_for("the moon", timeout: 0.05) { false } }
        .to raise_error(described_class::TimedOut, "timed out after 0.05 s waiting for the moon")
    end

    it "names the scaled deadline and the scale when there is one, and waits that long" do
      scale(2.0)
      started = mono
      expect { wait_for("the moon", timeout: 0.05) { false } }
        .to raise_error(described_class::TimedOut, "timed out after 0.1 s (0.05 s × SPEC_TIME_SCALE 2) waiting for the moon")
      expect(mono - started).to be >= 0.1
    end

    it "shows what seen: last saw, its inspect cut to 300 chars" do
      scale(1.0)
      expect { wait_for("the task to end", timeout: 0.02, seen: -> { "running" }) { false } }
        .to raise_error('timed out after 0.02 s waiting for the task to end; last saw: "running"')
      expect { wait_for("a short line", timeout: 0.02, seen: -> { "x" * 400 }) { false } }
        .to raise_error(described_class::TimedOut) { |error| expect(error.message).to end_with("last saw: \"#{"x" * 299}…") }
    end

    it "is a StandardError, so a spec may expect it" do
      expect(described_class::TimedOut.ancestors).to include(StandardError)
    end
  end

  describe "#time_bound" do
    it "scales the bound, kept under the unscaled deadline it tells apart from" do
      scale(1.0)
      expect(time_bound(1.5)).to eq(1.5)
      expect(time_bound(1.8, below: 2)).to eq(1.8)
      scale(2.0)
      expect(time_bound(1.5)).to eq(3.0)
      expect(time_bound(5, below: 30)).to eq(10.0)
      expect(time_bound(1.8, below: 2)).to eq(2)
    end
  end

  describe "the message" do
    it "is one format for every helper: 5 s, or the scaled deadline with its parts" do
      expect(described_class.timed_out_message("x", 5, scale: 1.0)).to eq("timed out after 5 s waiting for x")
      expect(described_class.timed_out_message("task 1 to end", 5, scale: 2.0, seen: -> { "running" }))
        .to eq('timed out after 10.0 s (5 s × SPEC_TIME_SCALE 2) waiting for task 1 to end; last saw: "running"')
      expect(described_class.timed_out_message("x", 0.05, scale: 1.5)).to eq("timed out after 0.075 s (0.05 s × SPEC_TIME_SCALE 1.5) waiting for x")
    end
  end

  describe "#join! and #pop!" do
    it "give the thread or the value, and share wait_for's message (join! adds 'to finish')" do
      scale(2.0)
      done = Thread.new { :ok }
      expect(join!(done, "the thread")).to be(done)
      queue = Queue.new << :value
      expect(pop!(queue, "the value")).to eq(:value)

      stuck = Thread.new { sleep } # sleep-ok: the thread that never ends
      expect { join!(stuck, "the stuck thread", timeout: 0.02) }
        .to raise_error(described_class::TimedOut, "timed out after 0.04 s (0.02 s × SPEC_TIME_SCALE 2) waiting for the stuck thread to finish")
      expect { pop!(Queue.new, "a push", timeout: 0.02) }
        .to raise_error(described_class::TimedOut, "timed out after 0.04 s (0.02 s × SPEC_TIME_SCALE 2) waiting for a push")
    ensure
      stuck&.kill&.join
    end
  end

  it "#process_gone? tells a reaped process from a live one" do
    pid = Process.spawn("true")
    Process.wait(pid)
    expect(process_gone?(pid)).to be true
    expect(process_gone?(Process.pid)).to be false
  end
end

RSpec.describe SpecWaiting do
  def scale(value) = allow(Samagotchi::Testing::Waiting).to(receive(:time_scale).and_return(value))

  it "works as a module too (SpecWaiting.pop!, outside an example group)" do
    scale(1.0)
    expect(described_class.pop!(Queue.new << 1, "one")).to eq(1)
    expect { described_class.wait_for("the moon", timeout: 0.02) { false } }
      .to raise_error(Samagotchi::Testing::Waiting::TimedOut, "timed out after 0.02 s waiting for the moon")
  end

  describe "#eventually" do
    it "retries the block until its expectations hold, and gives its value" do
      scale(1.0)
      calls = 0
      expect(eventually { expect(calls += 1).to be >= 3 }).to be(true)
      expect(calls).to eq(3)
    end

    it "raises the last failure again after the deadline, the matcher's own text after the prefix" do
      scale(1.0)
      values = %w[queued running]
      expect { eventually(timeout: 0.05) { expect(values.rotate!.first).to eq("completed") } }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError,
                        /\Astill failing after 0.05 s:\nexpected: "completed"\n     got: "(queued|running)"/)
    end

    it "names the scale in the prefix when there is one" do
      scale(2.0)
      value = 1
      expect { eventually(timeout: 0.02) { expect(value).to eq(2) } }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /\Astill failing after 0.04 s \(0.02 s × SPEC_TIME_SCALE 2\):\nexpected: 2/)
    end

    it "lets any other error through at once" do
      scale(1.0)
      calls = 0
      expect { eventually { calls += 1; raise ArgumentError, "bad" } }.to raise_error(ArgumentError, "bad")
      expect(calls).to eq(1)
    end
  end
end
