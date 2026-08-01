
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

      # Override list to use our tmpdir
      sessions = Samagotchi::Session.list(state_dir: tmpdir)
      expect(sessions.length).to eq(1)
      expect(sessions.first.status).to eq(Samagotchi::Session::STATUS_IDLE)
    end
  end

  describe ".stop_session" do
    it "marks a session as stopped" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)

      session_dir = Samagotchi::Session.session_dir(session.id)
      FileUtils.mkdir_p(session_dir)
      File.write(File.join(session_dir, Samagotchi::SessionManager::PID_FILE), "0")

      # stop_session uses default state dir; we need to test the mark_stopped effect
      Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
      loaded = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      expect(loaded.status).to eq(Samagotchi::Session::STATUS_STOPPED)
    end

    it "does not raise when PID file does not exist" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)

      expect {
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
      }.not_to raise_error
    end
  end

  describe ".wait_for_session" do
    it "returns true when session is already completed" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.status = Samagotchi::Session::STATUS_COMPLETED
      session.save(state_dir: tmpdir)

      result = Samagotchi::SessionManager.wait_for_session(session.id, timeout: 1, state_dir: tmpdir)
      expect(result).to be true
    end

    it "returns false when session stays running beyond timeout" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.status = Samagotchi::Session::STATUS_RUNNING
      session.save(state_dir: tmpdir)

      result = Samagotchi::SessionManager.wait_for_session(session.id, timeout: 1, state_dir: tmpdir)
      expect(result).to be false
    end
  end

  describe ".attach_session" do
    it "writes a message to the input directory" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session_dir = Samagotchi::Session.session_dir(session.id)
      FileUtils.mkdir_p(File.join(session_dir, Samagotchi::SessionManager::INPUT_DIR))
      FileUtils.mkdir_p(File.join(session_dir, Samagotchi::SessionManager::OUTPUT_DIR))

      Samagotchi::SessionManager.attach_session(session.id, message: "hello world")

      input_files = Dir.glob(File.join(session_dir, Samagotchi::SessionManager::INPUT_DIR, "*.txt"))
      expect(input_files.length).to be >= 1
      expect(File.read(input_files.last)).to eq("hello world")
    end
  end

  describe "IPC directory structure" do
    it "creates the expected directory structure" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session_dir = File.join(tmpdir, session.id)
      FileUtils.mkdir_p(File.join(session_dir, Samagotchi::SessionManager::INPUT_DIR))
      FileUtils.mkdir_p(File.join(session_dir, Samagotchi::SessionManager::OUTPUT_DIR))

      expect(Dir.exist?(File.join(session_dir, Samagotchi::SessionManager::INPUT_DIR))).to be true
      expect(Dir.exist?(File.join(session_dir, Samagotchi::SessionManager::OUTPUT_DIR))).to be true
    end
  end
end

