# frozen_string_literal: true

require "tmpdir"
require "open3"
require "stringio"
require "samagotchi/session_manager"
require "samagotchi/terminal_ui/attach_launcher"

RSpec.describe Samagotchi::TerminalUI::AttachLauncher do
  let(:state_dir) { Dir.mktmpdir("attach-launcher") }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
      s.save(state_dir: state_dir)
    end
  end
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: session.id) }

  after { FileUtils.rm_rf(state_dir) }

  before do
    # An attached TUI is a client: it never owns the session or runs an Engine.
    expect(Samagotchi::OwnerLock).not_to receive(:acquire)
    expect(Samagotchi::Engine).not_to receive(:new)
  end

  def connect(**opts) = described_class.connect(state_dir: state_dir, wait: 0.2, **opts)

  describe "--attach ID" do
    it "connects to the live Bridge of the session's worker" do
      allow(Samagotchi::BridgeClient).to receive(:discover)
        .with(session.id, session_dir: Samagotchi::Session.session_dir(session.id, state_dir: state_dir)).and_return(client)

      expect(connect(attach: session.id)).to be(client)
    end

    it "wakes a worker when none is running (it idle-exited)" do
      allow(Samagotchi::BridgeClient).to receive(:discover).and_return(nil)
      allow(Samagotchi::SessionManager).to receive(:resume_session).and_return(session)
      allow(Samagotchi::BridgeClient).to receive(:wait_for).and_return(client)

      expect(connect(attach: session.id)).to be(client)
      expect(Samagotchi::SessionManager).to have_received(:resume_session).with(session.id, state_dir: state_dir)
    end

    it "refuses a session a chi REPL has open" do
      allow(Samagotchi::BridgeClient).to receive(:discover).and_return(nil)
      allow(Samagotchi::SessionManager).to receive(:resume_session)
        .and_raise(Samagotchi::SessionManager::OwnedByTUI, session.id)

      expect { connect(attach: session.id) }
        .to raise_error(described_class::Error, "session #{session.id} is open in a chi REPL; close it there first")
    end

    it "rejects an unknown session" do
      expect { connect(attach: "nope") }.to raise_error(described_class::Error, "Session not found: nope")
    end
  end

  describe "--shared" do
    it "starts a worker for a new session, with no prompt, and waits for its Bridge" do
      allow(Samagotchi::SessionManager).to receive(:spawn_session).and_return(session)
      allow(Samagotchi::BridgeClient).to receive(:wait_for).and_return(client)

      expect(connect(shared: true)).to be(client)
      expect(Samagotchi::SessionManager).to have_received(:spawn_session).with(prompt: nil, state_dir: state_dir)
      expect(Samagotchi::BridgeClient).to have_received(:wait_for)
        .with(session.id, session_dir: Samagotchi::Session.session_dir(session.id, state_dir: state_dir), timeout: 0.2)
    end

    it "resumes a session in a worker (or joins the one running it)" do
      allow(Samagotchi::SessionManager).to receive(:resume_session).and_return(session)
      allow(Samagotchi::BridgeClient).to receive(:wait_for).and_return(client)

      expect(connect(shared: true, resume: session.id)).to be(client)
      expect(Samagotchi::SessionManager).to have_received(:resume_session).with(session.id, state_dir: state_dir)
    end

    it "refuses a session a chi REPL has open" do
      allow(Samagotchi::SessionManager).to receive(:resume_session)
        .and_raise(Samagotchi::SessionManager::OwnedByTUI, session.id)

      expect { connect(shared: true, resume: session.id) }
        .to raise_error(described_class::Error, /open in a chi REPL; close it there first/)
    end

    it "gives up when the worker's Bridge doesn't come up" do
      allow(Samagotchi::SessionManager).to receive(:spawn_session).and_return(session)
      allow(Samagotchi::BridgeClient).to receive(:wait_for).and_return(nil)

      expect { connect(shared: true) }
        .to raise_error(described_class::Error, "the worker for session #{session.id} did not start its Bridge in time")
    end
  end
end

RSpec.describe Samagotchi::TerminalUI::AttachLauncher, ".open_surface" do
  let(:tty) { StringIO.new.tap { |io| io.define_singleton_method(:tty?) { true } } }

  before { allow(Reline).to receive(:ambiguous_width).and_return(1) }

  it "draws a live region on a terminal and gives everything back when it closes" do
    stderr = $stderr
    surface = described_class.open_surface(out: tty, input: tty, env: { "TERM" => "xterm" })
    expect(surface).to be_a(Samagotchi::TerminalUI::Screen)
    expect(Samagotchi::TerminalUI::RelineSeam.screen).to be(surface)

    described_class.close_surface(surface)

    expect(Samagotchi::TerminalUI::RelineSeam.screen).to be_nil
    expect($stderr).to be(stderr)
  end

  it "prints plainly when the terminal can't show a live region (see LiveRegion)" do
    surface = described_class.open_surface(out: tty, input: tty, env: { "TERM" => "dumb" })

    expect(surface).to be_a(Samagotchi::TerminalUI::PlainSurface)
    expect(Samagotchi::TerminalUI::RelineSeam.screen).to be_nil
  end
end

RSpec.describe "bin/chi --attach / --shared flags" do
  let(:chi) { File.expand_path("../../bin/chi", __dir__) }

  {
    %w[--attach s1 -p hi] => "--attach/--shared can't be combined with --prompt",
    %w[--shared --non-interactive] => "--attach/--shared can't be combined with --non-interactive",
    %w[--shared --model m] => "--attach/--shared can't be combined with --model",
    %w[--attach s1 --shared] => "use either --attach ID or --shared",
    %w[--attach s1 --resume s1] => "--attach takes the session id; --resume goes with --shared"
  }.each do |args, message|
    it "rejects #{args.join(" ")}" do
      _out, err, status = Open3.capture3(RbConfig.ruby, chi, *args, stdin_data: "")

      expect(status.exitstatus).to eq(1)
      expect(err).to include(message)
    end
  end

  it "keeps rejecting explicit conflicts with session.shared on" do
    _out, err, status = Open3.capture3({ "SAMAGOTCHI_SESSION_SHARED" => "1" }, RbConfig.ruby, chi, "--shared", "--model", "m", stdin_data: "")

    expect(status.exitstatus).to eq(1)
    expect(err).to include("--attach/--shared can't be combined with --model")
    expect(err).not_to include("session.shared:")
  end
end
