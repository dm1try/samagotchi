# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "samagotchi/terminal_ui/remote_connector"

# TerminalUI::RemoteConnector: the wake through chi web, and its failures
# as AttachLauncher::Error in the words they came with.
RSpec.describe Samagotchi::TerminalUI::RemoteConnector do
  let(:remote) do
    instance_double(Samagotchi::SessionAccess::Remote, name: "studio", attach_client: :client,
                                                       invocation: Samagotchi::ChiInvocation.new(remote: "studio"))
  end
  let(:woke) do
    Samagotchi::SessionAccess::WakeReply.new(woke: true, worker: { "epoch" => "e1", "features" => [] }, default_model: nil,
                                             strategy: nil, installed: nil)
  end
  let(:err) { StringIO.new }
  let(:connector) { described_class.new(remote, session_id: "ab12", hostname: "mac.local", err: err) }

  def worker_reply(leaving: false, leave_seconds: nil)
    Samagotchi::SessionAccess::WorkerReply.new(live: false, stopped: false, worker: nil, strategy: nil,
                                               leaving: leaving, leave_seconds: leave_seconds)
  end

  before { allow(remote).to receive(:attach_worker).with("ab12").and_return(worker_reply) }

  it "wakes the session there and answers its RemoteLink" do
    allow(remote).to receive(:attach_wake).and_return(woke)

    link = connector.connect

    expect(link).to be_a(Samagotchi::TerminalUI::RemoteLink)
    expect(link.client).to eq(:client)
    expect(remote).to have_received(:attach_wake)
      .with("ab12", wait: Samagotchi::TerminalUI::AttachLauncher::BRIDGE_WAIT, read_timeout: nil)
    expect(err.string).to eq("")
  end

  it "says a worker there is still leaving (its recap) and lets the wake's read wait for it" do
    allow(remote).to receive(:attach_worker).with("ab12").and_return(worker_reply(leaving: true, leave_seconds: 80.0))
    allow(remote).to receive(:attach_wake).and_return(woke)

    connector.connect

    expect(err.string).to eq("#{Samagotchi::LaunchMode::RECAP_WAIT}\n")
    # 80 s left + the margin + the Bridge wait + the slack, over the transport's 75.
    expect(remote).to have_received(:attach_wake)
      .with("ab12", wait: Samagotchi::TerminalUI::AttachLauncher::BRIDGE_WAIT, read_timeout: 110.0)
  end

  it "names this TUI tui:PID@HOST, the short host name (P4-D6)" do
    expect(connector.client_id).to eq("tui:#{Process.pid}@mac")
  end

  it "fails in the words the wake failed with" do
    [Samagotchi::SessionManager::OwnedByTUI.new("ab12"),
     Samagotchi::SessionAccess::Refused.new(Samagotchi::LaunchMode::SCRATCH_LEFTOVER, code: "scratch"),
     Samagotchi::SessionAccess::RemoteFailed.new("remote studio (http://x): connection refused"),
     ArgumentError.new("Session not found: ab12")].each do |error|
      allow(remote).to receive(:attach_wake).and_raise(error)
      expect { connector.connect }.to raise_error(Samagotchi::TerminalUI::AttachLauncher::Error, error.message)
    end
  end
end
