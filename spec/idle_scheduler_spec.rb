# frozen_string_literal: true

require "samagotchi/idle_scheduler"
require "fileutils"
require "tmpdir"

RSpec.describe Samagotchi::IdleScheduler do
  subject(:scheduler) { described_class.new(engine: engine, jobs: jobs) }

  let(:engine) { double("Engine") }
  let(:jobs) { [job_a, job_b] }
  let(:job_a) { double("JobA", tick: nil) }
  let(:job_b) { double("JobB", tick: nil) }

  describe "#initialize" do
    it "requires an engine" do
      expect { described_class.new(jobs: []) }.to raise_error(ArgumentError)
    end

    it "drops nil jobs" do
      scheduler = described_class.new(engine: engine, jobs: [job_a, nil])
      expect(scheduler.jobs).to eq([job_a])
    end
  end

  describe "#start" do
    it "spawns a single background thread" do
      scheduler.start
      expect(scheduler.running?).to be true
      scheduler.stop
    end

    it "is idempotent" do
      scheduler.start
      scheduler.start
      expect(scheduler.running?).to be true
      scheduler.stop
    end

    it "is a no-op when there are no jobs" do
      scheduler = described_class.new(engine: engine, jobs: [])
      scheduler.start
      expect(scheduler.running?).to be false
    end
  end

  describe "#stop" do
    it "kills the background thread and is idempotent" do
      scheduler.start
      scheduler.stop
      scheduler.stop
      expect(scheduler.running?).to be false
      expect(scheduler.instance_variable_get(:@thread)).to be_nil
    end
  end

  describe "#tick" do
    it "steps every job in order" do
      scheduler.tick
      expect(job_a).to have_received(:tick).once
      expect(job_b).to have_received(:tick).once
    end

    it "isolates a failing job — the next job still ticks" do
      allow(job_a).to receive(:tick).and_raise(RuntimeError, "boom")
      expect { scheduler.tick }.to output(/\[IdleScheduler\] .* tick failed: RuntimeError: boom/).to_stderr
      expect(job_b).to have_received(:tick).once
    end

    it "logs the failure (stderr text unchanged, a WARN idle record in the file)" do
      dir = Dir.mktmpdir("samagotchi-log")
      path = File.join(dir, "chi.log")
      Samagotchi::Log.configure(path: path)
      allow(job_a).to receive(:tick).and_raise(RuntimeError, "boom")
      expect { scheduler.tick }.to output.to_stderr

      record = File.open(path) { |io| Samagotchi::LogLine.each_record(io).first }
      expect(record.to_h).to include(level: "WARN", tag: "idle", event: "tick_failed")
      expect(record.fields).to include("error" => "RuntimeError", "msg" => a_string_ending_with("tick failed: RuntimeError: boom"))
    ensure
      FileUtils.remove_entry(dir)
    end

    it "logs a crash of its thread as an ERROR with the backtrace" do
      dir = Dir.mktmpdir("samagotchi-log")
      path = File.join(dir, "chi.log")
      Samagotchi::Log.configure(path: path)
      allow(scheduler).to receive(:tick).and_raise(TypeError, "bad")

      expect { scheduler.send(:run_loop) }.to output(/scheduler thread crashed: TypeError: bad/).to_stderr

      record = File.open(path) { |io| Samagotchi::LogLine.each_record(io).first }
      expect(record.to_h).to include(level: "ERROR", tag: "idle", event: "scheduler_crashed")
      expect(record.payload).not_to be_empty
    ensure
      FileUtils.remove_entry(dir)
    end

    it "does nothing once stopped" do
      scheduler.stop
      scheduler.tick
      expect(job_a).not_to have_received(:tick)
    end
  end

  describe "background loop" do
    it "ticks jobs repeatedly until stopped" do
      counts = Hash.new(0)
      job_a = double("JobA")
      job_b = double("JobB")
      allow(job_a).to receive(:tick) { counts[:a] += 1 }
      allow(job_b).to receive(:tick) { counts[:b] += 1 }
      scheduler = described_class.new(engine: engine, jobs: [job_a, job_b])
      scheduler.start
      sleep(1.2) # a few 0.5s poll cycles
      scheduler.stop
      expect(counts[:a]).to be >= 2
      expect(counts[:b]).to be >= 2
    end
  end
end
