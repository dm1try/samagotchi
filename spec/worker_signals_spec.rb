# frozen_string_literal: true

require "spec_helper"
require "samagotchi/worker_signals"

RSpec.describe Samagotchi::WorkerSignals do
  it "records the first signal and counts them, running the handler on a thread of its own per signal" do
    signals = described_class.new
    calls = Queue.new
    signals.on_signal { |name, count| calls << [name, count, Thread.current] }

    signals.fire("TERM").join(1)
    signals.fire("INT").join(1)

    expect(signals.signal).to eq("TERM")
    expect(signals.count).to eq(2)
    first = calls.pop
    second = calls.pop
    expect([first.first(2), second.first(2)]).to eq([["TERM", 1], ["INT", 2]])
    expect(first.last).not_to eq(Thread.current)
  end

  it "records a signal that comes before any handler (the worker's run registers it)" do
    signals = described_class.new
    expect(signals.fire("HUP")).to be_nil
    expect(signals.signal).to eq("HUP")
  end

  it "calls the hard exit it was given" do
    exited = []
    described_class.new(hard_exit: -> { exited << true }).hard_exit
    expect(exited).to eq([true])
  end

  it "has a null object that traps and fires nothing" do
    none = described_class::NONE
    expect(none.on_signal { raise "never" }).to be_nil
    expect(none.signal).to be_nil
    expect(none.count).to eq(0)
  end

  # Traps only ever go into a process of its own (a fork), never the rspec
  # process, as in a real worker.
  it "traps TERM, HUP and INT in its process and restores the earlier handlers" do
    skip "fork unavailable" unless Process.respond_to?(:fork)

    reader, writer = IO.pipe
    pid = fork do
      reader.close
      signals = described_class.new
      fired = Queue.new
      signals.on_signal do |name, count|
        writer.puts("#{name} #{count}")
        fired << name
      end
      signals.install!
      Process.kill("TERM", Process.pid)
      Process.kill("HUP", Process.pid)
      2.times { pop!(fired, "a trapped signal's handler") }
      signals.restore!
      writer.puts(Signal.trap("TERM", "DEFAULT").is_a?(Proc) ? "proc" : "restored")
      writer.close
      exit!(0)
    end
    writer.close
    lines = Timeout.timeout(5) { reader.read.lines.map(&:strip) } # timeout-ok: a hang guard: the read ends when the child exits
    _, status = Process.wait2(pid)

    expect(status.exitstatus).to eq(0)
    expect(lines.first(2)).to eq(["TERM 1", "HUP 2"])
    expect(lines.last).to eq("restored")
  ensure
    reader&.close
  end
end
