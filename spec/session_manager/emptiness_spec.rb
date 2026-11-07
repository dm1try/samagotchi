# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/worker_link"
require "samagotchi/engine"
require "samagotchi/session_manager"
require "samagotchi/bridge"
require "samagotchi/reminder_store"
require_relative "../support/session_manager_context"

RSpec.describe Samagotchi::SessionManager do
  include_context "session manager files"

  describe ".empty_session?" do
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
        s.save(state_dir: tmpdir)
      end
    end
    let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }

    def empty?(default_model: "gemma4")
      described_class.empty_session?(session.id, state_dir: tmpdir, default_model: default_model)
    end

    def change(&)
      yield(session)
      session.save(state_dir: tmpdir)
    end

    before do
      %w[input output notes images].each { |sub| FileUtils.mkdir_p(File.join(session_dir, sub)) }
      %w[pid owner.lock bridge.json].each { |name| File.write(File.join(session_dir, name), "") }
      File.write(File.join(session_dir, "analytics.json"), JSON.generate("turns" => 0, "turn_records" => []))
      File.write(File.join(session_dir, "output", "1.txt"), "")
    end

    it "is true for a fresh session on the default model, its directory the worker's skeleton" do
      expect(empty?).to be true
    end

    it "is false with no session file" do
      FileUtils.rm_f(File.join(tmpdir, "#{session.id}.json"))

      expect(empty?).to be false
    end

    it "is still true when the only message is a turn note (a first turn that failed before any answer)" do
      change { |s| s.messages << Samagotchi::TurnNote.message("the previous turn failed before any answer") }

      expect(empty?).to be true
    end

    it "is false once a context note is in the conversation" do
      change { |s| s.messages << { role: "system", content: "[note]", kind: "note" } }

      expect(empty?).to be false
    end

    it "is true with only the system prompt saved, false with a context note" do
      change { |s| s.messages << { role: "system", content: "You are chi." } }
      expect(empty?).to be true

      change { |s| s.messages << { role: "system", kind: "note", content: "from slack" } }
      expect(empty?).to be false
    end

    it "is false with a conversation" do
      change { |s| s.messages << { role: "user", content: "hi" } }

      expect(empty?).to be false
    end

    # 0 messages, but turns that failed: a last_prompt and analytics turns.
    it "is false after a failed turn" do
      change { |s| s.last_prompt = "can you see this?" }

      expect(empty?).to be false
    end

    it "is false when analytics recorded a turn" do
      File.write(File.join(session_dir, "analytics.json"), JSON.generate("turns" => 1, "turn_records" => [{ "id" => "t1" }]))

      expect(empty?).to be false
    end

    it "is false with a first prompt waiting for the worker" do
      change { |s| s.first_preview = "hello" }

      expect(empty?).to be false
    end

    it "is false on a model other than the default (/model, --model)" do
      expect(empty?(default_model: "qwen36")).to be false
    end

    it "is false with no default model to compare with" do
      expect(empty?(default_model: nil)).to be false
    end

    it "is false with memory attached or a question pending" do
      change { |s| s.used_memory_names = ["notes"] }
      expect(empty?).to be false

      change do |s|
        s.used_memory_names = []
        s.pending_question = { question: "which?" }
      end
      expect(empty?).to be false
    end

    it "is false with queued input, a note or an image" do
      %w[input notes images].each do |sub|
        path = File.join(session_dir, sub, "1.json")
        File.write(path, "{}")
        expect(empty?).to be(false), sub
        FileUtils.rm_f(path)
      end
      expect(empty?).to be true
    end

    it "is false with anything else in its directory" do
      File.write(File.join(session_dir, "approvals.json"), "{}")

      expect(empty?).to be false
    end

    it "is false for an unknown or unreadable session" do
      File.write(File.join(tmpdir, "#{session.id}.json"), "{")

      expect(empty?).to be false
      expect(described_class.empty_session?("nope", state_dir: tmpdir, default_model: "gemma4")).to be false
    end

    # A wrong-shape (not a number) reads as "not empty": no raise, kept.
    it "is false for a wrong-shape cards.json (turns an array, a hash) or analytics.json (turn_records a hash)" do
      File.write(File.join(session_dir, "cards.json"), JSON.generate("turns" => []))
      expect(described_class.empty_session_dir?(session_dir)).to be false
      File.write(File.join(session_dir, "cards.json"), JSON.generate("turns" => {}))
      expect(described_class.empty_session_dir?(session_dir)).to be false
      File.write(File.join(session_dir, "analytics.json"), JSON.generate("turn_records" => {}))
      expect(described_class.empty_session_dir?(session_dir)).to be false
    end
  end

  describe ".discard_empty?" do
    it "is on unless session.keep_empty is set" do
      expect(described_class.discard_empty?).to be true

      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("session.keep_empty").and_return(true)
      expect(described_class.discard_empty?).to be false
    end

    it "keeps sessions when the setting can't be read, and logs it" do
      allow(Samagotchi::Log).to receive(:warn)
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("session.keep_empty").and_raise(ArgumentError, "bad yaml")

      expect(described_class.discard_empty?).to be false
      expect(Samagotchi::Log).to have_received(:warn).with(:config, "keep_empty_unreadable", hash_including(error: "ArgumentError"))
    end
  end
end
