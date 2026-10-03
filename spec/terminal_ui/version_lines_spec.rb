# frozen_string_literal: true

require "spec_helper"
require "samagotchi/terminal_ui/version_lines"

RSpec.describe Samagotchi::TerminalUI::VersionLines do
  def line(worker:, installed:, terminal:)
    described_class.at_attach(worker: worker, installed: installed, terminal: terminal, session_id: "abcdef12-3456")
  end

  it "tells how to move a worker older than this terminal or the newest installed" do
    expect(line(worker: "0.18.1", installed: "0.19.0", terminal: "0.19.0"))
      .to eq("chi> chi 0.19.0 is installed; this session's worker runs 0.18.1. " \
             "chi sessions restart abcdef12 moves it there (this terminal follows).")
    expect(line(worker: "0.18.1", installed: nil, terminal: "0.19.0")).to include("worker runs 0.18.1")
  end

  it "tells an older terminal to attach again" do
    expect(line(worker: "0.19.0", installed: "0.19.0", terminal: "0.18.1"))
      .to eq("chi> chi 0.19.0 is installed; this terminal runs 0.18.1. /detach, then chi --attach abcdef12 to use it.")
  end

  it "says both in one line" do
    expect(line(worker: "0.18.0", installed: "0.19.0", terminal: "0.18.1"))
      .to eq("chi> chi 0.19.0 is installed; this session's worker runs 0.18.0 and this terminal 0.18.1. " \
             "chi sessions restart abcdef12 moves the worker; /detach, then chi --attach abcdef12 for the terminal.")
  end

  it "says nothing when all is current, the worker is the newer one, or it doesn't say its version" do
    expect(line(worker: "0.19.0", installed: "0.19.0", terminal: "0.19.0")).to be_nil
    expect(line(worker: "0.20.0", installed: "0.19.0", terminal: "0.19.0")).to be_nil
    expect(line(worker: nil, installed: "0.20.0", terminal: "0.19.0")).to be_nil
  end

  it "names the restarted worker's version" do
    expect(described_class.restarted("0.19.0")).to eq("chi> the session's worker restarted on chi 0.19.0")
    expect(described_class.restarted(nil)).to eq("chi> the session's worker restarted")
  end
end
