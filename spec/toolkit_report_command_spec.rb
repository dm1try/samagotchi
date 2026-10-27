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

  it "grades the kit on mode would run against the tools used from that turn on, against narrower logged kits" do
    expect(command.run).to eq(Samagotchi::CLI::Exit::OK)
    out = stdout.string

    # M2: the window runs to the session's end, so turn 1's web misses turn 2's write too.
    expect(out).to include("11111111 turn 1: kit:web (p=0.91, would suggested) → web: short of a tool (write)")
    expect(out).to include("11111111 turn 2: kit:web (p=0.88, would suggested) → web: short of a tool (write)")
    expect(out).to include("call_tool→chi/write")
    # M1: wider only when a narrower logged kit would also cover; archived sessions count.
    expect(out).to include("22222222 turn 1: kit:wide (p=0.80, would suggested) → wide: wider than needed " \
                           "(shell would also cover)")
    # M3 + M4: a below-threshold pick grades the default; raw-prompt calls come from the tool_response.
    expect(out).to include("33333333 turn 1: kit:web (p=0.30, would below_threshold) → full: wider than needed " \
                           "(web would also cover)")
    expect(out).to include("  tools: read, call_tool→github/search_issues")
    expect(out).to include("  tools: read, chrome_screenshot")
    # A toolkit chosen since: only the asked turn. A plugin tool (not a logged built-in) is declared by
    # every kit, though it registered after the ask started (M6).
    expect(out).to include("44444444 turn 1: kit:web (p=0.90, would suggested) → web: covers " \
                           "(its turn only: the toolkit was chosen later)")
    # Unreadable calls are never covers or wider; a defer grades the default.
    expect(out).to include("55555555 turn 1: undecided (p=0.70, would defer) → full: ungradable (tool calls not readable)")
    expect(out).to include("kit | suggestions | covers | short of a tool | wider than needed | ungradable | would")
    expect(out).to include("full | 2 | 0 | 0 | 1 | 1 | below_threshold 1, defer 1")
    expect(out).to include("web | 3 | 1 | 2 | 0 | 0 | suggested 3")
    expect(stderr.string).to eq("")
  end

  it "never grades a raw-prompt call_tool whose target it can't read as covered" do
    report = described_class.new(["report"], sessions_dir: sessions_dir, log: log)
    message = { role: "tool_response", content: "[call_tool]\n{}", tool_ids: ["t1"] }

    expect(report.send(:joined_uses, message)).to eq([:ungradable])
  end

  it "grades an on-mode line by what the turn did, not what it would have done" do
    report = described_class.new(["report"], sessions_dir: sessions_dir, log: log)
    late = { "would" => "suggested", "did" => "timeout", "kit" => "web", "default_kit" => "full" }

    expect(report.send(:graded_kit, late)).to eq("full")
    expect(report.send(:graded_kit, late.merge("did" => "suggested"))).to eq("web")
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
