# frozen_string_literal: true

require "samagotchi/idle_scheduler"

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
      scheduler.tick
      expect(job_b).to have_received(:tick).once
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
