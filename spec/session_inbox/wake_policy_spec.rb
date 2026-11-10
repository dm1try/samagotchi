# frozen_string_literal: true

require "spec_helper"
require "samagotchi/session_inbox"
require "samagotchi/worker_presence"
require "samagotchi/owner_lock"

# The inbox's one table: what a delivery of each kind may do to a session's
# worker, from WorkerPresence values and a stand-in session file (no disk).
RSpec.describe Samagotchi::SessionInbox::WakePolicy do
  let(:worker) { Samagotchi::OwnerLock::Owner.new(pid: 1, kind: "worker", started_at: nil) }
  let(:tui) { Samagotchi::OwnerLock::Owner.new(pid: 1, kind: "tui", started_at: nil) }

  def presence(**facts)
    Samagotchi::WorkerPresence.new(session_id: "s", exists: true, owner: nil, stop_marked: false,
                                   starting_marked: false, archived: false, **facts)
  end

  # The session file as the policy reads it (its scratch flag), last.
  def file(scratch: false) = -> { Struct.new(:scratch).new(scratch) }

  # One column per presence and file: every kind's answer is read in each.
  def columns
    { gone: [presence(exists: false)], tui: [presence(owner: tui)], owned: [presence(owner: worker)],
      stopped: [presence(stop_marked: true)], archived: [presence(archived: true)],
      starting: [presence(starting_marked: true)], scratch: [presence, file(scratch: true)], idle: [presence] }
  end

  def row(kind) = columns.transform_values { |p, load| described_class.for(kind).decide(p, load: load || file) }

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

    # Pick 1 (R3): a turn delivery's unattended senders start an idle
    # session as a send does, but a stop and an archive are the owner's.
    it "lets an unattended sender start an idle session only" do
      %i[schedule plugin delegate participant automatic].each do |kind|
        expect(row(kind)).to eq(gone: :gone, tui: :owned, owned: :live, stopped: :stopped, archived: :archived,
                                starting: :starting, scratch: :scratch, idle: :start)
      end
    end

    # WorkerBoot's respawn as a worker leaves: a stop wins (P10), input
    # left in an archived session still starts it.
    it "lets a worker's leave start its successor unless a stop landed, or another worker is up or coming" do
      expect(row(:leave)).to eq(gone: :gone, tui: :owned, owned: :live, stopped: :stopped, archived: :start,
                                starting: :starting, scratch: :scratch, idle: :start)
    end

    it "takes over a start marked before a stop for send only" do
      both = presence(stop_marked: true, starting_marked: true)

      expect(described_class.for(:send).decide(both)).to eq(:start)
      expect(described_class.for(:ring).decide(both)).to eq(:stopped)
    end

    it "answers :off when no worker was asked for, before reading the file" do
      load = -> { raise "read" }

      expect(described_class.for(:ring).decide(presence, wake: false, load: load)).to eq(:off)
      expect(described_class.for(:push).decide(presence(owner: worker), wake: false)).to eq(:live)
    end

    it "reads the session file only to decide a start, after every marker" do
      load = -> { raise "read" }
      %i[gone tui owned stopped archived starting].each do |column|
        expect { described_class.for(:ring).decide(columns.fetch(column).first, load: load) }.not_to raise_error, column.to_s
      end

      expect(described_class.for(:ring).decide(presence, load: file(scratch: true))).to eq(:scratch)
      expect(described_class.for(:ring).decide(presence, load: file)).to eq(:start)
      expect(described_class.for(:ring).decide(presence)).to eq(:start)
    end
  end

  describe "#refusal" do
    def refusals(kind) = columns.transform_values { |p, load| described_class.for(kind).refusal(p, load: load || file) }.compact

    it "refuses send and a note for a one-turn run's or a scratch session, and every kind for a gone one" do
      expect(refusals(:send)).to eq(gone: :gone, tui: :owned, scratch: :scratch)
      expect(refusals(:note)).to eq(gone: :gone, tui: :owned, scratch: :scratch)
      %i[push ring fresh_verdict].each { |kind| expect(refusals(kind)).to eq(gone: :gone) }
      %i[schedule plugin delegate participant automatic].each do |kind|
        expect(refusals(kind)).to eq(gone: :gone, tui: :owned, scratch: :scratch)
      end
    end
  end

  it "has one row per kind, and only send un-stops; send and a worker's leave start an archived link" do
    expect(described_class::ROWS.keys)
      .to eq(%i[send note push ring fresh_verdict leave schedule plugin delegate participant automatic])
    expect(described_class::ROWS.values.select(&:unstops).map(&:kind)).to eq([:send])
    expect(described_class::ROWS.values.select(&:starts_archived).map(&:kind)).to eq(%i[send leave])
    expect(described_class::ROWS.transform_values(&:resolves))
      .to eq(send: :head, note: :head, push: :pinned, ring: :reader, fresh_verdict: :pinned, leave: :pinned,
             schedule: :pinned, plugin: :pinned, delegate: :pinned, participant: :pinned, automatic: :pinned)
    expect { described_class.for(:bogus) }.to raise_error(ArgumentError)
  end

  describe ".for_sender" do
    it "reads the row by the sender's client id" do
      senders = { "cli:send" => :send, "web:tab1" => :send, "web:unnamed" => :send, "tui:42" => :send,
                  "system:schedule:s1" => :schedule, "plugin" => :plugin, "delegate:abcdef12" => :delegate,
                  "review:p_1" => :participant, "system:reminder" => :automatic, "child:ab12cd34" => :automatic,
                  "cli:answer" => :automatic, "bot:x" => :automatic, "plugin:x" => :automatic }
      expect(senders.keys.to_h { |id| [id, described_class.for_sender(id).kind] }).to eq(senders)
    end
  end
end
