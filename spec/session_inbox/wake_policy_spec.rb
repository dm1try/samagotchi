# frozen_string_literal: true

require "spec_helper"
require "samagotchi/session_inbox"
require "samagotchi/worker_presence"
require "samagotchi/owner_lock"

# The inbox's one table: what a delivery of each kind may do to a session's
# worker, from WorkerPresence values alone (no disk).
RSpec.describe Samagotchi::SessionInbox::WakePolicy do
  let(:worker) { Samagotchi::OwnerLock::Owner.new(pid: 1, kind: "worker", started_at: nil) }
  let(:tui) { Samagotchi::OwnerLock::Owner.new(pid: 1, kind: "tui", started_at: nil) }

  def presence(**facts)
    Samagotchi::WorkerPresence.new(session_id: "s", exists: true, owner: nil, stop_marked: false,
                                   starting_marked: false, archived: false, scratch: false, **facts)
  end

  # One column per presence: every kind's answer is read in each.
  def columns
    { gone: presence(exists: false), tui: presence(owner: tui), owned: presence(owner: worker),
      stopped: presence(stop_marked: true), archived: presence(archived: true), starting: presence(starting_marked: true),
      scratch: presence(scratch: true), idle: presence }
  end

  def row(kind) = columns.transform_values { |p| described_class.for(kind).decide(p) }

  describe "#decide" do
    it "lets send start a stopped or archived session, and hold off a start pending" do
      expect(row(:send)).to eq(gone: :gone, tui: :owned, owned: :live, stopped: :start, archived: :start,
                               starting: :starting, scratch: :scratch, idle: :start)
    end

    it "never lets a note start a worker" do
      expect(row(:note)).to eq(gone: :gone, tui: :owned, owned: :live, stopped: :stopped, archived: :archived,
                               starting: :starting, scratch: :none, idle: :none)
    end

    it "lets a push and a ring start an idle session only" do
      expected = { gone: :gone, tui: :owned, owned: :live, stopped: :stopped, archived: :archived, starting: :starting,
                   scratch: :scratch, idle: :start }
      expect(row(:push)).to eq(expected)
      expect(row(:ring)).to eq(expected)
    end

    it "never lets a fresh verdict start a worker" do
      expect(row(:fresh_verdict)).to eq(gone: :gone, tui: :owned, owned: :live, stopped: :stopped, archived: :archived,
                                        starting: :starting, scratch: :none, idle: :none)
    end

    it "reads the stop marker alone as stopped, never the file's status" do
      expect(described_class.for(:ring).decide(presence(turn_status: "stopped"))).to eq(:start)
      expect(described_class.for(:push).decide(presence(turn_status: "stopped"))).to eq(:start)
    end

    it "takes over a start marked before a stop for send only" do
      both = presence(stop_marked: true, starting_marked: true)

      expect(described_class.for(:send).decide(both)).to eq(:start)
      expect(described_class.for(:ring).decide(both)).to eq(:stopped)
    end

    it "answers :off when no worker was asked for, before reading the file" do
      load = -> { raise "read" }

      expect(described_class.for(:ring).decide(presence(scratch: nil), wake: false, load: load)).to eq(:off)
      expect(described_class.for(:push).decide(presence(owner: worker), wake: false)).to eq(:live)
    end

    it "reads the session file only to decide a start, after every marker" do
      load = -> { raise "read" }
      %i[gone tui owned stopped archived starting].each do |column|
        unloaded = columns.fetch(column).with(scratch: nil)
        expect { described_class.for(:ring).decide(unloaded, load: load) }.not_to raise_error, column.to_s
      end

      scratch = Struct.new(:scratch)
      expect(described_class.for(:ring).decide(presence(scratch: nil), load: -> { scratch.new(true) })).to eq(:scratch)
      expect(described_class.for(:ring).decide(presence(scratch: nil), load: -> { scratch.new(false) })).to eq(:start)
    end
  end

  describe "#refusal" do
    def refusals(kind) = columns.transform_values { |p| described_class.for(kind).refusal(p) }.compact

    it "refuses send and a note for a one-turn run's or a scratch session, and every kind for a gone one" do
      expect(refusals(:send)).to eq(gone: :gone, tui: :owned, scratch: :scratch)
      expect(refusals(:note)).to eq(gone: :gone, tui: :owned, scratch: :scratch)
      %i[push ring fresh_verdict].each { |kind| expect(refusals(kind)).to eq(gone: :gone) }
    end
  end

  it "has one row per kind, and only send un-stops or starts an archived link" do
    expect(described_class::ROWS.keys).to eq(%i[send note push ring fresh_verdict])
    expect(described_class::ROWS.values.select(&:unstops).map(&:kind)).to eq([:send])
    expect(described_class::ROWS.values.select(&:starts_archived).map(&:kind)).to eq([:send])
    expect(described_class::ROWS.transform_values(&:resolves))
      .to eq(send: :pinned, note: :head, push: :pinned, ring: :reader, fresh_verdict: :pinned)
    expect { described_class.for(:bogus) }.to raise_error(ArgumentError)
  end
end
