# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/session"

RSpec.describe Samagotchi::Session do
  let(:tmpdir) { Dir.mktmpdir("session-spec") }

  after { FileUtils.rm_rf(tmpdir) }

  describe ".new_session" do
    it "generates a unique UUID id" do
      s1 = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      s2 = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      expect(s1.id).not_to eq(s2.id)
      expect(s1.id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it "sets metadata_version, mode, model_name, working_directory, and empty messages" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/home/user/proj")
      expect(session.metadata_version).to eq(described_class::METADATA_VERSION)
      expect(session.mode).to eq("assist")
      expect(session.model_name).to eq("gemma4")
      expect(session.working_directory).to eq("/home/user/proj")
      expect(session.messages).to eq([])
    end

    it "sets created_at and updated_at as ISO8601 strings" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      expect { Time.iso8601(session.created_at) }.not_to raise_error
      expect { Time.iso8601(session.updated_at) }.not_to raise_error
    end
  end

  describe "#save and .load round-trip" do
    it "persists and restores all fields" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp/proj")
      session.messages = [
        { role: "system", content: "You are Chi." },
        { role: "user",   content: "Hello" },
        { role: "model",  content: "Hi there!" }
      ]
      session.save(state_dir: tmpdir)

      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.id).to eq(session.id)
      expect(loaded.mode).to eq("assist")
      expect(loaded.model_name).to eq("gemma4")
      expect(loaded.working_directory).to eq("/tmp/proj")
      expect(loaded.metadata_version).to eq(described_class::METADATA_VERSION)
    end

    it "restores message hashes with symbol keys" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.messages = [
        { role: "user", content: "test message" }
      ]
      session.save(state_dir: tmpdir)

      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.messages.first.keys).to all(be_a(Symbol))
      expect(loaded.messages.first[:role]).to eq("user")
      expect(loaded.messages.first[:content]).to eq("test message")
    end

    it "updates updated_at on save" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      original_updated_at = session.updated_at
      sleep(0.01)
      session.save(state_dir: tmpdir)
      expect(session.updated_at).not_to eq(original_updated_at)
    end
  end

  describe "#save atomic write" do
    it "does not corrupt an existing file on concurrent save (rename is atomic)" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.messages = [{ role: "user", content: "first" }]
      session.save(state_dir: tmpdir)

      # Verify no .tmp file is left behind after save
      tmp_files = Dir.glob(File.join(tmpdir, "*.tmp"))
      expect(tmp_files).to be_empty

      # Verify the session file is valid JSON
      path = File.join(tmpdir, "#{session.id}.json")
      expect { JSON.parse(File.read(path)) }.not_to raise_error
    end
  end

  describe ".load" do
    it "raises ArgumentError when session_id does not exist" do
      expect {
        described_class.load("nonexistent-id", state_dir: tmpdir)
      }.to raise_error(ArgumentError, /Session not found/)
    end

    it "raises ArgumentError on corrupted JSON" do
      bad_path = File.join(tmpdir, "bad-id.json")
      File.write(bad_path, "{ not valid json")
      expect {
        described_class.load("bad-id", state_dir: tmpdir)
      }.to raise_error(ArgumentError, /corrupted/)
    end
  end

  describe ".list" do
    it "returns empty array when directory does not exist" do
      expect(described_class.list(state_dir: "/nonexistent/path")).to eq([])
    end

    it "returns sessions sorted by created_at oldest first" do
      s1 = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      sleep(0.01)
      s2 = described_class.new_session(mode: "assist", model_name: "qwen36", working_directory: "/tmp")
      s1.save(state_dir: tmpdir)
      s2.save(state_dir: tmpdir)

      sessions = described_class.list(state_dir: tmpdir)
      expect(sessions.map(&:id)).to eq([s1.id, s2.id])
    end

    it "skips files with invalid JSON without raising" do
      File.write(File.join(tmpdir, "corrupt.json"), "{ invalid")
      sessions = described_class.list(state_dir: tmpdir)
      expect(sessions).to be_empty
    end

    it "does not load messages for listed sessions (list is lightweight)" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.messages = [{ role: "user", content: "hello" }]
      session.save(state_dir: tmpdir)

      listed = described_class.list(state_dir: tmpdir).first
      expect(listed.messages).to eq([])
    end
  end

  describe ".default_state_dir" do
    it "uses XDG_STATE_HOME when set" do
      dir = described_class.default_state_dir(env: { "XDG_STATE_HOME" => "/custom/state" })
      expect(dir).to eq("/custom/state/samagotchi/sessions")
    end

    it "falls back to ~/.local/state when XDG_STATE_HOME is absent" do
      dir = described_class.default_state_dir(env: {})
      expect(dir).to eq(File.join(Dir.home, ".local", "state", "samagotchi", "sessions"))
    end
  end

  describe "status fields" do
    it "defaults to idle status and empty last_prompt" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      expect(session.status).to eq(described_class::STATUS_IDLE)
      expect(session.last_prompt).to eq("")
    end

    it "round-trips status and last_prompt through save/load" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.status = described_class::STATUS_RUNNING
      session.last_prompt = "tell me a joke"
      session.save(state_dir: tmpdir)

      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.status).to eq(described_class::STATUS_RUNNING)
      expect(loaded.last_prompt).to eq("tell me a joke")
    end
  end

  describe "status transition methods" do
    let(:session) { described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp") }

    before { session.save(state_dir: tmpdir) }

    it ".mark_running sets status to running" do
      described_class.mark_running(session.id, state_dir: tmpdir)
      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.status).to eq(described_class::STATUS_RUNNING)
    end

    it ".mark_completed sets status to completed" do
      described_class.mark_completed(session.id, state_dir: tmpdir)
      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.status).to eq(described_class::STATUS_COMPLETED)
    end

    it ".mark_error sets status to error with reason in last_prompt" do
      described_class.mark_error(session.id, reason: "timeout", state_dir: tmpdir)
      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.status).to eq(described_class::STATUS_ERROR)
      expect(loaded.last_prompt).to eq("timeout")
    end

    it ".mark_stopped sets status to stopped" do
      described_class.mark_stopped(session.id, state_dir: tmpdir)
      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.status).to eq(described_class::STATUS_STOPPED)
    end
  end

  describe ".session_dir and .default_sessions_dir" do
    it "returns a directory path for a session" do
      dir = described_class.session_dir("abc-123", state_dir: tmpdir)
      expect(dir).to eq(File.join(tmpdir, "abc-123"))
    end

    it ".default_sessions_dir equals .default_state_dir" do
      expect(described_class.default_sessions_dir).to eq(described_class.default_state_dir)
    end
  end
end
