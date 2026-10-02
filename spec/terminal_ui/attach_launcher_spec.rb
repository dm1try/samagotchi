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
      expect(Samagotchi::SessionManager).to have_received(:spawn_session)
        .with(prompt: nil, model_name: nil, state_dir: state_dir, memories: [], muted_memories: [])
      expect(Samagotchi::BridgeClient).to have_received(:wait_for)
        .with(session.id, session_dir: Samagotchi::Session.session_dir(session.id, state_dir: state_dir), timeout: 0.2)
    end

    it "starts a new session on --model as typed (spawn_session stores its alias resolved)" do
      allow(Samagotchi::SessionManager).to receive(:spawn_session).and_return(session)
      allow(Samagotchi::BridgeClient).to receive(:wait_for).and_return(client)

      connect(shared: true, model: "fast")

      expect(Samagotchi::SessionManager).to have_received(:spawn_session)
        .with(prompt: nil, model_name: "fast", state_dir: state_dir,
              memories: [], muted_memories: [])
    end

    it "starts a new session with its --memory and --mute lists" do
      allow(Samagotchi::SessionManager).to receive(:spawn_session).and_return(session)
      allow(Samagotchi::BridgeClient).to receive(:wait_for).and_return(client)

      expect { connect(shared: true, memories: ["cli_usage"], muted_memories: ["gh-helper"]) }.not_to output.to_stderr
      expect(Samagotchi::SessionManager).to have_received(:spawn_session)
        .with(prompt: nil, model_name: nil, state_dir: state_dir, memories: ["cli_usage"], muted_memories: ["gh-helper"])
    end

    it "ignores --memory/--mute for an existing session, saying so, and goes on" do
      allow(Samagotchi::SessionManager).to receive(:resume_session).and_return(session)
      allow(Samagotchi::BridgeClient).to receive(:wait_for).and_return(client)
      allow(Samagotchi::BridgeClient).to receive(:discover).and_return(client)
      err = StringIO.new

      expect(connect(shared: true, resume: session.id, muted_memories: ["gh-helper"], err: err)).to be(client)
      expect(connect(attach: session.id, memories: ["a"], muted_memories: ["b"], err: err)).to be(client)
      expect(connect(attach: session.id, err: err)).to be(client)

      expect(err.string).to eq(
        "(--mute applies to a new session; #{session.id}'s prompt is already built)\n" \
        "(--memory and --mute apply to a new session; #{session.id}'s prompt is already built)\n"
      )
      expect(Samagotchi::SessionManager).to have_received(:resume_session).with(session.id, state_dir: state_dir)
      expect(Samagotchi::Session.load(session.id, state_dir: state_dir).muted_memory_names).to eq([])
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

RSpec.describe Samagotchi::TerminalUI::AttachLauncher, ".run" do
  it "hands -p to the attached loop as its first prompt" do
    allow($stdin).to receive(:tty?).and_return(true)
    client = instance_double(Samagotchi::BridgeClient)
    surface = instance_double(Samagotchi::TerminalUI::PlainSurface)
    attached = instance_double(Samagotchi::TerminalUI::AttachedLoop, run: :detached)
    allow(described_class).to receive(:connect)
      .with(attach: nil, shared: true, resume: nil, model: nil, memories: [], muted_memories: []).and_return(client)
    allow(described_class).to receive(:open_surface).and_return(surface)
    allow(described_class).to receive(:close_surface)
    allow(Samagotchi::TerminalUI::AttachedLoop).to receive(:new).and_return(attached)

    expect(described_class.run(shared: true, prompt: "hi")).to eq(:detached)

    expect(Samagotchi::TerminalUI::AttachedLoop).to have_received(:new)
      .with(client: client, screen: surface, client_id: "tui:#{Process.pid}", first_prompt: "hi",
            first_command: nil, no_interrupt: false, default_input: false, wait_at_eof: false)
    expect(described_class).to have_received(:close_surface).with(surface)
  end

  it "has the loop wait for the -p turn when the input is a pipe" do
    allow($stdin).to receive(:tty?).and_return(false)
    attached = instance_double(Samagotchi::TerminalUI::AttachedLoop, run: :turn_failed)
    allow(described_class).to receive_messages(connect: instance_double(Samagotchi::BridgeClient),
                                               open_surface: instance_double(Samagotchi::TerminalUI::PlainSurface),
                                               close_surface: nil)
    allow(Samagotchi::TerminalUI::AttachedLoop).to receive(:new).and_return(attached)

    expect(described_class.run(shared: true, prompt: "hi")).to eq(:turn_failed)
    expect(Samagotchi::TerminalUI::AttachedLoop).to have_received(:new).with(hash_including(wait_at_eof: true))
  end

  it "switches a resumed or attached session's worker to --model before the first prompt, and passes --no-interrupt" do
    client = instance_double(Samagotchi::BridgeClient)
    surface = instance_double(Samagotchi::TerminalUI::PlainSurface)
    attached = instance_double(Samagotchi::TerminalUI::AttachedLoop, run: :detached)
    allow(described_class).to receive(:connect).and_return(client)
    allow(described_class).to receive_messages(open_surface: surface, close_surface: nil)
    loops = []
    default_inputs = []
    allow(Samagotchi::TerminalUI::AttachedLoop).to receive(:new).and_wrap_original do |_original, **kwargs|
      loops << kwargs.slice(:first_prompt, :first_command, :no_interrupt)
      default_inputs << kwargs[:default_input]
      attached
    end

    described_class.run(shared: true, resume: "s1", prompt: "hi", model: "qwen_moe", no_interrupt: true)
    described_class.run(attach: "s2", model: "qwen_moe")
    described_class.run(shared: true, model: "qwen_moe")

    expect(loops).to eq([
      { first_prompt: "hi", first_command: "/model qwen_moe", no_interrupt: true },
      { first_prompt: nil, first_command: "/model qwen_moe", no_interrupt: false },
      # A new session starts on the model instead (see .connect).
      { first_prompt: nil, first_command: nil, no_interrupt: false }
    ])
    # Only a new session with no -p gets the default input.
    expect(default_inputs).to eq([false, false, true])
    expect(described_class).to have_received(:connect)
      .with(attach: nil, shared: true, resume: nil, model: "qwen_moe", memories: [], muted_memories: [])
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
    %w[--attach s1 -p hi --non-interactive] => "--attach/--shared can't be combined with --non-interactive",
    %w[--shared --non-interactive] => "--attach/--shared can't be combined with --non-interactive",
    %w[--shared -v] => "--attach/--shared can't be combined with --verbose",
    %w[--attach s1 --shared] => "use either --attach ID or --shared",
    %w[--attach s1 --resume s1] => "--attach takes the session id; --resume goes with --shared"
  }.each do |args, message|
    it "rejects #{args.join(" ")}" do
      _out, err, status = Open3.capture3(RbConfig.ruby, chi, *args, stdin_data: "")

      expect(status.exitstatus).to eq(1)
      expect(err).to include(message)
    end
  end

  it "warns about --memory/--mute for an existing session and goes on to attach" do
    _out, err, status = Open3.capture3(RbConfig.ruby, chi, "--attach", "s1", "--memory", "notes", "--mute", "identity", stdin_data: "")

    expect(err).to include("Warning: --memory 'notes' not found")
    expect(err).to include("(--memory and --mute apply to a new session; s1's prompt is already built)")
    expect(err).not_to include("can't be combined")
    # The attach itself: s1 is no session here.
    expect(status.exitstatus).to eq(1)
    expect(err).to include("Session not found: s1")
  end

  it "keeps rejecting explicit conflicts with session.shared on" do
    _out, err, status = Open3.capture3({ "SAMAGOTCHI_SESSION_SHARED" => "1" }, RbConfig.ruby, chi, "--shared", "-v", stdin_data: "")

    expect(status.exitstatus).to eq(1)
    expect(err).to include("--attach/--shared can't be combined with --verbose")
    expect(err).not_to include("session.shared:")
  end
end

# bin/chi exits with this after an attached run: a script (or a parent
# agent) tells a question left waiting from a failed turn.
RSpec.describe Samagotchi::TerminalUI::AttachLauncher, ".exit_status" do
  it "is 0 detached, 3 for a question left waiting (input from a pipe), 1 otherwise" do
    expect(described_class.exit_status(:detached)).to eq(0)
    expect(described_class.exit_status(:unanswered)).to eq(3)
    %i[closed failed turn_failed].each { |ended| expect(described_class.exit_status(ended)).to eq(1) }
  end
end
