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

  describe "#replace_job" do
    let(:job_c) { double("JobC", tick: nil) }

    it "swaps a job in place, adds one for a nil old and drops one for a nil new" do
      expect(scheduler.replace_job(job_a, job_c).jobs).to eq([job_c, job_b])
      expect(scheduler.replace_job(job_c, nil).jobs).to eq([job_b])
      expect(scheduler.replace_job(nil, job_a).jobs).to eq([job_b, job_a])
      expect(scheduler.replace_job(nil, nil).jobs).to eq([job_b, job_a])
    end

    # A long interval: after the thread's first tick it waits, so the
    # example's own tick is the only one left and the counts are exact.
    it "keeps the running thread, which ticks the new job" do
      ticked = Queue.new
      allow(job_b).to receive(:tick) { ticked << true }
      scheduler = described_class.new(engine: engine, jobs: jobs, interval: 60)
      scheduler.start
      thread = scheduler.instance_variable_get(:@thread)
      pop!(ticked, "the thread's first tick")

      scheduler.replace_job(job_a, job_c)
      scheduler.tick
      expect(job_a).to have_received(:tick).once
      expect(job_c).to have_received(:tick).once
      expect(job_b).to have_received(:tick).twice
      expect(scheduler.instance_variable_get(:@thread)).to equal(thread)
    ensure
      scheduler.stop
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
    # The thread's first tick has run; it waits out its interval (60 s).
    def started(scheduler, ticked)
      scheduler.start
      pop!(ticked, "the thread's first tick")
      scheduler.instance_variable_get(:@thread).tap { |thread| allow(thread).to receive(:kill).and_call_original }
    end

    it "stops the background thread and is idempotent" do
      scheduler.start
      scheduler.stop
      scheduler.stop
      expect(scheduler.running?).to be false
      expect(scheduler.instance_variable_get(:@thread)).to be_nil
    end

    it "wakes a thread waiting out its interval and joins it, with no kill" do
      stub_const("#{described_class}::STOP_JOIN_SECONDS", 30)
      ticked = Queue.new
      allow(job_b).to receive(:tick) { ticked << true }
      scheduler = described_class.new(engine: engine, jobs: jobs, interval: 60)
      thread = started(scheduler, ticked)

      scheduler.stop

      expect(thread).not_to be_alive
      expect(thread).not_to have_received(:kill)
      expect(thread.name).to eq(described_class::THREAD_NAME)
    end

    it "kills a thread whose tick is still blocked after STOP_JOIN_SECONDS" do
      stub_const("#{described_class}::STOP_JOIN_SECONDS", 0.05)
      ticked = Queue.new
      gate = Queue.new
      allow(job_b).to receive(:tick) do
        ticked << true
        pop!(gate, "the example to open the gate", timeout: 30)
      end
      scheduler = described_class.new(engine: engine, jobs: jobs, interval: 60)
      thread = started(scheduler, ticked)

      scheduler.stop

      expect(thread).to have_received(:kill)
      join!(thread, "the killed thread")
    ensure
      gate << true
    end

    it "with join: false returns while a tick runs, and the thread exits after it" do
      ticked = Queue.new
      gate = Queue.new
      allow(job_b).to receive(:tick) do
        ticked << true
        pop!(gate, "the example to open the gate", timeout: 30)
      end
      scheduler = described_class.new(engine: engine, jobs: jobs, interval: 60)
      thread = started(scheduler, ticked)

      scheduler.stop(join: false)
      expect(thread).to be_alive
      expect(scheduler.running?).to be false

      gate << true
      join!(thread, "the thread's last tick")
      expect(thread).not_to have_received(:kill)
      expect(job_b).to have_received(:tick).once
    ensure
      gate << true
    end

    it "leaves the thread of a stop(join: false) for a later stop to join" do
      ticked = Queue.new
      gate = Queue.new
      allow(job_b).to receive(:tick) do
        ticked << true
        pop!(gate, "the example to open the gate", timeout: 30)
      end
      scheduler = described_class.new(engine: engine, jobs: jobs, interval: 60)
      thread = started(scheduler, ticked)
      allow(thread).to receive(:join).and_call_original

      scheduler.stop(join: false)
      expect(thread).not_to have_received(:join)
      gate << true
      scheduler.stop

      expect(thread).to have_received(:join).with(described_class::STOP_JOIN_SECONDS)
      expect(thread).not_to be_alive
      expect(thread).not_to have_received(:kill)
    ensure
      gate << true
    end

    # Engine#shutdown calls #stop first: a raise here would skip the rest of
    # its teardown (plugin tasks, MCP servers).
    it "logs a thread that died of a non-StandardError instead of raising it again from the join" do
      fatal = Class.new(Exception) # rubocop:disable Lint/InheritException -- what run_loop doesn't rescue
      report = Thread.report_on_exception
      Thread.report_on_exception = false
      allow(job_a).to receive(:tick).and_raise(fatal, "deep")
      scheduler = described_class.new(engine: engine, jobs: jobs, interval: 60).start
      thread = scheduler.instance_variable_get(:@thread)
      wait_for("the scheduler's thread to die") { !thread.alive? }

      expect { expect(scheduler.stop).to be_nil }.to output(/scheduler thread died: .*deep/).to_stderr
    ensure
      Thread.report_on_exception = report
    end

    it "is safe from inside a tick: it doesn't join its own thread, which ends after the tick" do
      scheduler = described_class.new(engine: engine, jobs: jobs, interval: 60)
      stopped = Queue.new
      allow(job_b).to receive(:tick) do
        scheduler.stop
        stopped << Thread.current
      end
      scheduler.start

      thread = pop!(stopped, "the tick that stops the scheduler")
      join!(thread, "the scheduler's thread")
      expect(job_a).to have_received(:tick).once
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

    it "logs the failure (stderr text unchanged, an ERROR idle record with the backtrace in the file)" do
      dir = Dir.mktmpdir("samagotchi-log")
      path = File.join(dir, "chi.log")
      Samagotchi::Log.configure(path: path)
      allow(job_a).to receive(:tick).and_raise(RuntimeError, "boom")
      expect { scheduler.tick }.to output.to_stderr

      record = File.open(path) { |io| Samagotchi::LogLine.each_record(io).first }
      expect(record.to_h).to include(level: "ERROR", tag: "idle", event: "tick_failed")
      expect(record.fields).to include("error" => "RuntimeError", "msg" => "boom", "job" => job_a.class.name)
      expect(record.payload).not_to be_empty
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
      scheduler = described_class.new(engine: engine, jobs: [job_a, job_b], interval: 0.01)
      scheduler.start
      wait_for("two ticks of each job", seen: -> { counts }) { counts.values_at(:a, :b).min >= 2 }
      scheduler.stop
      expect(counts[:a]).to be >= 2
      expect(counts[:b]).to be >= 2
    end

    it "waits POLL_INTERVAL_SECONDS between ticks by default" do
      expect(described_class.new(engine: engine).interval).to eq(described_class::POLL_INTERVAL_SECONDS)
    end
  end
end
