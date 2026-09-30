# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/session_inbox"

RSpec.describe Samagotchi::SessionInbox do
  let(:tmpdir) { Dir.mktmpdir("session-inbox-spec") }

  after { FileUtils.rm_rf(tmpdir) }

  describe ".checked_text" do
    it "names what it checks in its errors, a note by default" do
      expect { described_class.checked_text(" \n") }.to raise_error(described_class::NoteRejected, "the note is empty")
      expect { described_class.checked_text("", noun: "message") }.to raise_error(described_class::NoteRejected, "the message is empty")
      big = "x" * (described_class::NOTE_MAX_BYTES + 1)
      expect { described_class.checked_text(big, noun: "message") }
        .to raise_error(described_class::NoteRejected, "the message is 16385 bytes; the limit is 16 KiB (16384 bytes)")
    end

    it "answers the text stripped" do
      expect(described_class.checked_text("  hi\n", noun: "message")).to eq("hi")
    end
  end

  describe "input files" do
    let(:session_dir) { Samagotchi::Session.session_dir("abc", state_dir: tmpdir) }
    let(:input_dir) { File.join(session_dir, described_class::INPUT_DIR) }

    it "does not read a plain-text input file" do
      FileUtils.mkdir_p(input_dir)
      File.write(File.join(input_dir, "1.txt"), "hi")

      expect(described_class.find_new_input_files(session_dir)).to eq([])
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
end
