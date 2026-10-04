# frozen_string_literal: true

require "stringio"
require "pty"
require "io/console"
require "samagotchi/terminal_ui/live_region"

RSpec.describe Samagotchi::TerminalUI::LiveRegion do
  let(:tty) { StringIO.new.tap { |io| io.define_singleton_method(:tty?) { true } } }
  let(:pipe) { StringIO.new }

  after do
    screen = Samagotchi::TerminalUI::RelineSeam.screen
    described_class.close(screen) if screen
  end

  before { allow(Reline).to receive(:ambiguous_width).and_return(1) }

  it "draws a live region with Reline's prompt in it on a terminal" do
    surface = described_class.open(out: tty, input: tty, env: { "TERM" => "xterm-256color" })

    expect(surface).to be_a(Samagotchi::TerminalUI::Screen)
    expect(Samagotchi::TerminalUI::RelineSeam.screen).to be(surface)
  end

  {
    "output is not a terminal" => [:pipe, :tty, "xterm"],
    "input is not a terminal" => [:tty, :pipe, "xterm"],
    "TERM is dumb" => [:tty, :tty, "dumb"]
  }.each do |why, (out, input, term)|
    it "opens none when #{why}" do
      surface = described_class.open(out: send(out), input: send(input), env: { "TERM" => term })

      expect(surface).to be_nil
      expect(Samagotchi::TerminalUI::RelineSeam.screen).to be_nil
    end
  end

  it "opens none when the installed Reline doesn't have what the seam needs" do
    allow(Samagotchi::TerminalUI::RelineSeam).to receive(:supported?).and_return(false)

    expect(described_class.open(out: tty, input: tty, env: { "TERM" => "xterm" })).to be_nil
  end

  it "hands Reline its own drawing and $stderr back when it closes" do
    stderr = $stderr
    surface = described_class.open(out: tty, input: tty, env: { "TERM" => "xterm" })
    expect($stderr).to be_a(Samagotchi::TerminalUI::Screen::ErrorOutput)

    described_class.close(surface)

    expect(Samagotchi::TerminalUI::RelineSeam.screen).to be_nil
    expect($stderr).to be(stderr)
  end

  # Reline asks for the cursor row (ESC[6n) as each read starts: the reply
  # to one cut short at exit would land at the shell's prompt.
  it "drops what the terminal sent but nobody read before it hands the terminal back" do
    PTY.open do |terminal, input|
      surface = described_class.open(out: tty, input: input, env: { "TERM" => "xterm" })
      terminal.write("\e[12;1R")
      terminal.flush

      described_class.close(surface, input: input)

      left = input.raw { input.wait_readable(0.1) && input.read_nonblock(64, exception: false) }
      expect(left).to be_nil
    end
  end

  # A slow terminal (ssh): the read was stopped while Reline waited for the
  # reply, which comes after the region closed.
  it "waits for the reply to a cursor query a stopped read left unanswered, and no longer" do
    # A long reply wait, so "no longer" is told apart from running out the
    # wait by a wide margin instead of a tight wall-clock bound.
    stub_const("#{described_class}::CURSOR_REPLY_WAIT", 5.0)
    PTY.open do |terminal, input|
      surface = described_class.open(out: tty, input: input, env: { "TERM" => "xterm" })
      Samagotchi::TerminalUI::RelineSeam.unanswered_query_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      written_at = nil
      replier = Thread.new do
        sleep 0.1
        terminal.write("\e[12;1R")
        terminal.flush
        written_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      described_class.close(surface, input: input)
      closed_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      replier.join

      left = input.raw { input.wait_readable(0.1) && input.read_nonblock(64, exception: false) }
      expect(left).to be_nil
      # Timed from the reply itself: a loaded CI runner can wake the replier
      # late (0.50 s seen on macOS) or the closer late after it (0.19 s seen
      # on macOS against DRAIN_WINDOW 0.05), and close must wait for the
      # reply either way, then stop soon after instead of running out its
      # whole (here 5 s) wait.
      expect(closed_at).to be >= written_at
      expect(closed_at - written_at).to be < 2.0
      expect(Samagotchi::TerminalUI::RelineSeam.unanswered_query_at).to be_nil
    end
  end
end
