# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/session_chain/links"

# The one chain walker: SessionChain.latest/.next_of, SessionInbox::Head and
# Schedules' tick all ask one of these.
RSpec.describe Samagotchi::SessionChain::Links do
  # The sessions dir under a root of its own: a schedules file lives in the
  # sessions dir's parent, never the shared temp dir.
  let(:root) { Dir.mktmpdir("chain-links") }
  let(:tmpdir) { File.join(root, "sessions").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:clock) { [Time.utc(2026, 11, 10, 12)] }

  after { FileUtils.rm_rf(root) }

  def links(**opts) = described_class.new(state_dir: tmpdir, **opts)

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

  # A schedule's prune deletes the anchor's successor: nothing continues the
  # anchor any more, so the addressing walks (#latest, #first_live,
  # #anchor_forward) bridge the gap to the schedule's head; the graph walks
  # (#next_of, #chain, #root) stay raw.
  describe "a pruned anchor" do
    # A→B→C→D with B deleted; A and C archived, D live.
    def pruned_chain
      a = link(archived: true)
      b = link(continues: a.id, archived: true)
      c = link(continues: b.id, archived: true)
      d = link(continues: c.id)
      FileUtils.rm_rf(Samagotchi::Session.session_dir(b.id, state_dir: tmpdir))
      FileUtils.rm_f(Samagotchi::Session.session_file(b.id, state_dir: tmpdir))
      [a, c, d]
    end

    it "forwards latest, first_live and anchor_forward to the schedule's head; next_of and chain stay raw" do
      a, c, d = pruned_chain
      walker = links(anchor_heads: { a.id => [d.id] })

      expect(walker.latest(a.id)).to eq(d.id)
      expect(walker.first_live(a.id)).to eq(d.id)
      expect(walker.anchor_forward(a.id)).to eq(d.id)
      expect(walker.next_of(a.id)).to be_nil
      expect(walker.chain(a.id)).to eq([a.id])
      expect(walker.live_links(a.id)).to eq([a.id])
      expect(walker.root(d.id)).not_to eq(a.id)
      expect(walker.chain(c.id).last).to eq(d.id)
    end

    it "walks on from a head a later continue left behind" do
      a, c, d = pruned_chain
      walker = links(anchor_heads: { a.id => [c.id] })

      expect(walker.latest(a.id)).to eq(d.id)
      expect(walker.first_live(a.id)).to eq(d.id)
      expect(walker.anchor_forward(a.id)).to eq(c.id)
    end

    it "keeps today's dead end without an entry, with a gone head, or with the head the anchor itself" do
      a, = pruned_chain
      gone = "0" * 32
      [{}, { a.id => [gone] }, { a.id => [a.id] }].each do |heads|
        walker = links(anchor_heads: heads)
        expect(walker.latest(a.id)).to eq(a.id)
        expect(walker.first_live(a.id)).to eq(a.id)
        expect(walker.anchor_forward(a.id)).to be_nil
      end
    end

    it "takes the first listed head of several entries on one anchor" do
      a, _c, d = pruned_chain

      expect(links(anchor_heads: { a.id => ["0" * 32, a.id, d.id] }).latest(a.id)).to eq(d.id)
    end

    it "never forwards an anchor that is not archived" do
      a = link
      other = link

      walker = links(anchor_heads: { a.id => [other.id] })
      expect(walker.latest(a.id)).to eq(a.id)
      expect(walker.anchor_forward(a.id)).to be_nil
    end

    it "ends a loop through the bridge where it would repeat" do
      a, c, d = pruned_chain
      archived = link(continues: d.id, archived: true)
      Samagotchi::ArchiveStore.archive(d.id, state_dir: tmpdir)
      # A hand edit: the chain's archived end anchors a schedule whose head is
      # the anchor, so the bridges make a loop.
      walker = links(anchor_heads: { a.id => [c.id], archived.id => [a.id] })

      expect(walker.latest(a.id)).to eq(archived.id)
      expect(walker.latest(archived.id)).to eq(d.id)
    end

    it "reads no schedules for a live id or a link with a successor" do
      first = link(archived: true)
      second = link(continues: first.id)
      heads = instance_double(Hash)
      expect(heads).not_to receive(:[])
      expect(heads).not_to receive(:fetch)

      walker = links(anchor_heads: heads)
      expect(walker.first_live(second.id)).to eq(second.id)
      expect(walker.latest(first.id)).to eq(second.id)
      expect(walker.first_live(first.id)).to eq(second.id)
    end

    it "lists nothing for a live id" do
      live = link
      expect(Samagotchi::Session).not_to receive(:list)

      expect(links.first_live(live.id)).to eq(live.id)
    end
  end
end
