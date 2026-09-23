# frozen_string_literal: true

require "stringio"
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
end
