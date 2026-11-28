# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require_relative "../support/lifecycle_matrix"

# The session lifecycle characterization matrix: every row of facts
# (LifecycleMatrix.rows) written as files, read by SessionLifecycle.read and
# driven through every decider; each answer must be ALLOWED's cell for the
# row's state (SHOWN's for the session hub), or be named by exactly one
# KNOWN_DIFFERENCE. The delivery columns are generated from WakePolicy::ROWS,
# so for deliveries the matrix proves the states are drawn right (decide is a
# function of the state), not what WakePolicy does; the literal columns are
# goldens. See docs/internals/session-lifecycle.md (Characterization matrix).
module LifecycleMatrixFindings
  KnownDifference = Data.define(:op, :when, :reason)

  stop_first = %i[tui deleting]
  # Where a decider disagrees with ALLOWED (or the hub with SHOWN) today:
  # findings for the owner, not fixed here. Each mismatch is named by exactly
  # one entry; an entry that names none fails (it is stale).
  KNOWN_DIFFERENCES = [
    # F1: owner-first deciders (WakePolicy, resume, archive, delete) answer the lock; these read the stop first.
    KnownDifference.new(op: :sched_chain, when: ->(row) { row.owner == :tui && row.stop },
                        reason: "F1: Schedules#busy_cell reads the stop marker before the owner: a one-turn " \
                                "run's session with a stop answers stopped"),
    KnownDifference.new(op: :sched_same, when: ->(row) { row.owner == :tui && row.stop },
                        reason: "F1: as chain mode, the stop marker first: stopped under a one-turn run's lock"),
    KnownDifference.new(op: :attach, when: ->(row) { stop_first.include?(row.owner) && row.stop },
                        reason: "F1: LocalLink#live_worker reads Session.stopped_marker? before the link: " \
                                "gone_stopped under a one-turn run's or a deleter's lock"),
    # F1b (file with F6): chain mode's starting check comes before any one-turn-run check.
    KnownDifference.new(op: :sched_chain, when: ->(row) { row.owner == :tui && row.start && !row.stop },
                        reason: "F1b: busy_cell's chain-mode starting override runs with no tui check: " \
                                "a one-turn run's session with a fresh starting marker is worker_busy"),
    # An owner of unknown kind (a lock record still blank) is booting; with a stop the stop-first readers say stopped.
    KnownDifference.new(op: :sched_chain, when: ->(row) { row.owner == :unknown && row.stop },
                        reason: "unknown owner: WorkerLink reads a blank lock record as Starting (booting), " \
                                "busy_cell's stop-first override answers stopped"),
    KnownDifference.new(op: :sched_same, when: ->(row) { row.owner == :unknown && row.stop },
                        reason: "unknown owner: booting by its link, stopped by busy_cell's stop-first override"),
    KnownDifference.new(op: :attach, when: ->(row) { row.owner == :unknown && row.stop },
                        reason: "unknown owner: booting by its link, gone_stopped by LocalLink's stop-first check"),
    # The start/stop order is a row fact: a start marked after the stop holds a resume off.
    KnownDifference.new(op: :resume, when: lambda(&:start_after_stop),
                        reason: "start_after_stop: StartingMarker.claim takes over only a start marked at or before " \
                                "stopped_at, so a start marked after the stop (resume's claim before its " \
                                "Session.clear_stopped) holds resume off: starting where ALLOWED's canonical (marked " \
                                "before the stop) goes"),
    # New: wake_for_report folds the ring's :live into :owned.
    KnownDifference.new(op: :ring, when: ->(row) { row.exists && %i[worker unknown].include?(row.owner) },
                        reason: "wake_for_report maps the ring's :live (a worker reads it) to :owned, the word of a " \
                                "one-turn run's session: its caller can't tell the two apart")
  ].freeze

  stopped = %i[stopping stopped_starting stopped]
  # What the session hub should show in each state (Web::SessionSummary's
  # status and bridge_up, the live its summary gates the open question on
  # (SessionSummary.shown)): up and live only while a
  # worker's Bridge answers, status stopped only in a stopped state. absent
  # has no summary.
  SHOWN = Samagotchi::SessionLifecycle::STATES.to_h do |state|
    shown = if state == :absent
              { status: nil, bridge_up: nil, live: nil }
            else
              { status: stopped.include?(state) ? "stopped" : "idle", bridge_up: state == :live, live: state == :live }
            end
    [state, shown.freeze]
  end.freeze

  class << self
    attr_accessor :results, :seconds
  end
end

RSpec.describe "session lifecycle characterization matrix" do
  include LifecycleMatrix::Drivers

  let(:findings) { LifecycleMatrixFindings }

  def matrix
    findings.results ||= Dir.mktmpdir("lifecycle-matrix") do |root|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      run_lifecycle_matrix(root).tap do
        findings.seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end
    end
  end

  def expected(op, state, transitioning: false)
    key = { hub_status: :status, hub_bridge_up: :bridge_up, hub_live: :live }[op]
    key ? findings::SHOWN.fetch(state).fetch(key) : Samagotchi::SessionLifecycle.allowed(op, state, transitioning: transitioning)
  end

  def mismatches
    matrix.flat_map do |result|
      row = result[:row]
      result[:cells].filter_map do |op, got|
        want = expected(op, row.state, transitioning: row.transitioning)
        { op: op, row: row, got: got, want: want } unless got == want
      end
    end
  end

  def covering(mismatch)
    findings::KNOWN_DIFFERENCES.select { |known| known.op == mismatch[:op] && known.when.call(mismatch[:row]) }
  end

  def describe_mismatch(mismatch)
    "#{mismatch[:op]} in #{mismatch[:row].name} (#{mismatch[:row].state}): got #{mismatch[:got].inspect}, " \
      "ALLOWED/SHOWN #{mismatch[:want].inspect}"
  end

  it "reads every row's files as the state its facts derive, continue in flight as a fact" do
    wrong = matrix.reject do |result|
      row = result[:row]
      result[:read].state == row.state && result[:read].continuing? == row.continuing &&
        result[:read].transitioning? == row.transitioning
    end

    expect(wrong.map { |result| "#{result[:row].name}: read #{result[:read].state}, facts #{result[:row].state}" })
      .to be_empty
    expect(matrix.size).to be >= 100
  end

  it "drives a held transition lock for real: every :shared delivery busy, every :none one its state's cell, a stop and a ring's wake busy" do
    held = matrix.select { |result| result[:row].transitioning }
    expect(held.map { |result| result[:row].name }.size).to eq(LifecycleMatrix::HELD_ROWS.size)
    shared = Samagotchi::SessionInbox::WakePolicy::ROWS.select { |_, policy| policy.shared? }.keys
    held.each do |result|
      expect(result[:cells].slice(*shared).values.uniq).to eq([:busy]), result[:row].name
      expect(result[:cells][:note]).to eq(Samagotchi::SessionLifecycle.allowed(:note, result[:row].state))
      expect(result[:cells].values_at(:stop, :ring)).to eq(%i[busy busy]), result[:row].name
    end
  end

  it "reaches every state" do
    expect(matrix.map { |result| result[:row].state }.uniq).to match_array(Samagotchi::SessionLifecycle::STATES)
  end

  it "drives every operation of ALLOWED and the hub's keys over every row" do
    ops = Samagotchi::SessionLifecycle::ALLOWED.keys + LifecycleMatrix::HUB_OPS
    expect(matrix.map { |result| result[:cells].keys }).to all(match_array(ops))
  end

  it "agrees with ALLOWED and SHOWN except where exactly one KNOWN_DIFFERENCE names the cell" do
    unnamed = mismatches.select { |mismatch| covering(mismatch).empty? }
    doubled = mismatches.select { |mismatch| covering(mismatch).size > 1 }

    expect(unnamed.map { |mismatch| describe_mismatch(mismatch) }).to be_empty
    expect(doubled.map { |mismatch| "#{describe_mismatch(mismatch)}: named #{covering(mismatch).size} times" })
      .to be_empty
  end

  it "names a mismatch with every KNOWN_DIFFERENCE (a stale one fails)" do
    stale = findings::KNOWN_DIFFERENCES.reject do |known|
      mismatches.any? { |mismatch| known.op == mismatch[:op] && known.when.call(mismatch[:row]) }
    end

    expect(stale.map(&:reason)).to be_empty
  end

  it "says why each row the code can't make is kept" do
    unreachable = LifecycleMatrix.rows.reject(&:reachable)

    expect(unreachable).not_to be_empty
    expect(unreachable.map(&:note)).to all(be_a(String))
    expect(matrix.map { |result| result[:row].name }).to include(*unreachable.map(&:name))
  end
end
