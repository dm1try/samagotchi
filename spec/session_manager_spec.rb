
# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/session_manager"
require "samagotchi/reminder_store"

RSpec.describe Samagotchi::SessionManager do
  let(:tmpdir) { Dir.mktmpdir("session-manager-spec") }

  after { FileUtils.rm_rf(tmpdir) }

  describe ".list_sessions" do
    it "returns all sessions" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)

      sessions = described_class.list_sessions(state_dir: tmpdir)
      expect(sessions.length).to eq(1)
      expect(sessions.first.status).to eq(Samagotchi::Session::STATUS_IDLE)
    end
  end

  describe ".stop_session" do
    it "marks a session as stopped even when pid file does not exist" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)

      described_class.stop_session(session.id, state_dir: tmpdir)
      loaded = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      expect(loaded.status).to eq(Samagotchi::Session::STATUS_STOPPED)
    end

    context "with wait:" do
      let(:session) do
        Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
          s.save(state_dir: tmpdir)
        end
      end
      let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }

      # A stand-in worker: another process holding the owner lock.
      def spawn_owner(ignore_term: false)
        lib = File.expand_path("../lib", __dir__)
        script = <<~RUBY
          require "samagotchi/owner_lock"
          trap("TERM") {} if #{ignore_term}
          lock = Samagotchi::OwnerLock.acquire(ARGV[0], kind: "worker")
          sleep 30
        RUBY
        @owner_pid = Process.spawn(RbConfig.ruby, "-I", lib, "-e", script, session_dir)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        until described_class.session_owner(session.id, state_dir: tmpdir)
          raise "owner never took the lock" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 0.02
        end
      end

      after do
        if @owner_pid
          begin
            Process.kill("KILL", @owner_pid)
          rescue Errno::ESRCH
            nil
          end
          begin
            Process.wait(@owner_pid)
          rescue Errno::ECHILD
            nil
          end
        end
      end

      it "returns true once the owner has let go of the session" do
        spawn_owner

        expect(described_class.stop_session(session.id, state_dir: tmpdir, wait: 5)).to be true
        expect(described_class.session_owner(session.id, state_dir: tmpdir)).to be_nil
      end

      it "returns false when the owner outlives the wait" do
        spawn_owner(ignore_term: true)

        expect(described_class.stop_session(session.id, state_dir: tmpdir, wait: 0.3)).to be false
        expect(described_class.session_owner(session.id, state_dir: tmpdir)).not_to be_nil
      end

      it "returns true at once when nothing owns the session" do
        expect(described_class.stop_session(session.id, state_dir: tmpdir, wait: 5)).to be true
      end
    end
  end

  describe ".wait_for_session" do
    it "returns true when session is already completed" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.status = Samagotchi::Session::STATUS_COMPLETED
      session.save(state_dir: tmpdir)

      result = described_class.wait_for_session(session.id, timeout: 1, state_dir: tmpdir)
      expect(result).to be true
    end

    it "returns false when session stays running beyond timeout" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.status = Samagotchi::Session::STATUS_RUNNING
      session.save(state_dir: tmpdir)

      result = described_class.wait_for_session(session.id, timeout: 1, state_dir: tmpdir)
      expect(result).to be false
    end
  end

  describe ".resume_session" do
    it "wakes an idle session by spawning a worker" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.status = Samagotchi::Session::STATUS_IDLE
      session.save(state_dir: tmpdir)
      allow(Process).to receive(:spawn).and_return(20_002)

      described_class.resume_session(session.id, state_dir: tmpdir)

      expect(Process).to have_received(:spawn)
      # A live worker is not a running turn: the worker marks its turns.
      loaded = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      expect(loaded.status).to eq(Samagotchi::Session::STATUS_IDLE)
    end

    it "clears a stopped or stale running status when it wakes a worker" do
      [Samagotchi::Session::STATUS_STOPPED, Samagotchi::Session::STATUS_ERROR, Samagotchi::Session::STATUS_RUNNING].each do |status|
        session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
        session.status = status
        session.save(state_dir: tmpdir)
        allow(Process).to receive(:spawn).and_return(20_002)

        described_class.resume_session(session.id, state_dir: tmpdir)

        expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).status).to eq(Samagotchi::Session::STATUS_IDLE)
      end
    end
  end

  describe ".spawn_session" do
    it "starts a session with no prompt idle, with nothing to run" do
      allow(Process).to receive(:spawn).and_return(12_345)

      session = described_class.spawn_session(prompt: nil, mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      loaded = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      expect(loaded.status).to eq(Samagotchi::Session::STATUS_IDLE)
      expect(loaded.last_prompt.to_s).to eq("")
      expect(Process).to have_received(:spawn)
    end

    it "records the first prompt as the preview, before the worker takes it" do
      allow(Process).to receive(:spawn).and_return(12_345)

      session = described_class.spawn_session(prompt: "  fix the\n  bug " + ("x" * 90), model_name: "gemma4", state_dir: tmpdir)

      loaded = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      expect(loaded.first_preview).to eq("fix the bug #{"x" * 68}…")
    end

    it "hands the worker an idle exit set on the command line" do
      Samagotchi::Config.set_cli_overrides("session.idle_exit_minutes" => "0.5")
      spawned_env = nil
      allow(Process).to receive(:spawn) do |*args, **_opts|
        spawned_env = args.first if args.first.is_a?(Hash)
        12_345
      end

      described_class.spawn_session(prompt: nil, mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      expect(spawned_env).to include("SAMAGOTCHI_SESSION_IDLE_EXIT_MINUTES" => "0.5")
    ensure
      Samagotchi::Config.set_cli_overrides({})
    end

    describe "the worker's debug log" do
      def spawned_env
        env = nil
        allow(Process).to receive(:spawn) do |*args, **_opts|
          env = args.first if args.first.is_a?(Hash)
          12_345
        end
        described_class.spawn_session(prompt: nil, mode: "assist", model_name: "gemma4", working_directory: tmpdir, state_dir: tmpdir)
        env
      end

      after { Samagotchi::Config.set_cli_overrides({}) }

      it "is the spawner's log.file, made absolute against the spawner's directory" do
        Samagotchi::Config.set_cli_overrides("log.file" => "logs/chi.log")

        expect(spawned_env).to include("SAMAGOTCHI_LOG_FILE" => File.join(Dir.pwd, "logs", "chi.log"))
      end

      it "is disabled when the spawner's log is" do
        Samagotchi::Config.set_cli_overrides("log.disable" => true)

        expect(spawned_env).to include("SAMAGOTCHI_LOG_DISABLE" => "true")
        expect(spawned_env).not_to have_key("SAMAGOTCHI_LOG_FILE")
      end
    end

    it "spawns worker with explicit require for session manager" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      allow(Samagotchi::Session).to receive(:new_session).and_return(session)
      spawned_args = nil
      allow(Process).to receive(:spawn) do |*args|
        spawned_args = args
        12_345
      end

      described_class.spawn_session(prompt: "hello", mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      expect(Process).to have_received(:spawn)
      args_str = spawned_args.map(&:to_s).join(" ")
      expect(args_str).to include("require 'samagotchi/session_manager'; Samagotchi::SessionManager.run_session_loop")
      expect(spawned_args).to include(RbConfig.ruby)
      expect(spawned_args).to include("-I")

      lib_path_index = spawned_args.index("-I") + 1
      expect(spawned_args[lib_path_index]).to end_with("/lib")
      expect(File.directory?(spawned_args[lib_path_index])).to be true

      # The worker writes its own pid once it owns the session; a parent
      # writing it raced a second spawn and could record the loser.
      pid_file = File.join(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), Samagotchi::SessionManager::PID_FILE)
      expect(File.exist?(pid_file)).to be false
    end

    it "starts the worker in its own process group, so a Ctrl-C on `chi web` does not reach it" do
      spawned_opts = nil
      allow(Process).to receive(:spawn) do |*args, **opts|
        spawned_opts = opts
        12_345
      end

      described_class.spawn_session(prompt: "hello", mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      expect(spawned_opts).to include(pgroup: true)
    end
  end

  describe "the worker's directory" do
    def spawned_opts
      opts = nil
      allow(Process).to receive(:spawn) do |*_args, **o|
        opts = o
        12_345
      end
      yield
      opts
    end

    it "starts the worker in the session's directory, so its tools run there" do
      dir = Dir.mktmpdir("session-dir", tmpdir)

      opts = spawned_opts { described_class.spawn_session(prompt: nil, model_name: "gemma4", working_directory: dir, state_dir: tmpdir) }

      expect(opts).to include(chdir: dir)
    end

    it "falls back to the spawner's directory, with a log line, when the session's is gone" do
      log = File.join(tmpdir, "chi.log")
      Samagotchi::Config.set_cli_overrides("log.file" => log)
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: File.join(tmpdir, "gone"))
      session.save(state_dir: tmpdir)

      opts = spawned_opts { described_class.resume_session(session.id, state_dir: tmpdir) }

      expect(opts).not_to have_key(:chdir)
      expect(File.read(log)).to include("#{File.join(tmpdir, "gone")} is gone", Dir.pwd)
    ensure
      Samagotchi::Config.set_cli_overrides({})
    end
  end

  describe ".debug_log" do
    after { Samagotchi::Config.set_cli_overrides({}) }

    it "writes to the default log under XDG_STATE_HOME when log.file is unset" do
      stub_const("ENV", ENV.to_h.merge("XDG_STATE_HOME" => tmpdir))

      described_class.debug_log("[worker] hello")

      expect(File.read(File.join(tmpdir, "samagotchi", "samagotchi.log"))).to include("[worker] hello")
    end

    it "writes nothing when log.disable is set" do
      log = File.join(tmpdir, "chi.log")
      Samagotchi::Config.set_cli_overrides("log.file" => log, "log.disable" => true)

      described_class.debug_log("[worker] hello")

      expect(File.exist?(log)).to be(false)
    end
  end

  describe "single owner" do
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
        s.save(state_dir: tmpdir)
      end
    end
    let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }

    after { @lock&.release }

    it "does not spawn a second worker while one owns the session" do
      @lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "worker")
      allow(Process).to receive(:spawn)

      described_class.resume_session(session.id, state_dir: tmpdir)

      expect(Process).not_to have_received(:spawn)
    end

    it "spawns a worker when the last owner is gone, even if its pid was reused" do
      Samagotchi::OwnerLock.acquire(session_dir, kind: "worker").release
      File.write(File.join(session_dir, described_class::PID_FILE), Process.pid.to_s)
      allow(Process).to receive(:spawn).and_return(20_003)

      described_class.resume_session(session.id, state_dir: tmpdir)

      expect(Process).to have_received(:spawn)
    end

    it "treats a live pid-only worker (from before the owner lock) as the owner" do
      FileUtils.mkdir_p(session_dir)
      File.write(File.join(session_dir, described_class::PID_FILE), Process.pid.to_s)
      allow(Process).to receive(:spawn)

      described_class.resume_session(session.id, state_dir: tmpdir)

      expect(Process).not_to have_received(:spawn)
    end

    it "refuses to resume, write input for, or stop a session the interactive TUI owns" do
      @lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "tui")
      allow(Process).to receive(:spawn)
      allow(Process).to receive(:kill)

      expect { described_class.resume_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::OwnedByTUI)
      expect { described_class.stop_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::OwnedByTUI)
      expect(Process).not_to have_received(:spawn)
      expect(Process).not_to have_received(:kill)
      expect(described_class.session_owner(session.id, state_dir: tmpdir)).to include("kind" => "tui")
    end

    it "lets only one of two contending workers run the session" do
      @lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "worker")
      expect(Samagotchi::Engine).not_to receive(:new)

      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir, owner_wait: 0.1)
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    end

    it "does not run the initial prompt of a session stopped before the worker took it" do
      session.last_prompt = "hello"
      session.status = Samagotchi::Session::STATUS_STOPPED
      session.save(state_dir: tmpdir)
      engine = instance_double(Samagotchi::Engine, "interface=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil, start_idle: nil, stop_idle: nil, reminder_store: nil,
                                              turn_running?: false, last_activity_at: 0.0)
      allow(engine).to receive(:subscribe).and_return(double("subscribe_handle", unsubscribe: nil))
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
      expect(engine).not_to receive(:run_turn)

      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir)
      }.to raise_error(SystemExit)
    end

    it "records the worker as owner, with its own pid, while it runs" do
      engine = instance_double(Samagotchi::Engine, "interface=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil, start_idle: nil, stop_idle: nil, reminder_store: nil,
                                              turn_running?: false, last_activity_at: 0.0)
      allow(engine).to receive(:subscribe).and_return(double("subscribe_handle", unsubscribe: nil))
      owner_seen = nil
      pid_seen = nil
      allow(Samagotchi::Engine).to receive(:new) do
        owner_seen = Samagotchi::OwnerLock.owner(session_dir)
        pid_seen = File.read(File.join(session_dir, described_class::PID_FILE))
        engine
      end
      allow(described_class).to receive(:find_new_input_files) do
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
        []
      end

      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir, poll_interval: 0.01)
      }.to raise_error(SystemExit)

      expect(owner_seen).to include("kind" => "worker", "pid" => Process.pid)
      expect(pid_seen).to eq(Process.pid.to_s)
      # Released on the way out.
      expect(Samagotchi::OwnerLock.owner(session_dir)).to be_nil
    end
  end

  describe ".run_session_loop" do
    it "initializes Engine with supported keywords" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.status = Samagotchi::Session::STATUS_STOPPED
      session.save(state_dir: tmpdir)

      engine = instance_double(Samagotchi::Engine, "interface=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil)
      expect(Samagotchi::Engine).to receive(:new)
        .with(hash_including(mode: :assist, model_name: "gemma4"))
        .and_return(engine)

      allow(engine).to receive(:start_idle)
      allow(engine).to receive(:stop_idle)
      allow(engine).to receive(:reminder_store).and_return(nil)
      allow(engine).to receive_messages(turn_running?: false, last_activity_at: 0.0)
      # The worker always starts its Bridge, which subscribes a capture observer.
      sub_handle = double("subscribe_handle")
      allow(sub_handle).to receive(:unsubscribe)
      allow(engine).to receive(:subscribe).and_return(sub_handle)

      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir)
      }.to raise_error(SystemExit)
    end

    it "leaves the idle recap to the config (the web and attached UIs show :recap_ready)" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.status = Samagotchi::Session::STATUS_STOPPED
      session.save(state_dir: tmpdir)

      engine = instance_double(Samagotchi::Engine, "interface=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil, start_idle: nil, stop_idle: nil, reminder_store: nil,
                                              turn_running?: false, last_activity_at: 0.0)
      expect(Samagotchi::Engine).to receive(:new) do |**kwargs|
        expect(kwargs).not_to have_key(:recap)
        engine
      end
      allow(engine).to receive(:subscribe).and_return(double("subscribe_handle", unsubscribe: nil))

      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir)
      }.to raise_error(SystemExit)
    end

    it "hands the Engine its session before any turn, so a joining UI sees the history" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.messages = [{ role: "user", content: "earlier" }, { role: "model", content: "reply" }]
      session.save(state_dir: tmpdir)

      engine = instance_double(Samagotchi::Engine, "interface=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], start_idle: nil, stop_idle: nil, reminder_store: nil,
                                              turn_running?: false, last_activity_at: 0.0)
      allow(engine).to receive(:subscribe).and_return(double("subscribe_handle", unsubscribe: nil))
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
      given = nil
      allow(engine).to receive(:session=) { |s| given = s }
      bridge_started = false
      allow(described_class).to receive(:start_bridge) do
        bridge_started = true
        expect(given).not_to be_nil
        nil
      end
      allow(described_class).to receive(:find_new_input_files) do
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
        []
      end

      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir, poll_interval: 0.01)
      }.to raise_error(SystemExit)

      expect(bridge_started).to be(true)
      expect(given.id).to eq(session.id)
      expect(given.messages.map { |m| m[:content] || m["content"] }).to eq(%w[earlier reply])
    end

    it "wires a reminder callback that notes the due reminders for a reminder turn, with no input file" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.status = Samagotchi::Session::STATUS_STOPPED
      session.save(state_dir: tmpdir)

      engine = instance_double(Samagotchi::Engine, "interface=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil)
      reminder_callback = nil
      allow(Samagotchi::Engine).to receive(:new) do |**kwargs|
        reminder_callback = kwargs.dig(:reminders, :callback)
        engine
      end
      allow(engine).to receive(:start_idle)
      allow(engine).to receive(:stop_idle)
      allow(engine).to receive(:reminder_store).and_return(nil)
      allow(engine).to receive_messages(turn_running?: false, last_activity_at: 0.0)
      sub_handle = double("subscribe_handle")
      allow(sub_handle).to receive(:unsubscribe)
      allow(engine).to receive(:subscribe).and_return(sub_handle)

      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir)
      }.to raise_error(SystemExit)

      expect(engine).to receive(:note_due_reminders).with(["daily"])
      expect { reminder_callback.call(["daily"]) }.not_to raise_error
      input_dir = File.join(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), Samagotchi::SessionManager::INPUT_DIR)
      expect(Dir.glob(File.join(input_dir, "*"))).to be_empty
    end

    it "atomically claims an input file for single-consumer processing" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session_dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
      input_dir = File.join(session_dir, Samagotchi::SessionManager::INPUT_DIR)
      FileUtils.mkdir_p(input_dir)

      input_file = File.join(input_dir, "20260101000000000000000.txt")
      File.write(input_file, "ping")

      claimed = described_class.send(:claim_input_file, input_file)

      expect(File.exist?(input_file)).to be false
      expect(claimed).to end_with(".processing")
      expect(File.read(claimed)).to eq("ping")

      FileUtils.rm_f(claimed)
      expect(Dir.glob(File.join(input_dir, "*")).length).to eq(0)
    end

    it "processes prompts through Engine public background API" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.status = Samagotchi::Session::STATUS_RUNNING
      session.last_prompt = "hello"
      session.save(state_dir: tmpdir)

      engine = instance_double(Samagotchi::Engine, "interface=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil, messages_checkpoint: [])
      result = instance_double(Samagotchi::KernelLoop::Result, output: "hi")
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
      allow(engine).to receive(:start_idle)
      allow(engine).to receive(:stop_idle)
      allow(engine).to receive(:reminder_store).and_return(nil)
      allow(engine).to receive_messages(turn_running?: false, last_activity_at: 0.0)
      # The worker always starts its Bridge, which subscribes a capture observer.
      sub_handle = double("subscribe_handle")
      allow(sub_handle).to receive(:unsubscribe)
      allow(engine).to receive(:subscribe).and_return(sub_handle)
      expect(engine).to receive(:run_turn)
        .with(instance_of(Samagotchi::Session), "hello", pending_input: kind_of(Proc), origin: nil, max_iterations: 100, images: []) do
          Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
          result
        end

      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir)
      }.to raise_error(SystemExit)
    end

    it "does not replay the last prompt when resuming a session with history" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.messages = [{ role: "user", content: "earlier" }, { role: "model", content: "answer" }]
      session.last_prompt = "earlier"
      session.save(state_dir: tmpdir)

      engine = instance_double(Samagotchi::Engine, "interface=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil)
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
      allow(engine).to receive(:start_idle)
      allow(engine).to receive(:reminder_store).and_return(nil)
      allow(engine).to receive_messages(turn_running?: false, last_activity_at: 0.0)
      sub_handle = double("subscribe_handle")
      allow(sub_handle).to receive(:unsubscribe)
      allow(engine).to receive(:subscribe).and_return(sub_handle)
      expect(engine).not_to receive(:run_turn)
      # Stop on the first poll so the loop exits.
      allow(described_class).to receive(:find_new_input_files) do
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
        []
      end

      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir, poll_interval: 0.01)
      }.to raise_error(SystemExit)
      expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).last_prompt).to eq("earlier")
    end
  end

  describe "idle exit" do
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
        s.save(state_dir: tmpdir)
      end
    end
    let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }
    let(:sidecar) { File.join(session_dir, "bridge.json") }
    let(:reminders) { Samagotchi::ReminderStore.new }
    let(:engine) do
      instance_double(Samagotchi::Engine, "interface=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil, start_idle: nil, stop_idle: nil,
                                          reminder_store: reminders, turn_running?: false, last_activity_at: 0.0,
                                          messages_checkpoint: [])
    end

    before do
      allow(engine).to receive(:subscribe).and_return(double("subscribe_handle", unsubscribe: nil))
      allow(engine).to receive(:synchronize_events) { |&block| block.call }
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
    end

    def run_worker
      described_class.run_session_loop(session.id, state_dir: tmpdir, idle_exit_minutes: 0.002, poll_interval: 0.01)
    end

    def input_files
      Dir.glob(File.join(session_dir, described_class::INPUT_DIR, "*.json"))
    end

    it "returns once nobody has used the worker for the timeout, freeing the session" do
      sidecar_seen = nil
      allow(described_class).to receive(:find_new_input_files).and_wrap_original do |original, *args|
        sidecar_seen ||= File.exist?(sidecar)
        original.call(*args)
      end

      expect(run_worker).to eq(:idle_exit)

      expect(sidecar_seen).to be(true)
      expect(File.exist?(sidecar)).to be(false)
      expect(Samagotchi::OwnerLock.owner(session_dir)).to be_nil
      expect(engine).to have_received(:stop_idle)
    end

    it "stays up while a reminder is registered" do
      reminders.register(name: "stretch", description: "Remind me to stretch", interval_minutes: 60)
      polls = 0
      allow(described_class).to receive(:find_new_input_files).and_wrap_original do |original, *args|
        polls += 1
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir) if polls == 60
        original.call(*args)
      end

      expect { run_worker }.to raise_error(SystemExit)
      expect(polls).to be >= 60
    end

    it "stays up for input that came in while it checked with the event log held" do
      calls = 0
      allow(engine).to receive(:synchronize_events) do |&block|
        calls += 1
        described_class.write_turn_input(session.id, prompt: "late", state_dir: tmpdir) if calls == 1
        block.call
      end
      allow(engine).to receive(:run_turn) do
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
        nil
      end

      expect { run_worker }.to raise_error(SystemExit)
      expect(engine).to have_received(:run_turn).with(anything, "late", hash_including(:pending_input))
    end

    it "wakes a new worker for input queued after its last check" do
      # Written after the check, while this worker still holds the lock.
      allow(engine).to receive(:stop_idle) do
        described_class.write_turn_input(session.id, prompt: "late", state_dir: tmpdir)
      end
      allow(Process).to receive(:spawn).and_return(40_004)

      expect(run_worker).to eq(:idle_exit)

      expect(Process).to have_received(:spawn)
      expect(input_files.size).to eq(1)
    end

    it "wakes a new worker for input queued as it left on a client's request too" do
      allow_any_instance_of(Samagotchi::Worker).to receive(:run) do
        described_class.write_turn_input(session.id, prompt: "late", state_dir: tmpdir)
        :exit_requested
      end
      allow(Process).to receive(:spawn).and_return(40_005)

      expect(run_worker).to eq(:exit_requested)

      expect(Process).to have_received(:spawn)
      expect(Samagotchi::OwnerLock.owner(session_dir)).to be_nil
    end
  end

  describe "structured input" do
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
        s.save(state_dir: tmpdir)
      end
    end
    let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }
    let(:input_dir) { File.join(session_dir, described_class::INPUT_DIR) }

    def write_sidecar(record)
      FileUtils.mkdir_p(session_dir)
      File.write(File.join(session_dir, "bridge.json"), JSON.generate(record))
    end

    it "writes a JSON input file carrying the sender's ids" do
      path = described_class.write_turn_input(session.id, prompt: "hi", client_id: "web:1", enqueued_id: "e1", state_dir: tmpdir)

      expect(path).to end_with(".json")
      expect(JSON.parse(File.read(path))).to eq("prompt" => "hi", "client_id" => "web:1", "enqueued_id" => "e1")
    end

    it "writes plain text for a live worker that predates structured input" do
      write_sidecar("port" => 1, "session_id" => session.id)

      path = described_class.write_turn_input(session.id, prompt: "hi", client_id: "web:1", state_dir: tmpdir)

      expect(path).to end_with(".txt")
      expect(File.read(path)).to eq("hi")
    end

    it "writes JSON for a worker that advertises input_format 2" do
      write_sidecar("port" => 1, "session_id" => session.id, "input_format" => 2)

      expect(described_class.write_turn_input(session.id, prompt: "hi", state_dir: tmpdir)).to end_with(".json")
    end

    def run_worker_with(engine)
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
      allow(engine).to receive(:start_idle)
      allow(engine).to receive(:reminder_store).and_return(nil)
      allow(engine).to receive_messages(turn_running?: false, last_activity_at: 0.0, messages_checkpoint: [])
      allow(engine).to receive(:subscribe).and_return(double("subscribe_handle", unsubscribe: nil))
      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir)
      }.to raise_error(SystemExit)
    end

    it "runs queued turns with their origin, text or JSON" do
      described_class.write_turn_input(session.id, prompt: "from web", client_id: "web:1", enqueued_id: "e1", state_dir: tmpdir)
      write_sidecar("port" => 1, "session_id" => session.id) # an old worker's sidecar: next write is .txt
      described_class.write_turn_input(session.id, prompt: "plain", state_dir: tmpdir)
      engine = instance_double(Samagotchi::Engine, "interface=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil)
      runs = []
      allow(engine).to receive(:run_turn) do |_session, prompt, origin:, **|
        runs << [prompt, origin]
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir) if runs.size == 2
        instance_double(Samagotchi::KernelLoop::Result, output: "")
      end

      run_worker_with(engine)

      expect(runs).to eq([["from web", { client_id: "web:1", enqueued_id: "e1" }], ["plain", nil]])
    end

    it "runs a turn queued with no_interrupt under the raised iteration limit" do
      described_class.write_turn_input(session.id, prompt: "long", client_id: "tui:1", no_interrupt: true, state_dir: tmpdir)
      described_class.write_turn_input(session.id, prompt: "short", state_dir: tmpdir)
      engine = instance_double(Samagotchi::Engine, "interface=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil)
      runs = []
      allow(engine).to receive(:run_turn) do |_session, prompt, max_iterations:, **|
        runs << [prompt, max_iterations]
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir) if runs.size == 2
        instance_double(Samagotchi::KernelLoop::Result, output: "")
      end

      run_worker_with(engine)

      expect(runs).to eq([["long", 1000], ["short", 100]])
    end

    it "marks the session running on disk while a turn runs, and stops before the next queued turn" do
      described_class.write_turn_input(session.id, prompt: "one", state_dir: tmpdir)
      described_class.write_turn_input(session.id, prompt: "two", state_dir: tmpdir)
      engine = instance_double(Samagotchi::Engine, "interface=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil)
      runs = []
      allow(engine).to receive(:run_turn) do |_session, prompt, **|
        runs << [prompt, Samagotchi::Session.load(session.id, state_dir: tmpdir).status]
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
        instance_double(Samagotchi::KernelLoop::Result, output: "")
      end

      run_worker_with(engine)

      expect(runs).to eq([%w[one running]])
      expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).status).to eq("stopped")
      # Still queued for whoever resumes the session.
      expect(Dir.children(input_dir).map { |f| JSON.parse(File.read(File.join(input_dir, f)))["prompt"] }).to eq(["two"])
    end

    it "announces who sent input merged into a running turn" do
      engine = instance_double(Samagotchi::Engine, "interface=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil)
      announced = []
      allow(engine).to receive(:announce) { |event| announced << event }
      drained = nil
      described_class.write_turn_input(session.id, prompt: "first", state_dir: tmpdir)
      allow(engine).to receive(:run_turn) do |_session, _prompt, pending_input:, **|
        described_class.write_turn_input(session.id, prompt: "steer", client_id: "tui:1", enqueued_id: "e2", state_dir: tmpdir)
        drained = pending_input.call
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
        instance_double(Samagotchi::KernelLoop::Result, output: "")
      end

      run_worker_with(engine)

      expect(drained).to eq(["steer"])
      expect(announced).to eq([{ type: :input_merged, count: 1, origins: [{ client_id: "tui:1", enqueued_id: "e2" }] }])
    end
  end

  describe ".read_responses" do
    it "only returns outputs strictly newer than since_time" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session_dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
      output_dir = File.join(session_dir, Samagotchi::SessionManager::OUTPUT_DIR)
      FileUtils.mkdir_p(output_dir)

      old_file = File.join(output_dir, "old.txt")
      new_file = File.join(output_dir, "new.txt")
      File.write(old_file, "old")
      boundary = Time.now
      sleep(0.01)
      File.write(new_file, "new")

      responses = described_class.read_responses(session.id, since_time: boundary, state_dir: tmpdir)
      expect(responses).to eq(["new"])
    end
  end

  describe "context notes" do
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
        s.save(state_dir: tmpdir)
      end
    end
    let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }
    let(:notes_dir) { File.join(session_dir, described_class::NOTES_DIR) }

    it "writes a note to notes/, never to input/" do
      path = described_class.write_note(session.id, text: "  deploy frozen  \n", source: "slack", state_dir: tmpdir)

      expect(File.dirname(path)).to eq(notes_dir)
      expect(path).to end_with(".json")
      expect(described_class.find_new_input_files(session_dir)).to be_empty
      record = JSON.parse(File.read(path))
      expect(record).to include("text" => "deploy frozen", "source" => "slack")
      expect(record["created_at"]).to match(/\A\d{4}-\d\d-\d\dT/)
      expect(record).not_to have_key("from_session")
    end

    it "keeps the sending session and its folder" do
      path = described_class.write_note(session.id, text: "api moved", source: "session",
                                                    from_session: "3f2a1c00-1111", from_cwd: "/work/foo", state_dir: tmpdir)

      expect(JSON.parse(File.read(path))).to include("from_session" => "3f2a1c00-1111", "from_cwd" => "/work/foo")
    end

    it "defaults the source to cli" do
      path = described_class.write_note(session.id, text: "x", state_dir: tmpdir)
      expect(JSON.parse(File.read(path))["source"]).to eq("cli")
    end

    it "rejects an empty note" do
      expect { described_class.write_note(session.id, text: " \n\t", state_dir: tmpdir) }
        .to raise_error(described_class::NoteRejected, /empty/)
      expect(Dir.exist?(notes_dir) && Dir.children(notes_dir)).to be_falsey.or eq([])
    end

    it "rejects a note over 16 KiB instead of cutting it" do
      big = "a" * (16 * 1024 + 1)
      expect { described_class.write_note(session.id, text: big, state_dir: tmpdir) }
        .to raise_error(described_class::NoteRejected, /16 KiB/)
      expect(described_class.write_note(session.id, text: "a" * (16 * 1024), state_dir: tmpdir)).to be_a(String)
    end

    it "counts bytes, not characters" do
      expect { described_class.write_note(session.id, text: "ж" * (8 * 1024 + 1), state_dir: tmpdir) }
        .to raise_error(described_class::NoteRejected)
    end

    it "lists notes oldest first, and a claim moves one out of the way" do
      first = described_class.write_note(session.id, text: "one", state_dir: tmpdir)
      second = described_class.write_note(session.id, text: "two", state_dir: tmpdir)

      expect(described_class.find_new_note_files(session_dir)).to eq([first, second])

      claimed = described_class.claim_note_file(first)
      expect(claimed).to eq("#{first}.processing")
      expect(File.exist?(first)).to be false
      expect(described_class.claim_note_file(first)).to be_nil
    end

    it "lists a claimed note left by a crashed worker, and claims it again as is" do
      path = described_class.write_note(session.id, text: "left over", state_dir: tmpdir)
      claimed = described_class.claim_note_file(path)

      expect(described_class.find_new_note_files(session_dir)).to eq([claimed])
      expect(described_class.claim_note_file(claimed)).to eq(claimed)
    end

    it "ignores a half-written .tmp file" do
      FileUtils.mkdir_p(notes_dir)
      File.write(File.join(notes_dir, "20260101000000000000000-abc.json.tmp"), "{")
      expect(described_class.find_new_note_files(session_dir)).to be_empty
    end

    it "reads a claimed note with its id (the file name)" do
      path = described_class.write_note(session.id, text: "hello", source: "slack", from_session: "abc",
                                                    from_cwd: "/w", state_dir: tmpdir)
      note = described_class.read_note(described_class.claim_note_file(path))

      expect(note).to include(note_id: File.basename(path, ".json"), text: "hello", source: "slack",
                              from_session: "abc", from_cwd: "/w")
      expect(note[:created_at]).to be_a(String)
    end

    it "reads nil for a broken or empty note file" do
      FileUtils.mkdir_p(notes_dir)
      broken = File.join(notes_dir, "20260101000000000000000-abc.json")
      File.write(broken, "{nope")
      expect(described_class.read_note(broken)).to be_nil
      File.write(broken, JSON.generate("text" => "  "))
      expect(described_class.read_note(broken)).to be_nil
    end
  end

  describe ".session_summaries" do
    let(:locks) { [] }

    after { locks.each(&:release) }

    def make(cwd: "/work/app", prompt: "hello", updated: "2026-09-24T10:00:00Z", status: nil, test_run: false, preview: "")
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: cwd).tap do |s|
        s.last_prompt = prompt
        s.first_preview = preview
        s.status = status if status
        s.test_run = test_run
        s.save(state_dir: tmpdir)
        # save stamps updated_at; set it after for a fixed order
        data = JSON.parse(File.read(File.join(tmpdir, "#{s.id}.json")))
        File.write(File.join(tmpdir, "#{s.id}.json"), JSON.generate(data.merge("updated_at" => updated)))
      end
    end

    def own(session, kind: "worker")
      locks << Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), kind: kind)
    end

    def ids(**opts) = described_class.session_summaries(state_dir: tmpdir, **opts).map { |s| s[:id] }

    it "sums a session up: short id, a one-line description, cwd, liveness and whether a turn runs" do
      session = make(cwd: "/work/app", prompt: "fix   the\nlogin page", status: Samagotchi::Session::STATUS_RUNNING)
      own(session)

      summary = described_class.session_summaries(state_dir: tmpdir).first

      expect(summary).to include(id: session.id, short_id: session.id[0, 8], desc: "app · fix the login page",
                                 cwd: "/work/app", updated_at: "2026-09-24T10:00:00Z", live: true, busy: true)
    end

    it "cuts a long description to 60 characters and falls back to the first preview" do
      long = make(prompt: "x" * 100)
      preview = make(prompt: "", preview: "from the preview", updated: "2026-09-23T10:00:00Z")

      by_id = described_class.session_summaries(state_dir: tmpdir).to_h { |s| [s[:id], s[:desc]] }

      expect(by_id[long.id].length).to eq(60)
      expect(by_id[long.id]).to end_with("…")
      expect(by_id[preview.id]).to eq("app · from the preview")
    end

    it "live: only sessions a worker owns now, not a REPL's and not a stale running status" do
      worker = make(updated: "2026-09-24T10:00:00Z")
      repl = make(updated: "2026-09-24T11:00:00Z")
      stale = make(updated: "2026-09-24T12:00:00Z", status: Samagotchi::Session::STATUS_RUNNING)
      own(worker)
      own(repl, kind: "tui")

      expect(ids(live: true)).to eq([worker.id])
      expect(ids).to eq([stale.id, repl.id, worker.id])
      expect(described_class.session_summaries(state_dir: tmpdir).find { |s| s[:id] == stale.id })
        .to include(live: false, busy: false)
    end

    it "filters before it takes the limit" do
      live_one = make(updated: "2026-09-24T09:00:00Z")
      make(updated: "2026-09-24T10:00:00Z")
      make(updated: "2026-09-24T11:00:00Z")
      own(live_one)

      expect(ids(live: true, limit: 1)).to eq([live_one.id])
      expect(ids(limit: 2).size).to eq(2)
    end

    it "cwd: the folder or below it, not a sibling that shares its prefix" do
      top = make(cwd: "/work/app", updated: "2026-09-24T12:00:00Z")
      below = make(cwd: "/work/app/web", updated: "2026-09-24T11:00:00Z")
      make(cwd: "/work/apple", updated: "2026-09-24T10:00:00Z")

      expect(ids(cwd: "/work/app")).to eq([top.id, below.id])
      expect(ids(cwd: "/work/app/")).to eq([top.id, below.id])
    end

    it "leaves out test runs on request, and a given session (the asking one)" do
      mine = make(updated: "2026-09-24T12:00:00Z")
      test = make(test_run: true, updated: "2026-09-24T11:00:00Z")
      other = make(updated: "2026-09-24T10:00:00Z")

      expect(ids).to include(test.id)
      expect(ids(include_tests: false, exclude: mine.id)).to eq([other.id])
    end
  end
end
