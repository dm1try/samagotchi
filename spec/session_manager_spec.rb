
# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/session_manager"

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

  describe ".attach_session" do
    it "writes a message to the input directory" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      session_dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
      FileUtils.mkdir_p(File.join(session_dir, Samagotchi::SessionManager::INPUT_DIR))
      FileUtils.mkdir_p(File.join(session_dir, Samagotchi::SessionManager::OUTPUT_DIR))
      allow(Process).to receive(:spawn).and_return(10_001)

      described_class.attach_session(session.id, message: "hello world", state_dir: tmpdir)

      input_files = Dir.glob(File.join(session_dir, Samagotchi::SessionManager::INPUT_DIR, "*.txt"))
      expect(input_files.length).to be >= 1
      expect(File.read(input_files.last)).to eq("hello world")
    end

    it "ignores empty messages" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      session_dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
      FileUtils.mkdir_p(File.join(session_dir, Samagotchi::SessionManager::INPUT_DIR))

      responses = described_class.attach_session(session.id, message: "   ", state_dir: tmpdir)

      input_files = Dir.glob(File.join(session_dir, Samagotchi::SessionManager::INPUT_DIR, "*.txt"))
      expect(responses).to eq([])
      expect(input_files).to be_empty
    end

    it "auto-resumes idle sessions by spawning a worker" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.status = Samagotchi::Session::STATUS_IDLE
      session.save(state_dir: tmpdir)
      allow(Process).to receive(:spawn).and_return(20_002)

      described_class.attach_session(session.id, message: "wake up", state_dir: tmpdir)

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
      engine = instance_double(Samagotchi::Engine, "session=": nil, start_idle: nil, stop_idle: nil, reminder_store: nil)
      allow(engine).to receive(:subscribe).and_return(double("subscribe_handle", unsubscribe: nil))
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
      expect(engine).not_to receive(:run_turn)

      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir)
      }.to raise_error(SystemExit)
    end

    it "records the worker as owner, with its own pid, while it runs" do
      engine = instance_double(Samagotchi::Engine, "session=": nil, start_idle: nil, stop_idle: nil, reminder_store: nil)
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
        described_class.run_session_loop(session.id, state_dir: tmpdir)
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

      engine = instance_double(Samagotchi::Engine, "session=": nil)
      expect(Samagotchi::Engine).to receive(:new)
        .with(hash_including(mode: :assist, model_name: "gemma4"))
        .and_return(engine)

      allow(engine).to receive(:start_idle)
      allow(engine).to receive(:stop_idle)
      allow(engine).to receive(:reminder_store).and_return(nil)
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

      engine = instance_double(Samagotchi::Engine, "session=": nil, start_idle: nil, stop_idle: nil, reminder_store: nil)
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

      engine = instance_double(Samagotchi::Engine, start_idle: nil, stop_idle: nil, reminder_store: nil)
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
        described_class.run_session_loop(session.id, state_dir: tmpdir)
      }.to raise_error(SystemExit)

      expect(bridge_started).to be(true)
      expect(given.id).to eq(session.id)
      expect(given.messages.map { |m| m[:content] || m["content"] }).to eq(%w[earlier reply])
    end

    it "wires a reminder callback that queues a synthetic turn in the session's state dir" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.status = Samagotchi::Session::STATUS_STOPPED
      session.save(state_dir: tmpdir)

      engine = instance_double(Samagotchi::Engine, "session=": nil)
      reminder_callback = nil
      allow(Samagotchi::Engine).to receive(:new) do |**kwargs|
        reminder_callback = kwargs.dig(:reminders, :callback)
        engine
      end
      allow(engine).to receive(:start_idle)
      allow(engine).to receive(:stop_idle)
      allow(engine).to receive(:reminder_store).and_return(nil)
      sub_handle = double("subscribe_handle")
      allow(sub_handle).to receive(:unsubscribe)
      allow(engine).to receive(:subscribe).and_return(sub_handle)

      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir)
      }.to raise_error(SystemExit)

      expect { reminder_callback.call(["daily"]) }.not_to raise_error
      input_dir = File.join(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), Samagotchi::SessionManager::INPUT_DIR)
      queued = Dir.glob(File.join(input_dir, "*.json"))
      expect(queued.size).to eq(1)
      input = JSON.parse(File.read(queued.first))
      expect(input["prompt"]).to include("scheduled reminders are due")
      expect(input["client_id"]).to eq("system:reminder")
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

      engine = instance_double(Samagotchi::Engine, "session=": nil)
      result = instance_double(Samagotchi::KernelLoop::Result, output: "hi")
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
      allow(engine).to receive(:start_idle)
      allow(engine).to receive(:stop_idle)
      allow(engine).to receive(:reminder_store).and_return(nil)
      # The worker always starts its Bridge, which subscribes a capture observer.
      sub_handle = double("subscribe_handle")
      allow(sub_handle).to receive(:unsubscribe)
      allow(engine).to receive(:subscribe).and_return(sub_handle)
      expect(engine).to receive(:run_turn)
        .with(instance_of(Samagotchi::Session), "hello", pending_input: kind_of(Proc), origin: nil) do
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

      engine = instance_double(Samagotchi::Engine, "session=": nil)
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
      allow(engine).to receive(:start_idle)
      allow(engine).to receive(:reminder_store).and_return(nil)
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
        described_class.run_session_loop(session.id, state_dir: tmpdir)
      }.to raise_error(SystemExit)
      expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).last_prompt).to eq("earlier")
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
      allow(engine).to receive(:subscribe).and_return(double("subscribe_handle", unsubscribe: nil))
      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir)
      }.to raise_error(SystemExit)
    end

    it "runs queued turns with their origin, text or JSON" do
      described_class.write_turn_input(session.id, prompt: "from web", client_id: "web:1", enqueued_id: "e1", state_dir: tmpdir)
      write_sidecar("port" => 1, "session_id" => session.id) # an old worker's sidecar: next write is .txt
      described_class.write_turn_input(session.id, prompt: "plain", state_dir: tmpdir)
      engine = instance_double(Samagotchi::Engine, "session=": nil)
      runs = []
      allow(engine).to receive(:run_turn) do |_session, prompt, origin:, **|
        runs << [prompt, origin]
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir) if runs.size == 2
        instance_double(Samagotchi::KernelLoop::Result, output: "")
      end

      run_worker_with(engine)

      expect(runs).to eq([["from web", { client_id: "web:1", enqueued_id: "e1" }], ["plain", nil]])
    end

    it "marks the session running on disk while a turn runs, and stops before the next queued turn" do
      described_class.write_turn_input(session.id, prompt: "one", state_dir: tmpdir)
      described_class.write_turn_input(session.id, prompt: "two", state_dir: tmpdir)
      engine = instance_double(Samagotchi::Engine, "session=": nil)
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
      engine = instance_double(Samagotchi::Engine, "session=": nil)
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
end

