# frozen_string_literal: true

require "stringio"
require "tmpdir"
require_relative "../../script/model_notes_report/cli"
require_relative "report_fixtures"

RSpec.describe ModelNotesReport::CLI do
  let(:dir) { Dir.mktmpdir("notes-report-cli-") }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:other_note) { ReportFixtures::NOTE.merge("digest" => "9f9f9f9f") }

  before do
    ReportFixtures.write_session(dir, messages: ReportFixtures.build_messages, id: "aaaaaaaa-0000-4000-8000-000000000000",
                                      turn_records: [{ "id" => "t-1" }, { "id" => "k-1" }])
    ReportFixtures.write_session(dir, messages: ReportFixtures.build_messages, id: "bbbbbbbb-0000-4000-8000-000000000000",
                                      created_at: "2026-10-07T09:00:00.000+02:00")
    ReportFixtures.write_session(dir, messages: ReportFixtures.build_messages, id: "cccccccc-0000-4000-8000-000000000000",
                                      prompt_notes: nil, created_at: "2026-09-28T09:00:00.000+02:00")
    ReportFixtures.write_session(dir, messages: ReportFixtures.build_messages, id: "dddddddd-0000-4000-8000-000000000000",
                                      prompt_notes: [other_note])
    ReportFixtures.write_session(dir, messages: ReportFixtures.build_messages, id: "eeeeeeee-0000-4000-8000-000000000000",
                                      model: "local-qwen", prompt_notes: [])
    ReportFixtures.write_session(dir, messages: [], id: "ffffffff-0000-4000-8000-000000000000")
    File.write(File.join(dir, "broken.json"), "{not json")
  end

  after { FileUtils.rm_rf(dir) }

  def run(*argv, env: {}) = described_class.new(argv, env: env, out: out, err: err).run

  def json(*argv, env: {})
    expect(run(*argv, "--json", env: env)).to eq(0)
    JSON.parse(out.string)
  end

  it "groups by model and by the notes' names and digests, older files and no notes as none" do
    data = json("--sessions", dir)

    keys = data["groups"].map { |group| [group["model"], group["notes_key"], group["session_ids"].map { |id| id[0, 4] }] }
    expect(keys).to eq([["local-qwen", "none", ["eeee"]],
                        ["openrouter:deepseek/deepseek-v4.1-flash", "model_notes_deepseek@1a2b3c4d", %w[aaaa bbbb]],
                        ["openrouter:deepseek/deepseek-v4.1-flash", "model_notes_deepseek@9f9f9f9f", ["dddd"]],
                        ["openrouter:deepseek/deepseek-v4.1-flash", "none", ["cccc"]]])
    expect(data).to include("sessions" => 5, "skipped" => include("unreadable" => 1, "few_steps" => 1))
  end

  it "sums and takes medians per group" do
    group = json("--sessions", dir)["groups"][1]

    expect(group).to include("sessions" => 2, "first_edit_median" => 3, "never_edited" => 0, "first_commit_median" => 5,
                             "steps" => 14, "commits" => 2, "commits_per_100" => 14.29, "longest_no_edit_median" => 3,
                             "bare_amp" => 2, "continues" => 1, "steers" => 0, "follow_ups" => 0)
    expect(group["notes"]).to eq([ReportFixtures::NOTE])
  end

  it "filters by a model glob, a date and a step count" do
    expect(json("--sessions", dir, "--model", "deepseek/*")["groups"].map { |group| group["model"] }.uniq)
      .to eq(["openrouter:deepseek/deepseek-v4.1-flash"])

    out.truncate(0) && out.rewind
    data = json("--sessions", dir, "--model", "*qwen*|nothing", "--since", "2026-10-01", "--min-steps", "8")
    expect(data["sessions"]).to eq(0)
    expect(data["skipped"]).to include("other_model" => 5, "few_steps" => 1)

    out.truncate(0) && out.rewind
    expect(json("--sessions", dir, "--since", "2026-10-06")["session_rows"].map { |row| row["id"][0, 4] }).to eq(["bbbb"])
  end

  it "prints the groups and sessions as tables, with ids, models, notes and numbers only" do
    expect(run("--sessions", dir)).to eq(0)

    text = out.string
    expect(text).to start_with("model notes report: 5 session(s) in 4 group(s) from #{dir} (skipped: 1 unreadable, 1 few steps)")
    expect(text).to include("  2. openrouter:deepseek/deepseek-v4.1-flash  notes: model_notes_deepseek@1a2b3c4d")
    group_row = text.lines.find { |line| line.split.first == "2" && line.split.size == 13 }
    expect(group_row.split).to eq(%w[2 2 3 0 5 0 14.3 3 2 1 0 0 0])
    expect(text.lines.find { |line| line.include?("cccccccc") }.split).to eq(%w[4 cccccccc 2026-09-28 7 6 3 5 14.3 3 1 - 0 0 0])
    expect(text).not_to include("Fix the rounding", "Round to cents", "lib/cart.rb", "coding agent")
  end

  it "reads chi's own sessions folder by default" do
    state = Dir.mktmpdir("notes-report-state-")
    FileUtils.mkdir_p(File.join(state, "samagotchi"))
    FileUtils.cp_r(dir, File.join(state, "samagotchi", "sessions"))

    expect(json(env: { "XDG_STATE_HOME" => state })["source"]).to eq(File.join(state, "samagotchi", "sessions"))
  ensure
    FileUtils.rm_rf(state)
  end

  it "refuses a missing folder, a bad date and stray arguments" do
    expect(run("--sessions", File.join(dir, "nope"))).to eq(2)
    expect(run("--since", "yesterday")).to eq(2)
    expect(run("extra")).to eq(2)
    expect(err.string).to include("no sessions directory", "invalid argument: --since yesterday", "needless argument")
  end

  it "defines the metrics in --help" do
    expect { run("--help") }.to raise_error(SystemExit).and output(/1st-commit +the place of the first execute call/).to_stdout
  end
end
