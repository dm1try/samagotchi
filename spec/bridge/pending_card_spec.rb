# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "samagotchi/bridge/pending_card"

# The running turn's open card with actions, as pending_card.json in the
# session's folder (the web hub's "needs you").
RSpec.describe Samagotchi::Bridge::PendingCard do
  subject(:pending) { described_class.new(dir) }

  let(:dir) { Dir.mktmpdir("pending-card-spec") }
  let(:path) { File.join(dir, described_class::FILE) }

  after { FileUtils.rm_rf(dir) }

  def card(id, actions: [{ label: "Nudge", command: "/checkin nudge" }], in_turn: true)
    { type: :card, id: id, source: "check-in", title: "t", body: "", level: :info, actions: actions, in_turn: in_turn }
  end

  it "writes a running turn's card with actions, and removes it when the card comes back without them" do
    pending.call(card("c1"))
    expect(described_class.read(dir)).to eq(id: "c1", bundle: "check-in")
    pending.call(card("c1", actions: []))
    expect(File.exist?(path)).to be(false)
    expect(described_class.read(dir)).to be_nil
  end

  it "removes it when the turn ends, however it ends" do
    %i[turn_completed turn_canceled turn_failed].each do |type|
      pending.call(card("c1"))
      pending.call({ type: type })
      expect(File.exist?(path)).to be(false), "after #{type}"
    end
  end

  it "never writes a card without actions or a card between turns" do
    pending.call(card("warn", actions: []))
    pending.call(card("btw", in_turn: false))
    expect(File.exist?(path)).to be(false)
  end

  it "leaves the open card alone for another card's update" do
    pending.call(card("c1"))
    pending.call(card("other", actions: []))
    expect(described_class.read(dir)).to eq(id: "c1", bundle: "check-in")
  end

  it "clears a file a dead worker left" do
    File.write(path, '{"id":"old","bundle":"check-in"}')
    pending.clear
    expect(File.exist?(path)).to be(false)
  end
end
