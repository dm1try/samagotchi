# frozen_string_literal: true

require "spec_helper"
require "samagotchi/session_lifecycle"
require "samagotchi/session_manager"
require "samagotchi/schedules"

RSpec.describe "SessionLifecycle::ALLOWED" do
  let(:lifecycle) { Samagotchi::SessionLifecycle }
  let(:allowed) { lifecycle::ALLOWED }
  let(:rows) { Samagotchi::SessionInbox::WakePolicy::ROWS }
  let(:literal_ops) { %i[resume restart stop archive delete sched_chain sched_same attach] }

  # The words each operation's column may hold: :go, :wait, the decider's
  # own refusal reason, or a cell word (live, fallback, gone_*) that is no
  # reason but what the operation answers there.
  vocabulary = {
    delivery: %i[go wait gone owned deleting],
    resume: %i[go gone owned_by_tui live starting],
    restart: %i[go gone owned_by_tui starting not_running fallback stop_marked deleting],
    stop: %i[go gone owned_by_tui],
    archive: %i[go gone owned_by_tui starting],
    delete: %i[go owned_by_tui worker_running],
    sched_chain: %i[go stopped worker_busy],
    sched_same: %i[go stopped worker_busy],
    attach: %i[go wait gone_stopped gone_worker_newer]
  }.freeze
  define_method(:vocabulary) { |op| vocabulary.fetch(rows.key?(op) ? :delivery : op) }

  it "has a cell for every operation in every state" do
    expect(allowed.keys).to match_array(rows.keys + literal_ops)
    allowed.each do |op, column|
      expect(column.keys).to eq(lifecycle::STATES), "ALLOWED[#{op.inspect}]"
    end
    expect(lifecycle.allowed(:resume, :stopped)).to eq(:go)
  end

  it "generates each delivery column from its WakePolicy row, decided on the canonical facts" do
    mapping = { start: :go, live: :go, starting: :wait, stopped: :wait, archived: :wait, none: :wait,
                gone: :gone, owned: :owned, deleting: :deleting }
    rows.each do |kind, policy|
      expected = lifecycle::STATES.to_h do |state|
        [state, mapping.fetch(policy.decide(lifecycle::CANONICAL.fetch(state), wake: true, load: nil))]
      end
      expect(allowed.fetch(kind)).to eq(expected), "ALLOWED[#{kind.inspect}]"
    end
    expect(allowed.fetch(:send).fetch(:stopped)).to eq(:go)
    expect(allowed.fetch(:ring).fetch(:stopped)).to eq(:wait)
    expect(rows.keys.map { |kind| allowed.fetch(kind).fetch(:deleting) }).to all(eq(:deleting))
  end

  it "leaves WakePolicy::ROWS the same frozen table" do
    before = rows
    snapshot = before.transform_values(&:to_h)

    expect(lifecycle::ALLOWED).to be_frozen

    expect(Samagotchi::SessionInbox::WakePolicy::ROWS).to be(before)
    expect(before).to be_frozen
    expect(before.transform_values(&:to_h)).to eq(snapshot)
  end

  it "holds only its operation's words in each column" do
    allowed.each do |op, column|
      expect(column.values - vocabulary(op)).to be_empty, "ALLOWED[#{op.inspect}]: #{column.values.uniq.inspect}"
    end
  end

  it "names only refusal reasons the deciders have" do
    id = "00000000-0000-0000-0000-000000000000"
    sm = Samagotchi::SessionManager
    # A reason the refusal has its own words for, unlike a name it doesn't know.
    named = lambda do |make, reason|
      make.call(reason).message != make.call(:no_such_reason).message
    end
    checks = {
      restart: ->(reason) { named.call(->(r) { sm::RestartRefused.new(id, r) }, reason) },
      archive: ->(reason) { named.call(->(r) { sm::ArchiveRefused.new(id, r) }, reason) },
      delete: ->(reason) { named.call(->(r) { sm::DeleteRefused.new(id, r) }, reason) }
    }
    checks.each do |op, check|
      reasons = allowed.fetch(op).values.uniq - %i[go wait gone owned_by_tui fallback]
      expect(reasons.reject { |reason| check.call(reason) }).to be_empty, "#{op}: #{reasons.inspect}"
    end
    expect(defined?(Samagotchi::Session::NotFound)).to be_truthy
    expect(sm::OwnedByTUI).to be < StandardError
    schedules = File.read(File.expand_path("../../lib/samagotchi/schedules.rb", __dir__))
    expect(schedules).to include('"its worker is starting or leaving"')
    expect(sm::DeliverResult::STOPPED["detail"]).to be_a(String)
  end

  it "reads each cell as go, wait or refused" do
    expect(lifecycle.verdict(:send, :go)).to eq(:go)
    expect(lifecycle.verdict(:ring, :wait)).to eq(:wait)
    expect(lifecycle.verdict(:send, :owned)).to eq(:refused)
    expect(lifecycle.verdict(:send, :deleting)).to eq(:refused)
    expect(lifecycle.verdict(:resume, :live)).to eq(:wait)
    expect(lifecycle.verdict(:resume, :starting)).to eq(:wait)
    expect(lifecycle.verdict(:restart, :starting)).to eq(:refused)
    expect(lifecycle.verdict(:restart, :fallback)).to eq(:go)
    expect(lifecycle.verdict(:attach, :gone_stopped)).to eq(:refused)
    expect(lifecycle.verdict(:archive, :starting)).to eq(:refused)
  end
end
