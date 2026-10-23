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

  describe "across two machines (a remote attach, P4-D10)" do
    let(:via) { Samagotchi::ChiInvocation.new(remote: "studio") }

    def remote_line(worker:, installed:, terminal:)
      described_class.at_attach(worker: worker, installed: installed, session_id: "abcdef1234", terminal: terminal, via: via)
    end

    it "advises each machine where it runs: the worker there, this terminal here" do
      expect(remote_line(worker: "0.103.0", installed: "0.104.0", terminal: "0.104.0"))
        .to eq("chi> the session's worker runs chi 0.103.0; studio has 0.104.0 installed: chi --remote studio sessions restart abcdef12")
      expect(remote_line(worker: "0.104.0", installed: "0.104.0", terminal: "0.103.0"))
        .to eq("chi> this terminal runs chi 0.103.0 (studio has 0.104.0): chi update here")
      expect(remote_line(worker: "0.103.0", installed: "0.104.0", terminal: "0.102.0"))
        .to eq("chi> the session's worker runs chi 0.103.0; studio has 0.104.0 installed: chi --remote studio sessions " \
               "restart abcdef12. This terminal runs chi 0.102.0 (studio has 0.104.0): chi update here")
    end

    it "says nothing when the worker is that machine's newest and this terminal isn't behind it" do
      expect(remote_line(worker: "0.104.0", installed: "0.104.0", terminal: "0.105.0")).to be_nil
      expect(remote_line(worker: "0.104.0", installed: nil, terminal: "0.104.0")).to be_nil
    end
  end

  it "names the restarted worker's version" do
    expect(described_class.restarted("0.19.0")).to eq("chi> the session's worker restarted on chi 0.19.0")
    expect(described_class.restarted(nil)).to eq("chi> the session's worker restarted")
  end
end
