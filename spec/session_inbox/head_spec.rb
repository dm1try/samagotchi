# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/session_inbox"
require "samagotchi/archive_store"

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

  it "pins send, push and a fresh verdict to the id named" do
    first = link(archived: true)
    link(continues: first.id)

    %i[send push fresh_verdict].each do |kind|
      expect(resolve(kind, first)).to eq(id: first.id, asked: first.id, via: :pinned)
    end
  end
end
