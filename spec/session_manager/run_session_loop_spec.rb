# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/worker_link"
require "samagotchi/engine"
require "samagotchi/session_manager"
require "samagotchi/worker_boot"
require "samagotchi/worker"
require "samagotchi/bridge"
require "samagotchi/reminder_store"
require_relative "../support/session_manager_context"

RSpec.describe Samagotchi::SessionManager do
  include_context "session manager files"

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
      File.write(File.join(session_dir, "pid"), Process.pid.to_s)
      allow(Process).to receive(:spawn).and_return(20_003)

      described_class.resume_session(session.id, state_dir: tmpdir)

      expect(Process).to have_received(:spawn)
    end

    it "counts a session with only a pid file (no lock) as not owned, even when that pid is alive" do
      FileUtils.mkdir_p(session_dir)
      File.write(File.join(session_dir, "pid"), Process.pid.to_s)
      allow(Process).to receive(:spawn).and_return(20_004)

      expect(described_class.session_owner(session.id, state_dir: tmpdir)).to be_nil
      described_class.resume_session(session.id, state_dir: tmpdir)

      expect(Process).to have_received(:spawn)
    end

    it "refuses to resume, write input for, or stop a session the interactive TUI owns" do
      @lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "tui")
      allow(Process).to receive(:spawn)
      allow(Process).to receive(:kill)

      expect { described_class.resume_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::OwnedByTUI, "session #{session.id} is in use by a one-turn chi --non-interactive run or an older chi's terminal; let it finish first")
      expect { described_class.stop_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::OwnedByTUI)
      expect(Process).not_to have_received(:spawn)
      expect(Process).not_to have_received(:kill)
      expect(described_class.session_owner(session.id, state_dir: tmpdir)).to have_attributes(kind: "tui")
    end

    it "lets only one of two contending workers run the session" do
      @lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "worker")
      expect(Samagotchi::Engine).not_to receive(:new)

      expect do
        Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir, owner_wait: 0.1)
      end.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    end

    it "decides the worker's exit: 0 on a stop, without resuming for queued input or discarding; 1 on a crash" do
      described_class.write_turn_input(session.id, client_id: nil, prompt: "queued", state_dir: tmpdir)
      allow(described_class).to receive(:resume_session)
      allow(described_class).to receive(:discardable?).and_return(true)
      allow_any_instance_of(Samagotchi::Worker).to receive(:run).and_return(:stopped)

      expect do
        Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir)
      end.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      expect(described_class).not_to have_received(:resume_session)
      expect(described_class).not_to have_received(:discardable?)
      expect(Samagotchi::OwnerLock.owner(session_dir)).to be_nil

      allow_any_instance_of(Samagotchi::Worker).to receive(:run).and_return(:crashed)
      expect do
        Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir)
      end.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "does not run the initial prompt of a session stopped before the worker took it, nor its plugins' init tasks" do
      session.last_prompt = "hello"
      session.save(state_dir: tmpdir)
      Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
      engine = instance_double(Samagotchi::Engine, announce_participants: nil, command_registry: Samagotchi::SessionCommands.builtin_registry, peer_sources: nil, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, warm_toolkit_suggestion!: nil, "interface=": nil, "participant_stop=": nil, recap: nil, "recap_awaiting_continue=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, "next_turn_waiting=": nil, due_reminder_names: [], "session=": nil, start_idle: nil, stop_idle: nil, reminder_store: nil,
                                              turn_running?: false, last_activity_at: 0.0)
      allow(engine).to receive(:subscribe).and_return(double("subscribe_handle", unsubscribe: nil))
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
      expect(engine).not_to receive(:run_turn)

      expect do
        Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir)
      end.to raise_error(SystemExit)
      expect(engine).to have_received(:announce_load_events!)
      expect(engine).not_to have_received(:start_init_tasks!)
    end

    # resume_session writes nothing to the file (the worker owns it): the
    # worker, holding the lock, turns a status no turn is behind idle, as
    # the resume did before. Never a stopped one (the marker), nor a new
    # session's running whose first prompt hasn't run.
    describe "the status a worker finds as it takes the session" do
      def fake_engine
        instance_double(Samagotchi::Engine, announce_participants: nil, command_registry: Samagotchi::SessionCommands.builtin_registry, peer_sources: nil, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, warm_toolkit_suggestion!: nil, "interface=": nil, "participant_stop=": nil, recap: nil, "recap_awaiting_continue=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, "next_turn_waiting=": nil, due_reminder_names: [], "session=": nil, start_idle: nil, stop_idle: nil, reminder_store: nil,
                                                turn_running?: false, last_activity_at: 0.0).tap do |engine|
          allow(engine).to receive(:subscribe).and_return(double("subscribe_handle", unsubscribe: nil))
          allow(Samagotchi::Engine).to receive(:new).and_return(engine)
        end
      end

      # Runs the worker until its loop starts (its init tasks), then stops
      # it there: the status on disk at that moment.
      def status_as_it_runs(field = "status")
        engine = fake_engine
        seen = nil
        allow(engine).to receive(:start_init_tasks!) do
          seen = JSON.parse(File.read(File.join(tmpdir, "#{session.id}.json")))[field]
          Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
        end
        expect { Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir) }.to raise_error(SystemExit)
        seen
      end

      it "runs a session whose file says stopped with no stop marker (a stop baked in), idle" do
        session.status = Samagotchi::Session::STATUS_STOPPED
        session.save(state_dir: tmpdir)

        expect(status_as_it_runs).to eq("idle")
      end

      it "turns an error, or a running no turn is behind, idle" do
        [Samagotchi::Session::STATUS_ERROR, Samagotchi::Session::STATUS_RUNNING].each do |status|
          Samagotchi::Session.clear_stopped(session.id, state_dir: tmpdir)
          session.status = status
          session.messages = [{ role: "user", content: "hi" }, { role: "assistant", content: "hello" }]
          session.last_prompt = "hi"
          session.save(state_dir: tmpdir)

          expect(status_as_it_runs).to eq("idle")
        end
      end

      # A resume used to save the file: an old session woken with no turn
      # (an attach, a web wake) must not look old to the sweep.
      it "stamps updated_at as it takes the session, whatever its status" do
        session.messages = [{ role: "user", content: "hi" }, { role: "assistant", content: "hello" }]
        session.save(state_dir: tmpdir, now: Time.now - (20 * 86_400))

        expect(Time.iso8601(status_as_it_runs("updated_at"))).to be_within(60).of(Time.now)
      end

      it "keeps a new session's running while its first prompt waits" do
        session.status = Samagotchi::Session::STATUS_RUNNING
        session.last_prompt = "hello"
        session.save(state_dir: tmpdir)

        expect(status_as_it_runs).to eq("running")
      end
    end

    it "records the worker as owner, with its own pid, while it runs, and writes no pid file" do
      engine = instance_double(Samagotchi::Engine, announce_participants: nil, command_registry: Samagotchi::SessionCommands.builtin_registry, peer_sources: nil, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, warm_toolkit_suggestion!: nil, "interface=": nil, "participant_stop=": nil, recap: nil, "recap_awaiting_continue=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, "next_turn_waiting=": nil, due_reminder_names: [], "session=": nil, start_idle: nil, stop_idle: nil, reminder_store: nil,
                                              turn_running?: false, last_activity_at: 0.0)
      allow(engine).to receive(:subscribe).and_return(double("subscribe_handle", unsubscribe: nil))
      owner_seen = nil
      pid_seen = nil
      allow(Samagotchi::Engine).to receive(:new) do
        owner_seen = Samagotchi::OwnerLock.owner(session_dir)
        pid_seen = File.exist?(File.join(session_dir, "pid"))
        engine
      end
      allow(Samagotchi::SessionInbox).to receive(:find_new_input_files) do
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
        []
      end

      expect do
        Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir, poll_interval: 0.01)
      end.to raise_error(SystemExit)

      expect(owner_seen).to have_attributes(kind: "worker", pid: Process.pid)
      expect(pid_seen).to be(false)
      # Released on the way out.
      expect(Samagotchi::OwnerLock.owner(session_dir)).to be_nil
    end
  end

  describe "WorkerBoot.run_session_loop" do
    it "starts the next worker after a restart, once its lock is free, and never discards the session" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      worker = instance_double(Samagotchi::Worker, scratch?: false, run: :restart, discard?: false)
      allow(Samagotchi::Worker).to receive(:new).and_return(worker)
      owner_at_resume = :unset
      allow(described_class).to receive(:resume_session) do |id, state_dir:|
        owner_at_resume = described_class.session_owner(id, state_dir: state_dir)
      end
      allow(described_class).to receive(:delete_session)

      expect(Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir)).to eq(:restart)
      expect(described_class).to have_received(:resume_session).with(session.id, state_dir: tmpdir)
      expect(owner_at_resume).to be_nil
      expect(described_class).not_to have_received(:delete_session)
    end

    it "computes the project env only in a spawned worker, never in an in-process loop" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      allow(Samagotchi::Worker).to receive(:new).and_return(instance_double(Samagotchi::Worker, scratch?: false, run: :stopped))
      allow(Samagotchi::ProjectEnv).to receive(:compute)
      expect { Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir) }.to raise_error(SystemExit)
      expect(Samagotchi::ProjectEnv).not_to have_received(:compute)
    end

    it "starts a worker from a worker on its own env: the tools' project env never goes along" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      overlay = Samagotchi::ProjectEnv::NONE.with(env: { "PATH" => "/project/bin", "DATABASE_URL" => "a",
                                                         "SAMAGOTCHI_PROJECT_ENV_ORIG" => "{}" }.freeze)
      Samagotchi::ProjectEnv.install!(overlay)
      env = described_class.send(:spawn_options, session)[:env]
      expect(env.keys).not_to include("PATH", "DATABASE_URL")
    ensure
      Samagotchi::ProjectEnv.reset!
    end

    it "keeps a tool's project env record and marker from the worker it starts (bin/chi took the record's values)" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      with_env("SAMAGOTCHI_PROJECT_ENV_ORIG" => JSON.generate("PATH" => "/spawner/bin"),
               "SAMAGOTCHI_PROJECT_ENV" => "mise:/a/ruby") do
        env = described_class.send(:spawn_options, session)[:env]
        expect(env).to include("SAMAGOTCHI_PROJECT_ENV_ORIG" => nil, "SAMAGOTCHI_PROJECT_ENV" => nil)
        expect(env).not_to have_key("PATH")
      end
    end

    it "gives the project env the session's folder, and never fails the worker over it" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp/proj")
      session.save(state_dir: tmpdir)
      overlay = Samagotchi::ProjectEnv::NONE.with(reason: "no_mise")
      allow(Samagotchi::ProjectEnv).to receive(:compute).and_return(overlay)
      before_env = ENV.to_h
      Samagotchi::WorkerBoot.send(:apply_project_env, session.id, state_dir: tmpdir)
      expect(Samagotchi::ProjectEnv).to have_received(:compute).with("/tmp/proj")
      expect(Samagotchi::ProjectEnv.current).to eq(overlay)
      expect(ENV.to_h).to eq(before_env)
      Samagotchi::ProjectEnv.reset!

      allow(Samagotchi::Log).to receive(:warn)
      allow(Samagotchi::ProjectEnv).to receive(:compute).and_raise(ArgumentError, "boom")
      expect { Samagotchi::WorkerBoot.send(:apply_project_env, session.id, state_dir: tmpdir) }.not_to raise_error
      expect(Samagotchi::Log).to have_received(:warn)
        .with(:worker, "project_env", reason: "error", error: "ArgumentError", msg: "boom")
    end

    it "starts no next worker after a restart a stop landed on, and drops its reminders hand-off" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
      carry = File.join(dir, Samagotchi::ReminderCarry::FILE)
      worker = instance_double(Samagotchi::Worker, scratch?: false, discard?: false)
      allow(worker).to receive(:run) do
        # The stop's marker and its file remove, then the hand-off written as the worker left.
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
        File.write(carry, "{}")
        :restart
      end
      allow(Samagotchi::Worker).to receive(:new).and_return(worker)
      allow(described_class).to receive(:resume_session)

      expect(Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir)).to eq(:restart)
      expect(described_class).not_to have_received(:resume_session)
      expect(File.exist?(carry)).to be(false)
      expect(Samagotchi::Session.stopped_marker?(session.id, state_dir: tmpdir)).to be(true)
    end

    it "starts a new worker after an idle exit when delegate reports wait to wake it, not when they were held back" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      allow(described_class).to receive(:resume_session)
      [true, false].each do |due|
        worker = instance_double(Samagotchi::Worker, scratch?: false, run: :idle_exit, discard?: false, wake_due?: due)
        allow(Samagotchi::Worker).to receive(:new).and_return(worker)
        Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir)
      end
      expect(described_class).to have_received(:resume_session).once
    end

    # Lifecycle P10: a stop that lands as the worker leaves (after its last
    # pass) wins for every way out, not only a restart: the successor's
    # resume would clear it. Its input and rings stay for the next start.
    it "starts no next worker for input or rings when a stop landed as it left, however it left" do
      allow(described_class).to receive(:resume_session)
      allow(described_class).to receive(:delete_session)
      { idle_exit: nil, exit_requested: nil, signal: 0 }.each do |result, status|
        session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
        session.save(state_dir: tmpdir)
        described_class.write_turn_input(session.id, client_id: nil, prompt: "queued", state_dir: tmpdir)
        worker = instance_double(Samagotchi::Worker, scratch?: false, discard?: true, wake_due?: true)
        allow(worker).to receive(:run) do
          Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
          result
        end
        allow(Samagotchi::Worker).to receive(:new).and_return(worker)

        if status
          expect { Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir) }
            .to raise_error(SystemExit) { |e| expect(e.status).to eq(status) }
        else
          expect(Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir)).to eq(result)
        end
        dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
        expect(Samagotchi::SessionInbox.find_new_input_files(dir).size).to eq(1), result.to_s
        expect(Samagotchi::Session.stopped_marker?(session.id, state_dir: tmpdir)).to be(true), result.to_s
      end
      expect(described_class).not_to have_received(:resume_session)
      expect(described_class).not_to have_received(:delete_session)
    end

    it "deletes a chi scratch session as its worker leaves, however it leaves, and resumes nothing" do
      allow(described_class).to receive(:resume_session)
      { scratch_left: nil, idle_exit: nil, signal: 0, stopped: 0 }.each do |result, status|
        session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp", scratch: true)
        session.save(state_dir: tmpdir)
        described_class.write_turn_input(session.id, client_id: nil, prompt: "queued", state_dir: tmpdir)
        allow(Samagotchi::Worker).to receive(:new)
          .and_return(instance_double(Samagotchi::Worker, scratch?: true, run: result, discard?: false, wake_due?: true))

        if status
          expect { Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir) }
            .to raise_error(SystemExit) { |e| expect(e.status).to eq(status) }
        else
          expect(Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir)).to eq(result)
        end
        expect(Samagotchi::Session.exist?(session.id, state_dir: tmpdir)).to be(false), result.to_s
      end
      expect(described_class).not_to have_received(:resume_session)
    end

    it "exits 0 after a signal stopped the worker, logging stop reason=signal, with no discard, nor a resume with nothing queued" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      log = File.join(tmpdir, "chi.log")
      Samagotchi::Config.reload!(cli_overrides: { "log.file" => log })
      worker = instance_double(Samagotchi::Worker, scratch?: false, run: :signal, discard?: true, wake_due?: true)
      allow(Samagotchi::Worker).to receive(:new).and_return(worker)
      allow(described_class).to receive(:resume_session)
      allow(described_class).to receive(:delete_session)

      expect { Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

      stop = File.open(log) { |io| Samagotchi::LogLine.each_record(io).find { |r| r.event == "stop" } }
      expect(stop.fields).to include("reason" => "signal")
      expect(described_class).not_to have_received(:resume_session)
      expect(described_class).not_to have_received(:delete_session)
    ensure
      Samagotchi::Config.reload!(cli_overrides: {})
    end

    it "wakes a new worker after a signal when input is queued (behind the turn the signal stopped), once the lock is free" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      described_class.write_turn_input(session.id, client_id: nil, prompt: "queued", state_dir: tmpdir)
      allow(Samagotchi::Worker).to receive(:new).and_return(instance_double(Samagotchi::Worker, scratch?: false, run: :signal))
      owner_at_resume = :unset
      allow(described_class).to receive(:resume_session) do |id, state_dir:|
        owner_at_resume = described_class.session_owner(id, state_dir: state_dir)
      end

      expect { Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      expect(described_class).to have_received(:resume_session).with(session.id, state_dir: tmpdir)
      expect(owner_at_resume).to be_nil
    end

    it "restores the signal handlers once the worker's loop returned" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      allow(Samagotchi::Worker).to receive(:new)
        .and_return(instance_double(Samagotchi::Worker, scratch?: false, run: :idle_exit, discard?: false, wake_due?: false))
      allow_any_instance_of(Samagotchi::WorkerSignals).to receive(:install!) { |signals| signals }
      restored = []
      allow_any_instance_of(Samagotchi::WorkerSignals).to receive(:restore!) { |signals| restored << signals }
      ENV[described_class::WORKER_PROCESS_ENV] = "1"

      Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir)

      expect(restored.size).to eq(1)
    ensure
      ENV.delete(described_class::WORKER_PROCESS_ENV)
    end

    it "traps signals only in a spawned worker (WORKER_PROCESS_ENV, taken out of ENV), never in-process" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      given = []
      allow(Samagotchi::Worker).to receive(:new) do |**kwargs|
        given << kwargs[:signals]
        instance_double(Samagotchi::Worker, scratch?: false, run: :idle_exit, discard?: false, wake_due?: false)
      end
      installed = []
      allow_any_instance_of(Samagotchi::WorkerSignals).to receive(:install!) { |signals| (installed << signals).last }

      Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir)
      expect(given.last).to be(Samagotchi::WorkerSignals::NONE)
      expect(installed).to be_empty

      ENV[described_class::WORKER_PROCESS_ENV] = "1"
      Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir)
      expect(ENV.fetch(described_class::WORKER_PROCESS_ENV, nil)).to be_nil
      expect(installed.size).to eq(1)
      expect(given.last).to be(installed.first)
    ensure
      ENV.delete(described_class::WORKER_PROCESS_ENV)
    end

    it "leaves the spawner's process tree only when spawned (WORKER_DETACH_ENV, taken out of ENV), before the lock" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      allow(Samagotchi::Worker).to receive(:new)
        .and_return(instance_double(Samagotchi::Worker, scratch?: false, run: :idle_exit, discard?: false, wake_due?: false))
      order = []
      allow(Samagotchi::WorkerBoot).to receive(:detach_from_spawner) { order << :detach }
      allow(Samagotchi::OwnerLock).to receive(:acquire).and_wrap_original do |original, *args, **kwargs|
        order << :lock
        original.call(*args, **kwargs)
      end

      Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir)
      expect(order).to eq([:lock])

      ENV[described_class::WORKER_DETACH_ENV] = "1"
      Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir)
      expect(order).to eq(%i[lock detach lock])
      expect(ENV.fetch(described_class::WORKER_DETACH_ENV, nil)).to be_nil
    ensure
      ENV.delete(described_class::WORKER_DETACH_ENV)
    end

    # In a process of its own (a fork standing for the spawned worker
    # process), never the rspec process: its child runs on, reparented, in
    # a session of its own, and it exits once that child holds the lock.
    it "detaches: the worker is forked, setsid, reparented, and its starter exits once it holds the lock" do
      skip "fork unavailable" unless Process.respond_to?(:fork)

      dir = File.join(tmpdir, "detach-session")
      FileUtils.mkdir_p(dir)
      reader, writer = IO.pipe
      starter = fork do
        reader.close
        Samagotchi::WorkerBoot.send(:detach_from_spawner, dir)
        # The worker (the starter's child) from here on.
        starter_pid = Process.ppid
        writer.puts("worker #{Process.pid} sid #{Process.getsid} starter #{Process.ppid}")
        sleep 0.3 # sleep-ok: still starting: the starter waits
        lock = Samagotchi::OwnerLock.acquire(dir, kind: "worker", wait: 0)
        writer.puts("locked #{Process.clock_gettime(Process::CLOCK_MONOTONIC)}")
        # wait-ok: the parent checks the ppid this then reports
        wait_until(interval: 0.05) { Process.ppid != starter_pid }
        writer.puts("reparented #{Process.ppid}")
        writer.close
        lock&.release
        exit!(0)
      end
      writer.close
      _, status = Timeout.timeout(10) { Process.wait2(starter) } # timeout-ok: a hang guard: the starter exits by itself
      starter_exited = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      lines = Timeout.timeout(10) { reader.read.lines.map(&:split) } # timeout-ok: a hang guard: the read ends when the children close the pipe

      worker, = lines.assoc("worker").values_at(1)
      expect(status.exitstatus).to eq(0)
      expect(lines.assoc("worker")).to eq(["worker", worker, "sid", worker, "starter", starter.to_s])
      expect(starter_exited).to be >= Float(lines.assoc("locked")[1])
      expect(lines.assoc("reparented")[1]).not_to eq(starter.to_s)
    ensure
      reader&.close
    end

    it "logs a worker crash with its backtrace (its stderr is /dev/null) and re-raises" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      log = File.join(tmpdir, "chi.log")
      Samagotchi::Config.reload!(cli_overrides: { "log.file" => log })
      worker = instance_double(Samagotchi::Worker, scratch?: false)
      allow(worker).to receive(:run).and_raise(NoMethodError, "undefined method 'x'")
      allow(Samagotchi::Worker).to receive(:new).and_return(worker)

      expect { Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir) }
        .to raise_error(NoMethodError)

      records = File.open(log) { |io| Samagotchi::LogLine.each_record(io).to_a }
      expect(records.map(&:event)).to eq(%w[start crashed])
      expect(records.last.to_h).to include(level: "ERROR", tag: "worker", sid: session.id[0, 8])
      expect(records.last.fields).to include("error" => "NoMethodError")
      expect(records.last.payload.lines.size).to be_between(1, 20)
    ensure
      Samagotchi::Config.reload!(cli_overrides: {})
    end

    it "initializes Engine with supported keywords" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      # Stopped before this worker took it: it leaves at once.
      Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)

      engine = instance_double(Samagotchi::Engine, announce_participants: nil, command_registry: Samagotchi::SessionCommands.builtin_registry, peer_sources: nil, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, warm_toolkit_suggestion!: nil, "interface=": nil, "participant_stop=": nil, recap: nil, "recap_awaiting_continue=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, "next_turn_waiting=": nil, due_reminder_names: [], "session=": nil)
      expect(Samagotchi::Engine).to receive(:new)
        .with(hash_including(model_name: "gemma4"))
        .and_return(engine)

      allow(engine).to receive(:start_idle)
      allow(engine).to receive(:stop_idle)
      allow(engine).to receive(:reminder_store).and_return(nil)
      allow(engine).to receive_messages(turn_running?: false, last_activity_at: 0.0)
      # The worker always starts its Bridge, which subscribes a capture observer.
      sub_handle = double("subscribe_handle")
      allow(sub_handle).to receive(:unsubscribe)
      allow(engine).to receive(:subscribe).and_return(sub_handle)

      expect do
        Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir)
      end.to raise_error(SystemExit)
    end

    it "leaves the idle recap to the config (the web and attached UIs show :recap_ready)" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      # Stopped before this worker took it: it leaves at once.
      Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)

      engine = instance_double(Samagotchi::Engine, announce_participants: nil, command_registry: Samagotchi::SessionCommands.builtin_registry, peer_sources: nil, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, warm_toolkit_suggestion!: nil, "interface=": nil, "participant_stop=": nil, recap: nil, "recap_awaiting_continue=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, "next_turn_waiting=": nil, due_reminder_names: [], "session=": nil, start_idle: nil, stop_idle: nil, reminder_store: nil,
                                              turn_running?: false, last_activity_at: 0.0)
      expect(Samagotchi::Engine).to receive(:new) do |**kwargs|
        expect(kwargs).not_to have_key(:recap)
        engine
      end
      allow(engine).to receive(:subscribe).and_return(double("subscribe_handle", unsubscribe: nil))

      expect do
        Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir)
      end.to raise_error(SystemExit)
    end

    it "hands the Engine its session before any turn, so a joining UI sees the history" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.messages = [{ role: "user", content: "earlier" }, { role: "model", content: "reply" }]
      session.save(state_dir: tmpdir)

      engine = instance_double(Samagotchi::Engine, announce_participants: nil, command_registry: Samagotchi::SessionCommands.builtin_registry, peer_sources: nil, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, warm_toolkit_suggestion!: nil, "interface=": nil, "participant_stop=": nil, recap: nil, "recap_awaiting_continue=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, "next_turn_waiting=": nil, due_reminder_names: [], start_idle: nil, stop_idle: nil, reminder_store: nil,
                                              turn_running?: false, last_activity_at: 0.0)
      allow(engine).to receive(:subscribe).and_return(double("subscribe_handle", unsubscribe: nil))
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
      given = nil
      allow(engine).to receive(:session=) { |s| given = s }
      bridge_started = false
      allow_any_instance_of(Samagotchi::Worker).to receive(:start_bridge) do
        bridge_started = true
        expect(given).not_to be_nil
        nil
      end
      allow(Samagotchi::SessionInbox).to receive(:find_new_input_files) do
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
        []
      end

      expect do
        Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir, poll_interval: 0.01)
      end.to raise_error(SystemExit)

      expect(bridge_started).to be(true)
      expect(given.id).to eq(session.id)
      expect(given.messages.map { |m| m[:content] || m["content"] }).to eq(%w[earlier reply])
    end

    it "wires a reminder callback that notes the due reminders for a reminder turn, with no input file" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      # Stopped before this worker took it: it leaves at once.
      Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)

      engine = instance_double(Samagotchi::Engine, announce_participants: nil, command_registry: Samagotchi::SessionCommands.builtin_registry, peer_sources: nil, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, warm_toolkit_suggestion!: nil, "interface=": nil, "participant_stop=": nil, recap: nil, "recap_awaiting_continue=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, "next_turn_waiting=": nil, due_reminder_names: [], "session=": nil)
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

      expect do
        Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir)
      end.to raise_error(SystemExit)

      expect(engine).to receive(:note_due_reminders).with(["daily"])
      expect { reminder_callback.call(["daily"]) }.not_to raise_error
      input_dir = File.join(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), Samagotchi::SessionInbox::INPUT_DIR)
      expect(Dir.glob(File.join(input_dir, "*"))).to be_empty
    end

    it "atomically claims an input file for single-consumer processing" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session_dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
      input_dir = File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR)
      FileUtils.mkdir_p(input_dir)

      input_file = File.join(input_dir, "20260101000000000000000.txt")
      File.write(input_file, "ping")

      claimed = Samagotchi::SessionInbox.claim_input_file(input_file)

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

      engine = instance_double(Samagotchi::Engine, announce_participants: nil, command_registry: Samagotchi::SessionCommands.builtin_registry, peer_sources: nil, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, warm_toolkit_suggestion!: nil, "interface=": nil, "participant_stop=": nil, recap: nil, "recap_awaiting_continue=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, "next_turn_waiting=": nil, due_reminder_names: [], "session=": nil, messages_checkpoint: [])
      result = instance_double(Samagotchi::LLM::ModelResult, output: "hi", canceled?: false, resumable?: false)
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
        .with(instance_of(Samagotchi::Session), "hello", pending_input: kind_of(Proc), input_waiting: kind_of(Method), origin: Samagotchi::TurnOrigin::NONE, id: kind_of(String), max_iterations: Samagotchi::IterationLimit::DEFAULT, images: []) do
          Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
          result
        end

      expect do
        Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir)
      end.to raise_error(SystemExit)
    end

    it "does not replay the last prompt when resuming a session with history" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.messages = [{ role: "user", content: "earlier" }, { role: "model", content: "answer" }]
      session.last_prompt = "earlier"
      session.save(state_dir: tmpdir)

      engine = instance_double(Samagotchi::Engine, announce_participants: nil, command_registry: Samagotchi::SessionCommands.builtin_registry, peer_sources: nil, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, warm_toolkit_suggestion!: nil, "interface=": nil, "participant_stop=": nil, recap: nil, "recap_awaiting_continue=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, "next_turn_waiting=": nil, due_reminder_names: [], "session=": nil)
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
      allow(engine).to receive(:start_idle)
      allow(engine).to receive(:reminder_store).and_return(nil)
      allow(engine).to receive_messages(turn_running?: false, last_activity_at: 0.0)
      sub_handle = double("subscribe_handle")
      allow(sub_handle).to receive(:unsubscribe)
      allow(engine).to receive(:subscribe).and_return(sub_handle)
      expect(engine).not_to receive(:run_turn)
      # Stop on the first poll so the loop exits.
      allow(Samagotchi::SessionInbox).to receive(:find_new_input_files) do
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
        []
      end

      expect do
        Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir, poll_interval: 0.01)
      end.to raise_error(SystemExit)
      expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).last_prompt).to eq("earlier")
    end
  end
end
