# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/session_inbox"
require "samagotchi/archive_store"
require "json"

# Which link of a chain a delivery goes to.
RSpec.describe Samagotchi::SessionInbox::Head do
  let(:tmpdir) { Dir.mktmpdir("inbox-head") }

  after { FileUtils.rm_rf(tmpdir) }

  def link(continues: nil, archived: false)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w", continues: continues).tap do |s|
      s.save(state_dir: tmpdir)
      Samagotchi::ArchiveStore.archive(s.id, state_dir: tmpdir) if archived
    end
  end

  def resolve(kind, session) = described_class.resolve(kind, session.id, state_dir: tmpdir).to_h

  it "keeps an id that isn't archived, without listing the sessions" do
    one = link
    expect(Samagotchi::Session).not_to receive(:list)

    expect(resolve(:note, one)).to eq(id: one.id, asked: one.id, via: :same)
    expect(resolve(:ring, one)).to eq(id: one.id, asked: one.id, via: :same)
  end

  it "follows an archived link to its successor" do
    first = link(archived: true)
    second = link(continues: first.id)

    expect(resolve(:note, first)).to eq(id: second.id, asked: first.id, via: :head)
    expect(resolve(:ring, first)).to eq(id: second.id, asked: first.id, via: :head)
  end

  it "keeps an archived link nobody continues" do
    alone = link(archived: true)

    expect(resolve(:note, alone)).to eq(id: alone.id, asked: alone.id, via: :same)
  end

  it "walks a 3-link chain to its head, and a ring one hop, to the link that reads its file" do
    first = link(archived: true)
    second = link(continues: first.id, archived: true)
    third = link(continues: second.id)

    expect(resolve(:note, first)).to eq(id: third.id, asked: first.id, via: :head)
    expect(resolve(:ring, first)).to eq(id: second.id, asked: first.id, via: :head)
    expect(resolve(:note, second)).to eq(id: third.id, asked: second.id, via: :head)
  end

  it "stops at the first link not archived" do
    first = link(archived: true)
    second = link(continues: first.id)
    link(continues: second.id)

    expect(resolve(:note, first)).to eq(id: second.id, asked: first.id, via: :head)
  end

  it "ends a loop a hand-edited file made where it started over" do
    first = link(archived: true)
    second = link(continues: first.id, archived: true)
    looped = Samagotchi::Session.load(first.id, state_dir: tmpdir)
    looped.continues = second.id
    looped.save(state_dir: tmpdir)

    expect(resolve(:note, first)).to eq(id: second.id, asked: first.id, via: :head)
  end

  it "follows a send to the chain's newest link, as a note; pins push and a fresh verdict to the id named" do
    first = link(archived: true)
    second = link(continues: first.id)

    expect(resolve(:send, first)).to eq(id: second.id, asked: first.id, via: :head)
    %i[push fresh_verdict].each do |kind|
      expect(resolve(kind, first)).to eq(id: first.id, asked: first.id, via: :pinned)
    end
  end

  # SessionContinue.run_locked writes the previous link's intent (its
  # successor's id) under the continue's lock before it archives the link,
  # and saves the successor only after: a send in that gap would find no
  # successor and un-archive the link.
  describe "a continue in flight" do
    def intent(session, successor, locked: true)
      dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, Samagotchi::ContinueIntent::FILE), JSON.generate(successor_id: successor))
      return unless locked

      @lock = File.open(File.join(dir, Samagotchi::ContinueIntent::LOCK), File::RDWR | File::CREAT, 0o600)
      @lock.flock(File::LOCK_EX)
    end

    after { @lock&.close }

    let(:successor) { "7b2d41aa-0000-4000-8000-000000000000" }

    it "gives a send the successor not saved yet, via :continuing, archived or not yet" do
      archived = link(archived: true)
      intent(archived, successor)
      expect(resolve(:send, archived)).to eq(id: successor, asked: archived.id, via: :continuing)

      @lock.close
      live = link
      intent(live, successor)
      expect(resolve(:send, live)).to eq(id: successor, asked: live.id, via: :continuing)
    end

    it "is the walk's end it checks: a send to an earlier link waits for the last one's continue too" do
      first = link(archived: true)
      second = link(continues: first.id)
      intent(second, successor)

      expect(resolve(:send, first)).to eq(id: successor, asked: first.id, via: :continuing)
    end

    it "leaves a note in the link: the continue moves it, the new link's worker adopts a later one (NoteMove)" do
      archived = link(archived: true)
      intent(archived, successor)

      expect(resolve(:note, archived)).to eq(id: archived.id, asked: archived.id, via: :same)
    end

    it "is over once the successor is saved: the walk reaches it" do
      first = link(archived: true)
      second = link(continues: first.id)
      intent(first, second.id)

      expect(resolve(:send, first)).to eq(id: second.id, asked: first.id, via: :head)
    end

    it "ignores a stale intent, one no continue holds the lock of (a crash's, repair_interrupted's to undo)" do
      archived = link(archived: true)
      intent(archived, successor, locked: false)

      expect(resolve(:send, archived)).to eq(id: archived.id, asked: archived.id, via: :same)
    end

    it "ignores an intent that isn't JSON or names no valid id" do
      archived = link(archived: true)
      intent(archived, "../elsewhere")
      expect(resolve(:send, archived)).to eq(id: archived.id, asked: archived.id, via: :same)

      File.write(File.join(Samagotchi::Session.session_dir(archived.id, state_dir: tmpdir), Samagotchi::ContinueIntent::FILE), "{")
      expect(resolve(:send, archived)).to eq(id: archived.id, asked: archived.id, via: :same)
    end
  end
end
