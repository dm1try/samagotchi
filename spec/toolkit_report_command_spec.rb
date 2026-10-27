# frozen_string_literal: true

require "stringio"
require "samagotchi/toolkit_report_command"

RSpec.describe Samagotchi::ToolkitReportCommand do
  let(:fixture_dir) { File.expand_path("fixtures/toolkit_report", __dir__) }
  let(:sessions_dir) { File.join(fixture_dir, "sessions") }
  let(:log) { Samagotchi::SystemOne::Log.new(dir: fixture_dir, file: "toolkit_suggestions.jsonl") }
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }
  let(:now) { Time.utc(2026, 10, 27, 13) }

  def command(argv = ["report"])
    described_class.new(argv, stdout: stdout, stderr: stderr, sessions_dir: sessions_dir, log: log, now: now)
  end

  it "grades tool calls, call_tool targets, and archived sessions into the three report outcomes" do
    expect(command.run).to eq(Samagotchi::CLI::Exit::OK)

    expect(stdout.string).to include("turn 1: kit:web (p=0.91) → web: covers")
    expect(stdout.string).to include("turn 2: kit:web (p=0.88) → web: short of a tool (write)")
    expect(stdout.string).to include("call_tool→chi/write")
    expect(stdout.string).to include("22222222 turn 1: kit:wide (p=0.80) → wide: wider than needed")
    expect(stdout.string).to include("Per-kit")
    expect(stderr.string).to eq("")
  end

  it "caps days at retention and refuses a non-positive or malformed --days" do
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("session.retention_days").and_return(7)
    command(["report", "--days", "30"]).run
    expect(stdout.string).to include("last 7 days")

    stdout.truncate(0)
    expect(command(["report", "--days", "0"]).run).to eq(Samagotchi::CLI::Exit::USAGE)
    expect(stderr.string).to include("--days takes a positive whole number")
  end

  it "includes the fixture's archived session when building the report set" do
    summaries = Samagotchi::Session.list(state_dir: sessions_dir, include_archived: true)
    expect(summaries.map(&:id)).to include("22222222-2222-4222-8222-222222222222")
    expect(summaries.find { |session| session.id.start_with?("2222") }.archived).to be(true)
  end
end
