# frozen_string_literal: true

require "tmpdir"
require "open3"
require "stringio"
require "samagotchi/terminal_ui"
require "samagotchi/session_manager"
require "samagotchi/terminal_ui/attach_launcher"
require_relative "../support/worker_links"

RSpec.describe Samagotchi::TerminalUI::AttachLauncher do
  include WorkerLinks

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
      allow(Samagotchi::WorkerLink).to receive(:resolve)
        .with(Samagotchi::Session.session_dir(session.id, state_dir: state_dir), unlink: true, owner: nil)
        .and_return(live_link(client: client))

      expect(connect(attach: session.id)).to be(client)
    end

    it "wakes a worker when none is running (it idle-exited)" do
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(none_link)
      allow(Samagotchi::SessionManager).to receive(:resume_session).and_return(session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(live_link(client: client))

      expect(connect(attach: session.id)).to be(client)
      expect(Samagotchi::SessionManager).to have_received(:resume_session).with(session.id, state_dir: state_dir)
    end

    it "wakes a worker for the stale files a kill -9 left (a sidecar, a free lock), and removes the sidecar" do
      dir = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)
      Samagotchi::WorkerSidecar.new(port: 5001, pid: Process.pid + 1, session_id: session.id).write(dir)
      allow(Samagotchi::SessionManager).to receive(:resume_session).and_return(session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(live_link(client: client))

      expect(connect(attach: session.id)).to be(client)
      expect(Samagotchi::SessionManager).to have_received(:resume_session).with(session.id, state_dir: state_dir)
      expect(File.exist?(Samagotchi::WorkerSidecar.path(dir))).to be(false)
    end

    it "refuses a worker of a newer protocol instead of waking another" do
      skew = Samagotchi::WorkerLink::Skew.new(sidecar: Samagotchi::WorkerSidecar.new(port: 1, protocol: 99), owner: nil, reason: :protocol)
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(skew)
      allow(Samagotchi::SessionManager).to receive(:resume_session)

      expect { connect(attach: session.id) }.to raise_error(described_class::Error, /newer than this chi/)
      expect(Samagotchi::SessionManager).not_to have_received(:resume_session)
    end

    it "waits for a worker still leaving (its recap on leave), saying so once, then resumes" do
      err = StringIO.new
      calls = []
      owner = Samagotchi::OwnerLock::Owner.new(pid: 1, kind: "worker", leaving_at: Time.now.iso8601, leave_wait: 30.0)
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(none_link)
      allow(Samagotchi::OwnerLock).to receive(:await_release) do |dir, on_wait:|
        calls << [:await, dir]
        on_wait.call(owner)
        :released
      end
      allow(Samagotchi::SessionManager).to receive(:resume_session) { (calls << [:resume]) && session }
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(live_link(client: client))

      expect(connect(attach: session.id, err: err)).to be(client)
      expect(calls).to eq([[:await, Samagotchi::Session.session_dir(session.id, state_dir: state_dir)], [:resume]])
      expect(err.string).to eq("#{Samagotchi::LaunchMode::RECAP_WAIT}\n")
    end

    it "says nothing when no worker is leaving (--resume ID too)" do
      err = StringIO.new
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(none_link)
      allow(Samagotchi::SessionManager).to receive(:resume_session).and_return(session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(live_link(client: client))
      allow(Samagotchi::OwnerLock).to receive(:await_release).and_call_original

      expect(connect(attach: session.id, err: err)).to be(client)
      expect(connect(resume: session.id, err: err)).to be(client)
      expect(Samagotchi::OwnerLock).to have_received(:await_release).twice
      expect(err.string).to eq("")
    end

    it "refuses a session a one-turn chi run has open" do
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(none_link)
      allow(Samagotchi::SessionManager).to receive(:resume_session)
        .and_raise(Samagotchi::SessionManager::OwnedByTUI, session.id)

      expect { connect(attach: session.id) }
        .to raise_error(described_class::Error, "session #{session.id} is in use by a one-turn chi --non-interactive run or an older chi's terminal; let it finish first")
    end

    it "rejects an unknown session" do
      expect { connect(attach: "nope") }.to raise_error(described_class::Error, "no session nope")
    end
  end

  describe "a new session (plain chi)" do
    it "starts a worker for a new session, with no prompt, and waits for its Bridge" do
      allow(Samagotchi::SessionManager).to receive(:spawn_session).and_return(session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(live_link(client: client))

      expect(connect).to be(client)
      expect(Samagotchi::SessionManager).to have_received(:spawn_session)
        .with(prompt: nil, model_name: nil, state_dir: state_dir, setup: Samagotchi::SessionSetup.new,
              scratch: false, client_id: nil)
      expect(Samagotchi::WorkerLink).to have_received(:await)
        .with(session.id, session_dir: Samagotchi::Session.session_dir(session.id, state_dir: state_dir), timeout: 0.2)
    end

    it "starts a new session on --model as typed (spawn_session stores its alias resolved)" do
      allow(Samagotchi::SessionManager).to receive(:spawn_session).and_return(session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(live_link(client: client))

      connect(model: "fast")

      expect(Samagotchi::SessionManager).to have_received(:spawn_session)
        .with(prompt: nil, model_name: "fast", state_dir: state_dir,
              setup: Samagotchi::SessionSetup.new, scratch: false, client_id: nil)
    end

    it "starts a new session with its own --llm-context values" do
      allow(Samagotchi::SessionManager).to receive(:spawn_session).and_return(session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(live_link(client: client))

      connect(llm_context: { strategy: "none", budget_tokens: "off" })

      expect(Samagotchi::SessionManager).to have_received(:spawn_session)
        .with(hash_including(setup: Samagotchi::SessionSetup.new(llm_context: Samagotchi::LLMContextOverride.new(strategy: [], budget_tokens: 0))))
    end

    it "starts a new session with its --memory and --mute lists" do
      allow(Samagotchi::SessionManager).to receive(:spawn_session).and_return(session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(live_link(client: client))

      expect { connect(memories: ["cli_usage"], muted_memories: ["gh-helper"]) }.not_to output.to_stderr
      expect(Samagotchi::SessionManager).to have_received(:spawn_session)
        .with(prompt: nil, model_name: nil, state_dir: state_dir,
              setup: Samagotchi::SessionSetup.new(preloaded_memory_names: ["cli_usage"],
                                                  muted_memory_names: ["gh-helper"]),
              scratch: false, client_id: nil)
    end

    it "starts a new session with --append-system-prompt's files in its setup" do
      allow(Samagotchi::SessionManager).to receive(:spawn_session).and_return(session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(live_link(client: client))

      connect(appended_prompt_files: ["/r/a.md"])
      expect(Samagotchi::SessionManager).to have_received(:spawn_session)
        .with(hash_including(setup: Samagotchi::SessionSetup.new(appended_prompt_files: ["/r/a.md"])))
    end

    it "starts a new session on its --toolkit, and ignores it for an existing one with a line" do
      allow(Samagotchi::SessionManager).to receive(:spawn_session).and_return(session)
      allow(Samagotchi::SessionManager).to receive(:resume_session).and_return(session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(live_link(client: client))
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(live_link(client: client))
      toolkit = Samagotchi::Toolkit.new(name: "lean", add: ["delegate"])
      err = StringIO.new

      connect(toolkit: toolkit, toolkit_flags: %w[--toolkit --tool])
      connect(attach: session.id, toolkit: toolkit, toolkit_flags: %w[--toolkit --tool], err: err)
      connect(attach: session.id, toolkit: toolkit, toolkit_flags: %w[--no-tool], err: err)

      expect(Samagotchi::SessionManager).to have_received(:spawn_session)
        .with(hash_including(setup: have_attributes(toolkit: toolkit, toolkit_origin: "chosen"))).once
      expect(err.string).to eq("(--toolkit and --tool apply to a new session; #{session.id} keeps its own)\n" \
                               "(--no-tool applies to a new session; #{session.id} keeps its own)\n")
    end

    it "starts a new session with its --parent-answers, and ignores it for an existing one with a line (never sent as a command)" do
      allow(Samagotchi::SessionManager).to receive(:spawn_session).and_return(session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(live_link(client: client))
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(live_link(client: client))
      err = StringIO.new

      connect(parent_answers: "standard")
      connect(attach: session.id, parent_answers: "standard", toolkit_flags: %w[--parent-answers], err: err)

      expect(Samagotchi::SessionManager).to have_received(:spawn_session)
        .with(hash_including(setup: Samagotchi::SessionSetup.new(parent_answers: "standard"))).once
      expect(err.string).to eq("(--parent-answers applies to a new session; #{session.id} keeps its own)\n")
    end

    it "starts a new session with its --set bundle settings, and ignores them for an existing one with a line" do
      allow(Samagotchi::SessionManager).to receive(:spawn_session).and_return(session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(live_link(client: client))
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(live_link(client: client))
      settings = Samagotchi::SessionConfig::Settings.new(bundles: { "cost-cap" => { "cap" => 3 } })
      err = StringIO.new

      connect(settings: settings)
      connect(attach: session.id, settings: settings, toolkit_flags: %w[--set], err: err)

      expect(Samagotchi::SessionManager).to have_received(:spawn_session)
        .with(hash_including(setup: Samagotchi::SessionSetup.new(settings: settings))).once
      expect(err.string).to eq("(--set applies to a new session; #{session.id} keeps its own)\n")
    end

    it "ignores --append-system-prompt for an existing session, with --memory and --mute's line" do
      allow(Samagotchi::SessionManager).to receive(:resume_session).and_return(session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(live_link(client: client))
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(live_link(client: client))
      err = StringIO.new

      connect(attach: session.id, appended_prompt_files: ["/r/a.md"], err: err)
      connect(attach: session.id, memories: ["a"], muted_memories: ["b"], appended_prompt_files: ["/r/a.md"], err: err)

      expect(err.string).to eq(
        "(--append-system-prompt applies to a new session; #{session.id} keeps its own)\n" \
        "(--memory, --mute and --append-system-prompt apply to a new session; #{session.id} keeps its own)\n"
      )
    end

    it "ignores --memory/--mute for an existing session, saying so, and goes on" do
      allow(Samagotchi::SessionManager).to receive(:resume_session).and_return(session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(live_link(client: client))
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(live_link(client: client))
      err = StringIO.new

      expect(connect(resume: session.id, muted_memories: ["gh-helper"], err: err)).to be(client)
      expect(connect(attach: session.id, memories: ["a"], muted_memories: ["b"], err: err)).to be(client)
      expect(connect(attach: session.id, err: err)).to be(client)

      expect(err.string).to eq(
        "(--mute applies to a new session; #{session.id} keeps its own)\n" \
        "(--memory and --mute apply to a new session; #{session.id} keeps its own)\n"
      )
      expect(Samagotchi::SessionManager).to have_received(:resume_session).with(session.id, state_dir: state_dir)
      expect(Samagotchi::Session.load(session.id, state_dir: state_dir).muted_memory_names).to eq([])
    end

    it "resumes a session in a worker (or joins the one running it)" do
      allow(Samagotchi::SessionManager).to receive(:resume_session).and_return(session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(live_link(client: client))

      expect(connect(resume: session.id)).to be(client)
      expect(Samagotchi::SessionManager).to have_received(:resume_session).with(session.id, state_dir: state_dir)
    end

    it "refuses a session a one-turn chi run has open" do
      allow(Samagotchi::SessionManager).to receive(:resume_session)
        .and_raise(Samagotchi::SessionManager::OwnedByTUI, session.id)

      expect { connect(resume: session.id) }
        .to raise_error(described_class::Error, /in use by a one-turn chi --non-interactive run or an older chi's terminal; let it finish first/)
    end

    it "starts a chi scratch session's worker on a scratch session" do
      allow(Samagotchi::SessionManager).to receive(:spawn_session).and_return(session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(live_link(client: client))

      expect(connect(scratch: true)).to be(client)
      expect(Samagotchi::SessionManager).to have_received(:spawn_session).with(hash_including(scratch: true))
    end

    it "deletes a scratch session whose worker's Bridge never came" do
      session.scratch = true
      allow(Samagotchi::SessionManager).to receive(:spawn_session).and_return(session)
      allow(Samagotchi::SessionManager).to receive(:delete_session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(none_link)

      expect { connect(scratch: true) }.to raise_error(described_class::Error, /did not start its Bridge/)
      expect(Samagotchi::SessionManager).to have_received(:delete_session)
        .with(session.id, state_dir: state_dir, stop: true, wait: Samagotchi::TerminalUI::LocalLink::DELETE_WAIT)
    end

    it "gives up when the worker's Bridge doesn't come up" do
      allow(Samagotchi::SessionManager).to receive(:spawn_session).and_return(session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(none_link)

      expect { connect }
        .to raise_error(described_class::Error, "the worker for session #{session.id} did not start its Bridge in time (chi home doctor shows a worker that failed to boot)")
    end
  end
end

RSpec.describe Samagotchi::TerminalUI::AttachLauncher, ".run" do
  it "hands -p to the attached loop as its first prompt" do
    allow($stdin).to receive(:tty?).and_return(true)
    allow(Samagotchi::Guardrails::ParentApprovals).to receive(:parent_process?).and_return(false)
    client = instance_double(Samagotchi::BridgeClient)
    surface = instance_double(Samagotchi::TerminalUI::PlainSurface)
    attached = instance_double(Samagotchi::TerminalUI::AttachedLoop, run: :detached)
    allow(described_class).to receive(:connect)
      .with(attach: nil, resume: nil, model: nil, memories: [], muted_memories: [], llm_context: {}, thinking: nil, appended_prompt_files: [], toolkit: nil, toolkit_flags: [], settings: nil, parent_answers: nil,
            scratch: false, state_dir: Samagotchi::Session.default_state_dir)
      .and_return(client)
    allow(described_class).to receive(:open_surface).and_return(surface)
    allow(described_class).to receive(:close_surface)
    allow(Samagotchi::TerminalUI::AttachedLoop).to receive(:new).and_return(attached)

    expect(described_class.run(prompt: "hi")).to eq(:detached)

    expect(Samagotchi::TerminalUI::AttachedLoop).to have_received(:new)
      .with(client: client, screen: surface, client_id: "tui:#{Process.pid}", first_prompt: "hi",
            first_command: nil, no_interrupt: false, default_input: false, wait_at_eof: false,
            scratch: false, as_parent: false, state_dir: Samagotchi::Session.default_state_dir)
    expect(described_class).to have_received(:close_surface).with(surface)
  end

  describe "-v" do
    let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-verbose") }
    let(:tail) { instance_double(Samagotchi::TerminalUI::LogTail, stop: nil) }

    before do
      allow(described_class).to receive_messages(connect: client, open_surface: nil, close_surface: nil)
      allow(Samagotchi::TerminalUI::AttachedLoop).to receive(:new)
        .and_return(instance_double(Samagotchi::TerminalUI::AttachedLoop, run: :detached))
      allow(Samagotchi::Log).to receive(:path).and_return("/tmp/chi.log")
      allow(Samagotchi::TerminalUI::LogTail).to receive(:new).and_return(tail)
      allow(tail).to receive(:start).and_return(tail)
    end

    it "follows the session's records in the debug log while attached, and stops with the loop" do
      described_class.run(verbose: true)

      expect(Samagotchi::TerminalUI::LogTail).to have_received(:new).with(hash_including(path: "/tmp/chi.log", session_id: "s-verbose"))
      expect(tail).to have_received(:stop)
    end

    it "says a worker running before this launch keeps its own level, once, and nothing for a new one" do
      allow(described_class).to receive(:worker_running?).and_return(true, false)

      expect { described_class.run(attach: "s-verbose", verbose: true) }
        .to output("#{format(described_class::VERBOSE_RUNNING, "/tmp/chi.log")}\n").to_stderr
      expect { described_class.run(verbose: true) }.not_to output.to_stderr
    end

    it "follows nothing without it" do
      described_class.run

      expect(Samagotchi::TerminalUI::LogTail).not_to have_received(:new)
    end
  end

  describe "chi scratch" do
    let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-scratch") }
    let(:out) { StringIO.new }

    before do
      allow($stdout).to receive(:puts) { |line| out.puts(line) }
      allow(described_class).to receive_messages(connect: client, open_surface: nil, close_surface: nil)
      allow(Samagotchi::SessionManager).to receive(:delete_session)
    end

    def loop_ending(&run)
      attached = instance_double(Samagotchi::TerminalUI::AttachedLoop)
      allow(attached).to receive(:run, &run)
      allow(Samagotchi::TerminalUI::AttachedLoop).to receive(:new).and_return(attached)
    end

    it "says what it is, tells the loop, then stops and deletes the session as it ends, saying so" do
      loop_ending { :detached }

      expect(described_class.run(scratch: true)).to eq(:detached)

      expect(Samagotchi::TerminalUI::AttachedLoop).to have_received(:new).with(hash_including(scratch: true))
      expect(Samagotchi::SessionManager).to have_received(:delete_session)
        .with("s-scratch", state_dir: Samagotchi::Session.default_state_dir, stop: true,
                           wait: Samagotchi::TerminalUI::LocalLink::DELETE_WAIT)
      expect(out.string).to eq("#{described_class::SCRATCH_BANNER}\n#{described_class::SCRATCH_DELETED}\n")
    end

    it "deletes it when the loop ends on an error (or Ctrl-C) too, quietly" do
      loop_ending { raise Interrupt }

      expect { described_class.run(scratch: true) }.to raise_error(Interrupt)
      expect(Samagotchi::SessionManager).to have_received(:delete_session).once
      expect(out.string).not_to include(described_class::SCRATCH_DELETED)
    end

    it "takes a session its worker deleted first as deleted" do
      loop_ending { :closed }
      allow(Samagotchi::SessionManager).to receive(:delete_session).and_raise(ArgumentError, "no session s-scratch")

      described_class.run(scratch: true)

      expect(out.string).to end_with("#{described_class::SCRATCH_DELETED}\n")
    end
  end

  it "tells the attached loop when a parent agent drives it (piped stdin, an agent marker)" do
    allow(Samagotchi::Guardrails::ParentApprovals).to receive(:parent_process?).and_return(true)
    attached = instance_double(Samagotchi::TerminalUI::AttachedLoop, run: :detached)
    allow(described_class).to receive(:connect).and_return(instance_double(Samagotchi::BridgeClient))
    allow(described_class).to receive(:open_surface).and_return(instance_double(Samagotchi::TerminalUI::PlainSurface))
    allow(described_class).to receive(:close_surface)
    allow(Samagotchi::TerminalUI::AttachedLoop).to receive(:new).and_return(attached)

    described_class.run(attach: "s1")

    expect(Samagotchi::TerminalUI::AttachedLoop).to have_received(:new).with(hash_including(as_parent: true))
  end

  it "has the loop wait for the -p turn when the input is a pipe" do
    allow($stdin).to receive(:tty?).and_return(false)
    attached = instance_double(Samagotchi::TerminalUI::AttachedLoop, run: :turn_failed)
    allow(described_class).to receive_messages(connect: instance_double(Samagotchi::BridgeClient),
                                               open_surface: instance_double(Samagotchi::TerminalUI::PlainSurface),
                                               close_surface: nil)
    allow(Samagotchi::TerminalUI::AttachedLoop).to receive(:new).and_return(attached)

    expect(described_class.run(prompt: "hi")).to eq(:turn_failed)
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

    described_class.run(resume: "s1", prompt: "hi", model: "qwen_moe", no_interrupt: true)
    described_class.run(attach: "s2", model: "qwen_moe")
    described_class.run(model: "qwen_moe")

    expect(loops).to eq([
      { first_prompt: "hi", first_command: "/model qwen_moe --yes", no_interrupt: true },
      { first_prompt: nil, first_command: "/model qwen_moe --yes", no_interrupt: false },
      # A new session starts on the model instead (see .connect).
      { first_prompt: nil, first_command: nil, no_interrupt: false }
    ])
    # Only a new session with no -p gets the default input.
    expect(default_inputs).to eq([false, false, true])
    expect(described_class).to have_received(:connect)
      .with(attach: nil, resume: nil, model: "qwen_moe", memories: [], muted_memories: [], llm_context: {}, thinking: nil, appended_prompt_files: [], toolkit: nil, toolkit_flags: [], settings: nil, parent_answers: nil,
            scratch: false, state_dir: Samagotchi::Session.default_state_dir)
  end

  it "sets a resumed or attached session's --llm-context through its worker, after the --model; a new one starts with it" do
    client = instance_double(Samagotchi::BridgeClient)
    attached = instance_double(Samagotchi::TerminalUI::AttachedLoop, run: :detached)
    allow(described_class).to receive_messages(connect: client, open_surface: nil, close_surface: nil)
    commands = []
    allow(Samagotchi::TerminalUI::AttachedLoop).to receive(:new).and_wrap_original do |_original, **kwargs|
      commands << kwargs[:first_command]
      attached
    end
    words = { strategy: "stale forget", budget_tokens: "64k" }

    described_class.run(resume: "s1", model: "qwen_moe", llm_context: words)
    described_class.run(attach: "s2", llm_context: { apply: "turn_end" })
    described_class.run(llm_context: words)

    expect(commands).to eq([["/model qwen_moe --yes", "/llm-context strategy stale,forget budget 64k --yes"],
                            "/llm-context apply turn_end --yes", nil])
    expect(described_class).to have_received(:connect)
      .with(attach: nil, resume: nil, model: nil, memories: [], muted_memories: [], llm_context: words, thinking: nil, appended_prompt_files: [], toolkit: nil, toolkit_flags: [], settings: nil, parent_answers: nil,
            scratch: false, state_dir: Samagotchi::Session.default_state_dir)
  end
end

RSpec.describe Samagotchi::TerminalUI::AttachLauncher, "--thinking" do
  include WorkerLinks

  it "sets a resumed or attached session's level through its worker, after the others; a new one starts with it" do
    client = instance_double(Samagotchi::BridgeClient)
    attached = instance_double(Samagotchi::TerminalUI::AttachedLoop, run: :detached)
    allow(described_class).to receive_messages(connect: client, open_surface: nil, close_surface: nil)
    commands = []
    allow(Samagotchi::TerminalUI::AttachedLoop).to receive(:new).and_wrap_original do |_original, **kwargs|
      commands << kwargs[:first_command]
      attached
    end

    described_class.run(resume: "s1", model: "qwen_moe", llm_context: { apply: "turn_end" }, thinking: "low")
    described_class.run(attach: "s2", thinking: "default")
    described_class.run(thinking: "high")

    # --yes: the flag is the user's choice, so a costly change doesn't ask (and the launch doesn't wait on it).
    expect(commands).to eq([["/model qwen_moe --yes", "/llm-context apply turn_end --yes", "/thinking low --yes"], "/thinking default --yes", nil])
    expect(described_class).to have_received(:connect)
      .with(attach: nil, resume: nil, model: nil, memories: [], muted_memories: [], llm_context: {}, thinking: "high", appended_prompt_files: [], toolkit: nil, toolkit_flags: [], settings: nil, parent_answers: nil,
            scratch: false, state_dir: Samagotchi::Session.default_state_dir)
  end

  it "spawns a new session with the level as its own" do
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd)
    allow(Samagotchi::SessionManager).to receive(:spawn_session).and_return(session)
    allow(Samagotchi::WorkerLink).to receive(:await).and_return(live_link(client: instance_double(Samagotchi::BridgeClient)))

    described_class.connect(thinking: "low", state_dir: Dir.pwd, wait: 0.1)

    expect(Samagotchi::SessionManager).to have_received(:spawn_session)
      .with(hash_including(setup: Samagotchi::SessionSetup.new(thinking: :low)))
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

RSpec.describe "bin/chi --attach flags" do
  let(:chi) { File.expand_path("../../bin/chi", __dir__) }

  {
    %w[--attach s1 -p hi --non-interactive] => "--attach can't be combined with --non-interactive",
    %w[--attach s1 --resume s1] => "use either --attach ID or --resume ID"
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
    expect(err).to include("(--memory and --mute apply to a new session; s1 keeps its own)")
    expect(err).not_to include("can't be combined")
    # The attach itself: s1 is no session here.
    expect(status.exitstatus).to eq(1)
    expect(err).to include("no session s1")
  end
end

# bin/chi exits with this after an attached run: a script (or a parent
# agent) tells a question left waiting from a failed turn.
RSpec.describe Samagotchi::TerminalUI::AttachLauncher, ".exit_status" do
  it "is 0 detached, 3 for a question left waiting (input from a pipe), 1 otherwise" do
    expect(described_class.exit_status(:detached)).to eq(0)
    expect(described_class.exit_status(:unanswered)).to eq(3)
    %i[closed failed turn_failed empty_answer].each { |ended| expect(described_class.exit_status(ended)).to eq(1) }
  end
end

# Attached `chi -p` from a script whose turn ended with no answer: exit 1
# and one line on stderr, as the in-process `chi -p --non-interactive`.
RSpec.describe Samagotchi::TerminalUI::AttachLauncher, ".report_ended" do
  it "says when an answer was empty or a prompt was removed, and nothing for other endings" do
    err = StringIO.new
    described_class.report_ended(:empty_answer, err: err)
    described_class.report_ended(:removed, err: err)
    described_class.report_ended(:detached, err: err)

    expect(err.string).to eq("chi: the model gave an empty answer\nchi: the prompt was removed before it ran\n")
  end
end

# Attached `chi -p` from a script, exit 3: the question in full on stderr,
# as `chi send --wait` prints it, so a parent agent can answer it.
RSpec.describe Samagotchi::TerminalUI::AttachLauncher, ".report_unanswered" do
  it "prints the question, its options and the chi answer command" do
    err = StringIO.new
    described_class.report_unanswered({ id: "q1", question: "Which file?", options: %w[A B] }, session_id: "s-1", err: err)

    expect(err.string).to eq(<<~TEXT)
      chi: waiting for an answer (question): Which file?
          1. A
          2. B
        answer: chi answer s-1 --question q1 --option N
        or open it: chi --attach s-1 or the web
    TEXT
  end
end
