# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/context_poller"

RSpec.describe Samagotchi::ContextPoller do
  let(:tmpdir) { Dir.mktmpdir("context-poller") }
  let(:state_dir) { File.join(tmpdir, "samagotchi", "sessions") }
  let(:session_id) { "11111111-2222-3333-4444-555555555555" }
  let(:work) { File.join(tmpdir, "work").tap { |d| FileUtils.mkdir_p(d) } }
  let(:root) { File.join(tmpdir, "repo").tap { |d| FileUtils.mkdir_p(d) } }
  let(:own) { Samagotchi::ContextSources.session_location(session_id, state_dir: state_dir) }
  let(:project) { Samagotchi::ContextSources.project_location_for(root, state_dir: state_dir) }
  let(:changes) { [] }
  let(:poller) do
    described_class.new(session_id: session_id, state_dir: state_dir, project_root: root, cwd: work,
                        on_change: -> { changes << :change }, tick: 0.05)
  end

  after do
    poller.stop
    FileUtils.rm_rf(tmpdir)
  end

  def add(location, name, cmd, every: nil)
    location.add(Samagotchi::ContextSources::Source.new(name: name, cmd: cmd, every_seconds: every, why: nil, hint: nil,
                                                        scope: location.scope, added_by: "cli", created_at: nil))
  end

  # A snapshot tried +seconds+ ago.
  def age!(location, name, seconds)
    stamp = (Time.now - seconds).utc.iso8601
    location.write_snapshot(name, location.snapshot(name).with(checked_at: stamp, fetched_at: stamp))
  end

  it "runs a session source in the session's folder and a project's in the project root, then calls on_change" do
    add(own, "where", "pwd")
    add(project, "root", "pwd")

    poller.poll

    expect(own.snapshot("where").text.strip).to eq(File.realpath(work))
    expect(project.snapshot("root").text.strip).to eq(File.realpath(root))
    expect(changes.size).to eq(2)
  end

  it "runs a source again only once its interval has passed, and leaves push sources alone" do
    add(own, "date", "date +%s%N", every: 60)
    add(own, "pushed", nil)
    poller.poll
    first = own.snapshot("date").text

    poller.poll
    expect(own.snapshot("date").text).to eq(first)

    age!(own, "date", 61)
    poller.poll
    expect(own.snapshot("date").text).not_to eq(first)
    expect(own.snapshot("pushed").text).to be_nil
  end

  it "uses context.every_seconds without --every" do
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("context.every_seconds").and_return(120)
    add(own, "date", "date +%s%N")
    poller.poll
    first = own.snapshot("date").text

    age!(own, "date", 100)
    poller.poll
    expect(own.snapshot("date").text).to eq(first)
    age!(own, "date", 121)
    poller.poll
    expect(own.snapshot("date").text).not_to eq(first)
  end

  it "on its first pass runs every source not tried in the last 30 s, whatever its interval" do
    add(own, "slow", "date +%s%N", every: 3600)
    poller.poll
    first = own.snapshot("slow").text

    age!(own, "slow", 31)
    poller.poll(first: true)
    expect(own.snapshot("slow").text).not_to eq(first)
  end

  it "doesn't run a source this session muted, and retries a failing one only after its interval" do
    add(project, "quiet", "echo x")
    own.mute("quiet")
    add(own, "broken", "exit 3", every: 60)

    poller.poll
    poller.poll

    expect(project.snapshot("quiet").checked_at).to be_nil
    expect(own.snapshot("broken").error).to eq("exit 3")
    expect(changes.size).to eq(1)
  end

  it "polls in its own thread, and stop kills the command it runs" do
    add(own, "hang", "sleep 30; echo late")
    poller.start
    expect(wait_until { Dir.glob(File.join(own.dir, "hang.lock")).any? }).to be(true)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    poller.stop

    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
    expect(own.snapshot("hang").error).to eq("stopped with the worker")
  end
end
