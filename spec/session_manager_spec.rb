
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
      loaded = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      expect(loaded.status).to eq(Samagotchi::Session::STATUS_RUNNING)
    end
  end

  describe ".spawn_session" do
    it "spawns worker with explicit require for session manager" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      allow(Samagotchi::Session).to receive(:new_session).and_return(session)
      spawned_args = nil
      allow(Process).to receive(:spawn) do |*args|
        spawned_args = args
        12_345
      end

      described_class.spawn_session(prompt: "hello", mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      expect(Process).to have_received(:spawn).with(
        RbConfig.ruby,
        "-I", anything,
        "-e", include("require 'samagotchi/session_manager'; Samagotchi::SessionManager.run_session_loop") ,
        out: File::NULL,
        err: File::NULL
      )

      lib_path_index = spawned_args.index("-I") + 1
      expect(spawned_args[lib_path_index]).to end_with("/lib")
      expect(File.directory?(spawned_args[lib_path_index])).to be true

      pid_file = File.join(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), Samagotchi::SessionManager::PID_FILE)
      expect(File.read(pid_file)).to eq("12345")
    end
  end

  describe ".run_session_loop" do
    it "initializes Engine with supported keywords" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.status = Samagotchi::Session::STATUS_STOPPED
      session.save(state_dir: tmpdir)

      engine = instance_double(Samagotchi::Engine)
      expect(Samagotchi::Engine).to receive(:new)
        .with(mode: :assist, model_name: "gemma4")
        .and_return(engine)

      allow(engine).to receive(:start_reminders)
      allow(engine).to receive(:stop_reminders)
      allow(engine).to receive(:reminder_store).and_return(nil)

      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir)
      }.to raise_error(SystemExit)
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

      engine = instance_double(Samagotchi::Engine)
      result = instance_double(Samagotchi::KernelLoop::Result, output: "hi")
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
      allow(engine).to receive(:start_reminders)
      allow(engine).to receive(:stop_reminders)
      allow(engine).to receive(:reminder_store).and_return(nil)
      expect(engine).to receive(:run_turn)
        .with(instance_of(Samagotchi::Session), "hello") do
          Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
          result
        end

      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir)
      }.to raise_error(SystemExit)
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

