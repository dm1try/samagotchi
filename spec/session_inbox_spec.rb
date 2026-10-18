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

    it "writes delivery only for queue: a step-boundary or cut message adds no key" do
      plain = described_class.write_input(session_dir, prompt: "hi")
      cut = described_class.write_input(session_dir, prompt: "hi", delivery: "cut")

      expect(JSON.parse(File.read(plain))).not_to have_key("delivery")
      expect(JSON.parse(File.read(cut))).not_to have_key("delivery")
    end

    it "round-trips a queued message" do
      path = described_class.write_input(session_dir, prompt: "later", client_id: "cli:send", delivery: "queue")

      expect(JSON.parse(File.read(path))["delivery"]).to eq("queue")
      expect(described_class.read_input(path))
        .to eq(described_class::Input.new(prompt: "later", origin: { client_id: "cli:send" }, delivery: "queue"))
    end

    it "reads an old file that carries no delivery as a step-boundary message" do
      FileUtils.mkdir_p(input_dir)
      old = File.join(input_dir, "20260101000000000000000.json")
      File.write(old, JSON.generate({ "prompt" => "hi", "client_id" => "web:1" }))

      expect(described_class.read_input(old)).to eq(described_class::Input.new(prompt: "hi", origin: { client_id: "web:1" }))
    end

    it "reads a file that holds JSON but no object (an array, a number, null) as an unreadable one" do
      FileUtils.mkdir_p(input_dir)
      ["[1,2]", "5", "null", '"hi"'].each_with_index do |json, i|
        path = File.join(input_dir, "2026010100000000000000#{i}.json")
        File.write(path, json)

        expect(described_class.read_input(path)).to eq(described_class::UNREADABLE_INPUT)
      end
    end

    describe ".waits_for_turn_end?" do
      it "answers true for an image message and a queued one, false for a plain or cut line" do
        with_images = described_class.write_input(session_dir, prompt: "look", images: [{ file: "a.png", name: "a" }])
        queued = described_class.write_input(session_dir, prompt: "later", delivery: Samagotchi::Delivery::QUEUE)
        text = described_class.write_input(session_dir, prompt: "hi")
        cut = described_class.write_input(session_dir, prompt: "now", delivery: Samagotchi::Delivery::CUT)

        expect(described_class.waits_for_turn_end?(with_images)).to be(true)
        expect(described_class.waits_for_turn_end?(queued)).to be(true)
        expect(described_class.waits_for_turn_end?(text)).to be(false)
        expect(described_class.waits_for_turn_end?(cut)).to be(false)
      end

      it "answers false for a file it cannot read" do
        FileUtils.mkdir_p(input_dir)
        broken = File.join(input_dir, "20260101000000000000001.json")
        File.write(broken, "not json")

        expect(described_class.waits_for_turn_end?(broken)).to be(false)
      end
    end

    describe ".take_queued_input" do
      def write(prompt, id, **options)
        described_class.write_input(session_dir, prompt: prompt, client_id: "tui:1", enqueued_id: id, **options)
      end

      it "takes back a queued input: the file goes, its tombstone stays, and it answers what it held" do
        write("first", "id-1", delivery: "queue")
        write("second", "id-2", delivery: "queue")

        status, input = described_class.take_queued_input(session_dir, "id-2")

        expect(status).to eq(:removed)
        expect(input.prompt).to eq("second")
        expect(described_class.find_new_input_files(session_dir).map { |f| JSON.parse(File.read(f))["prompt"] }).to eq(["first"])
        expect(Dir.glob(File.join(input_dir, "*.processing"))).to eq([])
        expect(described_class.removed?(session_dir, "id-2")).to be(true)
        expect(described_class.removed?(session_dir, "id-1")).to be(false)
      end

      it "takes an image message too (it waits for the turn's end as well)" do
        write("look", "id-img", images: [{ file: "a.png", name: "a" }])

        expect(described_class.take_queued_input(session_dir, "id-img").first).to eq(:removed)
      end

      it "warns when writing a removal tombstone fails but still removes the queued input" do
        write("later", "id-1", delivery: "queue")
        error = Errno::EACCES.new("tombstone")
        allow(Samagotchi::AtomicFile).to receive(:write).and_raise(error)
        allow(Samagotchi::Log).to receive(:warn)

        status, input = described_class.take_queued_input(session_dir, "id-1")

        expect([status, input.prompt]).to eq([:removed, "later"])
        expect(described_class.find_new_input_files(session_dir)).to be_empty
        expect(Samagotchi::Log).to have_received(:warn).with(:bridge, "removed_tombstone_write_failed",
                                                             error: "Errno::EACCES", msg: error.message)
      end

      it "leaves a next-step file where it is: a running turn's drain may merge it any moment" do
        path = write("now", "id-plain")

        expect(described_class.take_queued_input(session_dir, "id-plain")).to eq([:not_queued, nil])
        expect(File.exist?(path)).to be(true)
        expect(described_class.removed?(session_dir, "id-plain")).to be(false)
      end

      it "answers :claimed when a turn took the file (renamed to .processing), :none for an unknown id" do
        path = write("later", "id-1", delivery: "queue")
        described_class.claim_input_file(path)

        expect(described_class.take_queued_input(session_dir, "id-1")).to eq([:claimed, nil])
        expect(described_class.take_queued_input(session_dir, "nope")).to eq([:none, nil])
        expect(described_class.take_queued_input(session_dir, "")).to eq([:none, nil])
        expect(described_class.removed?(session_dir, "id-1")).to be(false)
      end

      it "answers :claimed when the drain wins the rename after the file was read" do
        path = write("later", "id-1", delivery: "queue")
        allow(described_class).to receive(:claim_input_file).with(path).and_return(nil)

        expect(described_class.take_queued_input(session_dir, "id-1")).to eq([:claimed, nil])
      end

      it "writes no tombstone for an id unsafe in a file name" do
        write("later", "../x", delivery: "queue")

        expect(described_class.take_queued_input(session_dir, "../x").first).to eq(:removed)
        expect(described_class.removed?(session_dir, "../x")).to be(false)
        expect(Dir.exist?(File.join(input_dir, described_class::REMOVED_DIR))).to be(false)
      end
    end
  end

  describe "reply files" do
    let(:session_dir) { File.join(tmpdir, "s") }
    let(:output_dir) { File.join(session_dir, described_class::OUTPUT_DIR) }

    it "names a turn's reply by time, with its input's enqueued_id when it has one; the names still sort by time" do
      described_class.write_output(session_dir, "bare")
      sleep(0.002)
      described_class.write_output(session_dir, "mine", enqueued_id: "1b2c-3d")
      sleep(0.002)
      described_class.write_output(session_dir, "odd id", enqueued_id: "../x")

      names = Dir.children(output_dir).sort
      expect(names.map { |n| File.read(File.join(output_dir, n)) }).to eq(["bare", "mine", "odd id"])
      expect(names[0]).to match(/\A\d{23}\.txt\z/)
      expect(names[1]).to match(/\A\d{23}-1b2c-3d\.txt\z/)
      expect(names[2]).to match(/\A\d{23}\.txt\z/)
      # Same timestamp: "-" sorts before ".", the id'd name first.
      expect(["20261013000000000000001.txt", "20261013000000000000001-a.txt"].max).to eq("20261013000000000000001.txt")
      expect(described_class.read_outputs(session_dir)).to eq(["bare", "mine", "odd id"])
    end

    it "finds the reply of one input's turn" do
      expect(described_class.reply_for(session_dir, "q1")).to be_nil
      described_class.write_output(session_dir, "other", enqueued_id: "q2")
      expect(described_class.reply_for(session_dir, "q1")).to be_nil
      described_class.write_output(session_dir, "mine", enqueued_id: "q1")
      expect(File.read(File.join(output_dir, described_class.reply_for(session_dir, "q1")))).to eq("mine")
      expect(described_class.reply_for(session_dir, nil)).to be_nil
    end

    it "says how an input with an enqueued_id still waits unclaimed: for the turn's end, to merge, or not at all" do
      expect(described_class.waiting_input(session_dir, "q1")).to be_nil
      path = described_class.write_input(session_dir, prompt: "later", enqueued_id: "q1", delivery: "queue")
      described_class.write_input(session_dir, prompt: "other", enqueued_id: "q2")
      expect(described_class.waiting_input(session_dir, "q1")).to eq(:turn_end)
      expect(described_class.waiting_input(session_dir, nil)).to be_nil

      described_class.claim_input_file(path)
      expect(described_class.waiting_input(session_dir, "q1")).to be_nil
      expect(described_class.waiting_input(session_dir, "q2")).to eq(:merges)
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
      big = "a" * ((16 * 1024) + 1)
      expect { described_class.write_note(session.id, text: big, state_dir: tmpdir) }
        .to raise_error(described_class::NoteRejected, /16 KiB/)
      expect(described_class.write_note(session.id, text: "a" * (16 * 1024), state_dir: tmpdir)).to be_a(String)
    end

    it "counts bytes, not characters" do
      expect { described_class.write_note(session.id, text: "ж" * ((8 * 1024) + 1), state_dir: tmpdir) }
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
