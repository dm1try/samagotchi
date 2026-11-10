# frozen_string_literal: true

require "spec_helper"
require "samagotchi/terminal_ui/version_lines"

RSpec.describe Samagotchi::TerminalUI::VersionLines do
  def line(worker:, installed:, terminal:)
    described_class.at_attach(worker: worker, installed: installed, terminal: terminal, session_id: "abcdef12-3456")
  end

  it "tells how to move a worker older than this terminal or the newest installed" do
    expect(line(worker: "0.158.1", installed: "0.160.0", terminal: "0.160.0"))
      .to eq("chi> chi 0.160.0 is installed; this session's worker runs 0.158.1. " \
             "chi sessions restart abcdef12 moves it there (this terminal follows).")
    expect(line(worker: "0.158.1", installed: nil, terminal: "0.160.0")).to include("worker runs 0.158.1")
  end

  it "does not suggest restarting a worker from the previous minor" do
    expect(line(worker: "0.159.9", installed: "0.160.0", terminal: "0.160.0")).to be_nil
  end

  it "tells an older terminal to attach again" do
    expect(line(worker: "0.160.0", installed: "0.160.0", terminal: "0.158.1"))
      .to eq("chi> chi 0.160.0 is installed; this terminal runs 0.158.1. /detach, then chi --attach abcdef12 to use it.")
  end

  it "says both in one line" do
    expect(line(worker: "0.155.0", installed: "0.160.0", terminal: "0.157.1"))
      .to eq("chi> chi 0.160.0 is installed; this session's worker runs 0.155.0 and this terminal 0.157.1. " \
             "chi sessions restart abcdef12 moves the worker; /detach, then chi --attach abcdef12 for the terminal.")
    expect(line(worker: "0.160.0", installed: "99.0.0", terminal: "0.160.0"))
      .to start_with("chi> chi 99.0.0 is installed; this session's worker runs 0.160.0 and this terminal 0.160.0.")
  end

  it "says nothing when all is current, the worker is the newer one, or it doesn't say its version" do
    expect(line(worker: "0.160.0", installed: "0.160.0", terminal: "0.160.0")).to be_nil
    expect(line(worker: "0.161.0", installed: "0.160.0", terminal: "0.160.0")).to be_nil
    expect(line(worker: nil, installed: "0.161.0", terminal: "0.160.0")).to be_nil
  end

  describe "across two machines (a remote attach, P4-D10)" do
    let(:via) { Samagotchi::ChiInvocation.new(remote: "studio") }

    def remote_line(worker:, installed:, terminal:)
      described_class.at_attach(worker: worker, installed: installed, session_id: "abcdef1234", terminal: terminal, via: via)
    end

    it "advises each machine where it runs: the worker there, this terminal here" do
      expect(remote_line(worker: "0.158.0", installed: "0.160.0", terminal: "0.160.0"))
        .to eq("chi> the session's worker runs chi 0.158.0; studio has 0.160.0 installed: chi --remote studio sessions restart abcdef12")
      expect(remote_line(worker: "0.160.0", installed: "0.160.0", terminal: "0.158.0"))
        .to eq("chi> this terminal runs chi 0.158.0 (studio has 0.160.0): chi update here")
      expect(remote_line(worker: "0.158.0", installed: "0.160.0", terminal: "0.157.0"))
        .to eq("chi> the session's worker runs chi 0.158.0; studio has 0.160.0 installed: chi --remote studio sessions " \
               "restart abcdef12. This terminal runs chi 0.157.0 (studio has 0.160.0): chi update here")
    end

    it "says nothing when the worker is that machine's newest and this terminal isn't behind it" do
      expect(remote_line(worker: "0.160.0", installed: "0.160.0", terminal: "0.161.0")).to be_nil
      expect(remote_line(worker: "0.160.0", installed: nil, terminal: "0.160.0")).to be_nil
      expect(remote_line(worker: "0.160.0", installed: "", terminal: "0.160.0")).to be_nil
    end
  end

  it "names the restarted worker's version" do
    expect(described_class.restarted("0.19.0")).to eq("chi> the session's worker restarted on chi 0.19.0")
    expect(described_class.restarted(nil)).to eq("chi> the session's worker restarted")
  end
end
