# frozen_string_literal: true

require "samagotchi/context_note"

RSpec.describe Samagotchi::ContextNote do
  let(:at) { Time.local(2026, 9, 24, 14, 2, 30).iso8601 }

  describe ".message" do
    it "frames a note as a system message marked kind: note" do
      message = described_class.message(note_id: "n1", text: "deploy frozen", source: "slack", created_at: at)

      expect(message).to eq(role: "system", kind: "note", note_id: "n1", source: "slack",
                            content: "[CONTEXT NOTE from slack, 14:02]\ndeploy frozen\n[END NOTE]")
    end

    it "names the sending session by its short id and folder" do
      message = described_class.message(note_id: "n2", text: "api moved", source: "session", created_at: at,
                                        from_session: "3f2a1c00-aaaa-bbbb", from_cwd: File.join(Dir.home, "projects/foo"))

      expect(message[:content]).to start_with("[CONTEXT NOTE from session 3f2a1c (~/projects/foo), 14:02]\n")
      expect(message).to include(from_session: "3f2a1c00-aaaa-bbbb", from_cwd: File.join(Dir.home, "projects/foo"))
    end

    it "leaves the time out when the note has none" do
      message = described_class.message(note_id: "n3", text: "x", source: "cli", created_at: nil)
      expect(message[:content]).to start_with("[CONTEXT NOTE from cli]\n")
    end
  end

  describe ".note?" do
    it "knows a note by its kind, with symbol or string keys" do
      expect(described_class.note?({ role: "system", kind: "note" })).to be true
      expect(described_class.note?({ "role" => "system", "kind" => "note" })).to be true
      expect(described_class.note?({ role: "system", content: "[SYSTEM: REMINDERS DUE]" })).to be false
    end
  end

  describe ".with_system_head" do
    let(:head) { { role: "system", content: "new prompt" } }
    let(:note) { { role: "system", kind: "note", content: "[CONTEXT NOTE from cli]\nx\n[END NOTE]" } }

    it "starts an empty conversation with the system prompt" do
      expect(described_class.with_system_head([], head)).to eq([head])
    end

    it "replaces an old system prompt at the head" do
      messages = [{ role: "system", content: "old" }, { role: "user", content: "hi" }]
      expect(described_class.with_system_head(messages, head)).to eq([head, { role: "user", content: "hi" }])
    end

    it "keeps a note at the head and puts the system prompt before it" do
      expect(described_class.with_system_head([note], head)).to eq([head, note])
    end

    it "puts the system prompt before a conversation that has none" do
      messages = [{ role: "user", content: "hi" }]
      expect(described_class.with_system_head(messages, head)).to eq([head, { role: "user", content: "hi" }])
    end

    it "leaves the given array alone" do
      messages = [{ role: "system", content: "old" }]
      described_class.with_system_head(messages, head)
      expect(messages).to eq([{ role: "system", content: "old" }])
    end
  end
end
