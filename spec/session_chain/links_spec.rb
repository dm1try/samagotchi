# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/session_chain/links"

# The one chain walker: SessionChain.latest/.next_of, SessionInbox::Head and
# Schedules' tick all ask one of these.
RSpec.describe Samagotchi::SessionChain::Links do
  let(:tmpdir) { Dir.mktmpdir("chain-links") }
  let(:clock) { [Time.utc(2026, 11, 10, 12)] }

  after { FileUtils.rm_rf(tmpdir) }

  def links = described_class.new(state_dir: tmpdir)

  # Each link a second after the last: created_at decides a fork.
  def link(continues: nil, archived: false)
    clock[0] += 1
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w", continues: continues,
                                    now: clock[0]).tap do |s|
      s.save(state_dir: tmpdir)
      Samagotchi::ArchiveStore.archive(s.id, state_dir: tmpdir) if archived
    end
  end

  def rewrite_continues(session, to)
    session.continues = to
    session.save(state_dir: tmpdir)
  end

  it "gives a fork's earliest created successor, archived or not" do
    first = link
    early = link(continues: first.id, archived: true)
    late = link(continues: first.id)

    walker = links
    expect(walker.next_of(first.id)).to eq(early.id)
    expect(walker.latest(first.id)).to eq(early.id)
    expect(walker.next_of(late.id)).to be_nil
  end

  it "ends a loop a hand-edited file made where it would repeat" do
    first = link(archived: true)
    second = link(continues: first.id, archived: true)
    rewrite_continues(first, second.id)

    walker = links
    expect(walker.latest(first.id)).to eq(second.id)
    expect(walker.latest(second.id)).to eq(first.id)
    expect(walker.first_live(first.id)).to eq(second.id)
    expect(walker.root(second.id)).to eq(first.id)
  end

  it "stops a walk at a deleted middle link: nothing lists it as continued" do
    first = link(archived: true)
    middle = link(continues: first.id, archived: true)
    last = link(continues: middle.id)
    FileUtils.rm_f(Samagotchi::Session.session_file(middle.id, state_dir: tmpdir))

    walker = links
    expect(walker.gone?(middle.id)).to be(true)
    expect(walker.latest(first.id)).to eq(first.id)
    expect(walker.first_live(first.id)).to eq(first.id)
    expect(walker.latest(last.id)).to eq(last.id)
  end

  it "reaches the first live link with first_live and the end with latest" do
    first = link(archived: true)
    second = link(continues: first.id)
    third = link(continues: second.id)

    walker = links
    expect(walker.first_live(first.id)).to eq(second.id)
    expect(walker.latest(first.id)).to eq(third.id)
    expect(walker.first_live(second.id)).to eq(second.id)
  end

  it "goes to the end with first_live when every link is archived" do
    first = link(archived: true)
    second = link(continues: first.id, archived: true)

    walker = links
    expect(walker.first_live(first.id)).to eq(second.id)
    expect(walker.latest(first.id)).to eq(second.id)
    expect(walker.archived?(second.id)).to be(true)
  end

  it "names a deleted root by its id from every link after it" do
    root = link(archived: true)
    second = link(continues: root.id, archived: true)
    third = link(continues: second.id)
    FileUtils.rm_f(Samagotchi::Session.session_file(root.id, state_dir: tmpdir))

    walker = links
    expect(walker.root(third.id)).to eq(root.id)
    expect(walker.root(second.id)).to eq(root.id)
    expect(walker.continues(second.id)).to eq(root.id)
    expect(walker.continues(root.id)).to be_nil
  end

  it "answers archived? for a live id without listing, and lists once for every walk" do
    first = link(archived: true)
    second = link(continues: first.id)
    walker = links

    expect(Samagotchi::Session).not_to receive(:list)
    expect(walker.archived?(second.id)).to be(false)
    expect(walker.first_live(second.id)).to eq(second.id)

    RSpec::Mocks.space.proxy_for(Samagotchi::Session).reset
    expect(Samagotchi::Session).to receive(:list).once.and_call_original
    expect(walker.first_live(first.id)).to eq(second.id)
    expect(walker.latest(first.id)).to eq(second.id)
    expect(walker.root(second.id)).to eq(first.id)
  end

  it "takes an id that is no session id as not archived" do
    expect(links.archived?("../etc")).to be(false)
  end

  describe "#chain and #live_links" do
    it "runs root to end from any link" do
      first = link(archived: true)
      second = link(continues: first.id, archived: true)
      third = link(continues: second.id)

      walker = links
      [first, second, third].each do |from|
        expect(walker.chain(from.id)).to eq([first.id, second.id, third.id])
      end
      expect(walker.live_links(second.id)).to eq([first.id, second.id, third.id])
    end

    it "keeps a gone root's id in #chain and drops it from #live_links" do
      root = link(archived: true)
      second = link(continues: root.id)
      FileUtils.rm_f(Samagotchi::Session.session_file(root.id, state_dir: tmpdir))

      walker = links
      expect(walker.chain(second.id)).to eq([root.id, second.id])
      expect(walker.live_links(second.id)).to eq([second.id])
    end

    it "ends at a gap: the links before a deleted middle link are not reached from after it" do
      first = link(archived: true)
      middle = link(continues: first.id, archived: true)
      last = link(continues: middle.id)
      FileUtils.rm_f(Samagotchi::Session.session_file(middle.id, state_dir: tmpdir))

      walker = links
      expect(walker.chain(last.id)).to eq([middle.id, last.id])
      expect(walker.live_links(last.id)).to eq([last.id])
      expect(walker.chain(first.id)).to eq([first.id])
    end

    it "follows the asked link's own branch of a fork" do
      first = link(archived: true)
      early = link(continues: first.id)
      late = link(continues: first.id)

      walker = links
      expect(walker.chain(late.id)).to eq([first.id, late.id])
      expect(walker.chain(early.id)).to eq([first.id, early.id])
      expect(walker.chain(first.id)).to eq([first.id, early.id])
    end

    it "ends a loop where it would repeat" do
      first = link(archived: true)
      second = link(continues: first.id, archived: true)
      rewrite_continues(first, second.id)

      walker = links
      expect(walker.chain(first.id)).to eq([first.id, second.id])
      expect(walker.chain(second.id)).to eq([second.id, first.id])
    end

    it "is the id alone for an id nobody lists" do
      expect(links.chain("0" * 32)).to eq(["0" * 32])
    end
  end
end
