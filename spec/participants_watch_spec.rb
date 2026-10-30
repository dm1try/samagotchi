# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

require "samagotchi/participants_watch"
require "samagotchi/participants"
require "samagotchi/session"
require "support/test_kernel"
require "support/worker_loop_rounds"
require "samagotchi/engine"
require "samagotchi/bridge"
require "samagotchi/worker"

# Who is in a session's review, and who came or went since the last look
# (the worker's idle tick announces it as :participants_changed).
RSpec.describe Samagotchi::ParticipantsWatch do
  let(:state_dir) { Dir.mktmpdir("participants-watch") }
  let(:session_id) { "11111111-2222-3333-4444-555555555555" }
  let(:now) { [Time.utc(2026, 10, 23, 12)] }
  let(:watch) { described_class.new(session_id: -> { session_id }, state_dir: -> { state_dir }, clock: -> { now.first }) }
  let(:entries) { [] }

  before { FileUtils.mkdir_p(Samagotchi::Session.session_dir(session_id, state_dir: state_dir)) }
  after { FileUtils.rm_rf(state_dir) }

  def entry(id, name, expires_in: 3600, removed: false)
    { "id" => id, "kind" => "human", "name" => name, "role" => "reviewer", "added_at" => now.first.iso8601,
      "expires_at" => (now.first + expires_in).iso8601, "removed_at" => removed ? now.first.iso8601 : nil, "cap" => 2.0 }
  end

  # The sidecar as Participants.write leaves it, with a new mtime.
  def write(*rows)
    file = File.join(Samagotchi::Session.session_dir(session_id, state_dir: state_dir), "participants.json")
    File.write(file, JSON.generate({ "participants" => rows }))
    File.utime(Time.now, Time.now + rows.size + (@writes = (@writes || 0) + 1), file)
  end

  it "has nobody, and no change, without a sidecar" do
    expect(watch.active).to eq([])
    expect(watch.changes).to be_nil
    expect(watch.changes).to be_nil
  end

  it "takes the state as it is on its first look, then names who joined and who left, and why" do
    write(entry("p_aaaaaaaa", "Alex"))
    expect(watch.changes).to be_nil

    write(entry("p_aaaaaaaa", "Alex"), entry("p_bbbbbbbb", "Bo", expires_in: 60))
    change = watch.changes
    expect(change.joined).to eq([{ id: "p_bbbbbbbb", name: "Bo", kind: "human" }])
    expect(change.left).to eq([])
    expect(change.participants.map { |row| row[:id] }).to eq(%w[p_aaaaaaaa p_bbbbbbbb])
    expect(watch.changes).to be_nil

    now[0] += 120
    expect(watch.changes.left).to eq([{ id: "p_bbbbbbbb", name: "Bo", kind: "human", reason: "expired" }])

    write(entry("p_aaaaaaaa", "Alex", removed: true), entry("p_bbbbbbbb", "Bo", expires_in: -60))
    change = watch.changes
    expect(change.left).to eq([{ id: "p_aaaaaaaa", name: "Alex", kind: "human", reason: "revoked" }])
    expect(change.participants).to eq([])
    expect(change.to_event).to include(type: :participants_changed, participants: [])
  end

  it "reads the sidecar again only when its mtime moves" do
    write(entry("p_aaaaaaaa", "Alex"))
    watch.active
    allow(Samagotchi::Participants).to receive(:read).and_call_original
    watch.active
    watch.changes
    expect(Samagotchi::Participants).not_to have_received(:read)

    write(entry("p_aaaaaaaa", "Alex"), entry("p_bbbbbbbb", "Bo"))
    expect(watch.active.size).to eq(2)
    expect(Samagotchi::Participants).to have_received(:read).once
  end
end

# The worker announces each change between turns, and a join's snapshot
# names who is in the review.
RSpec.describe Samagotchi::Worker, "participants joining and leaving" do
  include WorkerLoopRounds

  around do |example|
    with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") do
      WebMock.allow_net_connect! if defined?(WebMock)
      example.run
    ensure
      WebMock.disable_net_connect! if defined?(WebMock)
    end
  end

  let(:tmpdir) { Dir.mktmpdir("worker-participants-spec") }
  let!(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir).tap do |s|
      s.save(state_dir: tmpdir)
    end
  end
  let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }
  let!(:engine) { Samagotchi::Engine.new(client: test_client, kernel: test_kernel) }
  let(:grants) { Samagotchi::Web::Grants.new(Samagotchi::Web::Grants.path(state_dir: tmpdir)) }
  let(:events) { Queue.new }

  before do
    FileUtils.mkdir_p(File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR))
    allow(Samagotchi::Engine).to receive(:new).and_return(engine)
    allow(engine).to receive(:start_idle)
    allow(engine).to receive(:stop_idle)
    engine.subscribe(observer: ->(event) { events << event if event[:type] == :participants_changed })
  end

  after do
    @thread&.kill
    join!(@thread, "the worker thread") if @thread
    FileUtils.rm_rf(tmpdir)
  end

  it "names nobody already invited at its start, then each invite and revoke once" do
    Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex", state_dir: tmpdir)
    worker = described_class.new(session_id: session.id, state_dir: tmpdir, session_dir: session_dir,
                                 idle_exit_minutes: 0, poll_interval: 0.05)
    count_loop_rounds(worker)
    @thread = Thread.new { worker.run }
    @thread.report_on_exception = false
    wait_for("the worker's sidecar") { File.exist?(File.join(session_dir, Samagotchi::WorkerSidecar::FILE)) }
    loop_rounds
    expect(events).to be_empty
    expect(engine.session_state_snapshot[:participants].map { |row| row[:name] }).to eq(["Alex"])

    bo = Samagotchi::Participants.invite(grants, session_id: session.id, name: "Bo", state_dir: tmpdir).grant
    joined = events.pop(timeout: 5)
    expect(joined).to include(joined: [{ id: bo.id, name: "Bo", kind: "human" }], left: [])
    expect(joined[:participants].map { |row| row[:name] }).to eq(%w[Alex Bo])

    Samagotchi::Participants.revoke(grants, session_id: session.id, id: bo.id, state_dir: tmpdir)
    left = events.pop(timeout: 5)
    expect(left).to include(joined: [], left: [{ id: bo.id, name: "Bo", kind: "human", reason: "revoked" }])
    loop_rounds
    expect(events).to be_empty
  end
end
