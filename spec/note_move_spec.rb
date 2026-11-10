# frozen_string_literal: true

require "json"
require "time"
require "tmpdir"
require "spec_helper"
require "samagotchi/note_move"
require "samagotchi/archive_store"
require "samagotchi/objectives"

# NoteMove: a continue moves the previous link's notes to the new one, a
# failed continue gives them back, and the new link's worker adopts a
# straggler written to the previous link after the move.
RSpec.describe Samagotchi::NoteMove do
  let(:tmpdir) { Dir.mktmpdir("note-move") }
  let(:now) { Time.now }

  after { FileUtils.rm_rf(tmpdir) }

  def make(continues: nil, created: now)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w", continues: continues,
                                    now: created).tap { |s| s.save(state_dir: tmpdir, now: created) }
  end

  def dir_of(id) = Samagotchi::Session.session_dir(id, state_dir: tmpdir)
  def names(id) = Samagotchi::SessionInbox.find_new_note_files(dir_of(id)).map { |f| File.basename(f) }
  def texts(id) = Samagotchi::SessionInbox.find_new_note_files(dir_of(id)).map { |f| JSON.parse(File.read(f))["text"] }

  def note(id, text, at: now, **)
    Samagotchi::SessionInbox.write_note(id, text: text, state_dir: tmpdir, now: at, **)
  end

  def list_note(id, at: now)
    list = Samagotchi::Objectives::List.new.add("Aim")
    note(id, list.text, at: at, source: Samagotchi::Objectives::SOURCE, objectives: list.to_payload)
  end

  describe ".move" do
    it "moves the notes, names kept, a claimed one un-claimed, and leaves objectives lists and the link's own continue notes" do
      from = make
      to = make(continues: from.id)
      first = File.basename(note(from.id, "one", at: now - 2))
      second = File.basename(note(from.id, "two", at: now - 1))
      claimed = File.basename(note(from.id, "claimed", at: now - 3))
      Samagotchi::SessionInbox.claim_note_file(File.join(dir_of(from.id), "notes", claimed))
      list_note(from.id)
      # A link continued before it ever started still holds its own.
      note(from.id, "its chain note", at: now - 9, source: Samagotchi::SessionChain::NOTE_SOURCE)
      note(from.id, "its context note", at: now - 8, source: Samagotchi::ContextMove::NOTE_SOURCE)
      allow(Samagotchi::Log).to receive(:info).and_call_original

      moved = described_class.move(from: from.id, to: to.id, state_dir: tmpdir)

      expect(moved).to eq([claimed, first, second])
      expect(names(to.id)).to eq([claimed, first, second])
      expect(texts(from.id)).to eq(["its chain note", "its context note", "O1 Aim"])
      expect(Samagotchi::Log).to have_received(:info).with(:worker, "notes_moved_claimed", hash_including(count: 1))
    end

    it "moves nothing from a link with no notes/" do
      expect(described_class.move(from: make.id, to: make.id, state_dir: tmpdir)).to eq([])
    end
  end

  describe ".give_back" do
    it "returns the moved notes and the ones sent meanwhile, never the continue's own" do
      from = make
      to = make(continues: from.id)
      note(from.id, "waiting", at: now - 5)
      moved = described_class.move(from: from.id, to: to.id, state_dir: tmpdir)
      note(to.id, "chain", source: Samagotchi::SessionChain::NOTE_SOURCE)
      note(to.id, "context", source: Samagotchi::ContextMove::NOTE_SOURCE)
      list_note(to.id)
      note(to.id, "sent to the new link meanwhile", at: now + 1, source: "slack")

      described_class.give_back(from: to.id, to: from.id, moved: moved, state_dir: tmpdir)

      expect(texts(from.id)).to eq(["waiting", "sent to the new link meanwhile"])
      expect(texts(to.id)).to contain_exactly("chain", "context", "O1 Aim")
    end

    it "returns a moved claimed note by its un-claimed name" do
      from = make
      to = make(continues: from.id)
      Samagotchi::SessionInbox.claim_note_file(note(from.id, "claimed"))
      moved = described_class.move(from: from.id, to: to.id, state_dir: tmpdir)

      described_class.give_back(from: to.id, to: from.id, moved: moved, state_dir: tmpdir)

      expect(names(from.id)).to eq(moved)
    end
  end

  describe ".adoption" do
    let(:from) { make(created: now - 3600).tap { |s| Samagotchi::ArchiveStore.archive(s.id, state_dir: tmpdir) } }
    let(:head) { make(continues: from.id) }

    def adoption = described_class.adoption(Samagotchi::Session.load(head.id, state_dir: tmpdir), state_dir: tmpdir)

    it "takes a note written to the archived predecessor after the new link, on each call" do
      taker = adoption
      name = File.basename(note(from.id, "straggler", at: now))

      expect(taker.call).to eq([name])
      expect([names(from.id), names(head.id)]).to eq([[], [name]])

      later = File.basename(note(from.id, "another", at: now + 5))
      expect(taker.call).to eq([later])
    end

    it "leaves notes from before the new link (a continue before this one moved none), objectives lists and claimed ones" do
      note(from.id, "ten days old", at: now - (10 * 24 * 3600))
      note(from.id, "an hour before", at: now - 1800)
      list_note(from.id, at: now + 1)
      Samagotchi::SessionInbox.claim_note_file(note(from.id, "claimed", at: now + 2))
      allow(Samagotchi::Log).to receive(:info).and_call_original

      taker = adoption
      expect(taker.call).to eq([])
      expect(taker.call).to eq([])

      expect(texts(from.id)).to eq(["ten days old", "an hour before", "O1 Aim", "claimed"])
      expect(Samagotchi::Log).to have_received(:info).with(:worker, "notes_left_old", any_args).once
    end

    it "takes a note in the same second as the new link (a writer that resolved the id just before it was saved)" do
      head
      name = File.basename(note(from.id, "raced", at: Time.at(Time.iso8601(Samagotchi::Session.load(head.id, state_dir: tmpdir).created_at).to_i)))

      expect(adoption.call).to eq([name])
    end

    it "takes none from a predecessor back in the lists (input un-archived it): its notes are its own" do
      taker = adoption
      Samagotchi::ArchiveStore.unarchive(from.id, state_dir: tmpdir)
      note(from.id, "its own", at: now + 1)

      expect(taker.call).to eq([])
    end

    it "takes from every archived link back along the chain, each from the link that continued it on" do
      first = make(created: now - 7200).tap { |s| Samagotchi::ArchiveStore.archive(s.id, state_dir: tmpdir) }
      middle = make(continues: first.id, created: now - 3600).tap { |s| Samagotchi::ArchiveStore.archive(s.id, state_dir: tmpdir) }
      last = make(continues: middle.id)
      before_middle = note(first.id, "older than the middle link", at: now - 5000)
      after_middle = File.basename(note(first.id, "an older chi wrote it to the first link", at: now - 1800))
      straggler = File.basename(note(middle.id, "a straggler", at: now))

      adopted = described_class.adoption(Samagotchi::Session.load(last.id, state_dir: tmpdir), state_dir: tmpdir).call

      expect(adopted).to contain_exactly(after_middle, straggler)
      expect(names(last.id)).to eq([after_middle, straggler])
      expect(names(first.id)).to eq([File.basename(before_middle)])
    end

    it "stops the walk at a link back in the lists" do
      first = make(created: now - 7200).tap { |s| Samagotchi::ArchiveStore.archive(s.id, state_dir: tmpdir) }
      middle = make(continues: first.id, created: now - 3600)
      last = make(continues: middle.id)
      Samagotchi::ArchiveStore.archive(middle.id, state_dir: tmpdir)
      taker = described_class.adoption(Samagotchi::Session.load(last.id, state_dir: tmpdir), state_dir: tmpdir)
      Samagotchi::ArchiveStore.unarchive(middle.id, state_dir: tmpdir)
      note(first.id, "beyond it", at: now)

      expect(taker.call).to eq([])
    end

    it "is nil for a first link, and for one the predecessor's next_of isn't (a later fork of it)" do
      expect(described_class.adoption(make, state_dir: tmpdir)).to be_nil
      head
      other = make(continues: from.id, created: now + 10)
      expect(described_class.adoption(other, state_dir: tmpdir)).to be_nil
    end
  end
end
