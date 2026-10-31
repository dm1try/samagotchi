# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "samagotchi/context_command"
require "samagotchi/context_report_command"

RSpec.describe Samagotchi::ContextReportCommand do
  let(:dir) { Dir.mktmpdir("context-report") }
  let(:state_dir) { File.join(dir, "sessions") }
  let(:now) { Time.utc(2026, 10, 31, 12) }
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  after { FileUtils.rm_rf(dir) }

  def write(*lines)
    File.write(Samagotchi::ContextCandidatesLog.path(state_dir), lines.map { |line| "#{JSON.generate(line)}\n" }.join)
  end

  def line(kind, session, name, at: "2026-10-30T10:00:00Z", **fields)
    { "kind" => kind, "session_id" => session, "name" => name, "at" => at }.merge(fields.transform_keys(&:to_s))
  end

  def judged(session, name, p, stated: true, **fields) = line("judged", session, name, p: p, stated: stated, **fields)

  it "counts the log's lines, what the judge would attach and how it agrees with the user" do
    write(
      line("proposed", "s1", "a"), judged("s1", "a", 0.2, stated: false), judged("s1", "a", 0.9), line("mentioned", "s1", "a"),
      line("proposed", "s1", "b"), judged("s1", "b", 0.85), line("declined", "s1", "b"),
      line("proposed", "s2", "c"), judged("s2", "c", 0.3), line("attached", "s2", "c"),
      line("proposed", "s2", "d"), judged("s2", "d", 0.65), line("withdrawn", "s2", "d"),
      line("proposed", "s3", "old", at: "2026-09-01T10:00:00Z")
    )

    status = described_class.new([], stdout: stdout, stderr: stderr, state_dir: state_dir, now: now).run

    expect(status).to eq(0)
    out = stdout.string
    expect(out).to include("the last 14 days, 2 sessions")
    expect(out).to include("proposed 4 · mentioned 1 · attached by you 1 · declined 1 · detached 0 · withdrawn 1")
    expect(out).to include("judge: 5 asks · judged 4 · no task yet 1 · 4 candidates judged")
    expect(out).to include("≥ 0.6  3  offer_threshold")
    expect(out).to include("≥ 0.8  2  threshold")
    expect(out).to include("(3 judged candidates you attached, mentioned or declined), at 0.8: agree 1 · " \
                           "would attach what you declined 1 · would miss what you attached 1")
    expect(out).not_to include("Fix")
  end

  it "takes --days, and refuses a bad one" do
    write(line("proposed", "s1", "a", at: "2026-10-20T10:00:00Z"))
    described_class.new(%w[--days 30], stdout: stdout, stderr: stderr, state_dir: state_dir, now: now).run
    expect(stdout.string).to include("proposed 1")

    expect(described_class.new(%w[--days 0], stdout: stdout, stderr: stderr, state_dir: state_dir, now: now).run).to eq(2)
    expect(stderr.string).to include("--days takes a positive whole number")
  end

  it "is chi context report" do
    write(line("proposed", "s1", "a", at: Time.now.utc.iso8601))
    status = Samagotchi::ContextCommand.new(%w[report], stdout: stdout, stderr: stderr, state_dir: state_dir).run

    expect(status).to eq(0)
    expect(stdout.string).to include("proposed 1")
  end
end
