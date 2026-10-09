# frozen_string_literal: true

require "tmpdir"
require_relative "../../script/model_notes_report/session_stats"
require_relative "report_fixtures"

RSpec.describe ModelNotesReport::SessionReader do
  let(:dir) { Dir.mktmpdir("notes-report-") }

  after { FileUtils.rm_rf(dir) }

  def stats(messages, **)
    described_class.read(ReportFixtures.write_session(dir, messages: messages, **))
  end

  def call_commands(*commands)
    commands.each_with_index.flat_map { |command, index| ReportFixtures.execute("x#{index}", command) }
  end

  it "counts a build's steps, calls, first edit and commit, commits per 100 steps and longest no-edit run" do
    result = stats(ReportFixtures.build_messages)

    expect(result).to have_attributes(steps: 7, calls: 6, edits: 1, commits: 1, first_edit: 3, first_commit: 5,
                                      longest_no_edit: 3, bare_amp: 1)
    expect(result.commits_per_100).to be_within(0.01).of(14.29)
    expect(result.notes_key).to eq("model_notes_deepseek@1a2b3c4d")
  end

  it "has no first edit or commit when there is none, and the whole session as its no-edit run" do
    messages = [ReportFixtures.prompt("Look around."), *ReportFixtures.read("c1"), *ReportFixtures.read("c2"),
                ReportFixtures.model("Seen.")]

    expect(stats(messages)).to have_attributes(first_edit: nil, first_commit: nil, longest_no_edit: 2, commits: 0)
  end

  it "takes the longest run between edits and counts a write as an edit" do
    messages = [ReportFixtures.prompt("Go."), *ReportFixtures.edit("c1"), *ReportFixtures.read("c2"),
                *ReportFixtures.read("c3"), *ReportFixtures.read("c4"),
                *ReportFixtures.step("c5", "write", { "path" => "lib/new.rb", "content" => "x" }),
                *ReportFixtures.read("c6")]

    expect(stats(messages)).to have_attributes(first_edit: 1, edits: 2, longest_no_edit: 3)
  end

  it "finds commits by git's own command, whatever options come before it" do
    messages = [ReportFixtures.prompt("Go."),
                *call_commands("git -C /home/dev/projects/shop commit -m 'x'", "GIT_AUTHOR_NAME=a git commit --amend",
                               "echo 'git commit'", "git log --grep commit", "git -c user.name=x commit -qm y",
                               "cd sub; git commit -m \"$(cat <<'EOF'\nmsg & more\nEOF\n)\"")]

    expect(stats(messages)).to have_attributes(commits: 4, first_commit: 1)
  end

  it "counts execute calls with a bare &, not &&, redirections or a quoted one" do
    messages = [ReportFixtures.prompt("Go."),
                *call_commands("a && b", "cmd 2>&1 | tee log", "cmd &> log", "cmd >& log", "echo 'a & b'",
                               "sleep 5 & wait", "server & server2 &")]

    expect(stats(messages).bare_amp).to eq(2)
  end

  it "reads a native model's calls from its text" do
    native = lambda do |name, key, value|
      ReportFixtures.model("<tool_call>\n<function=#{name}>\n<parameter=#{key}>\n#{value}\n</parameter>\n</function>\n</tool_call>")
    end
    messages = [ReportFixtures.prompt("Go."), native.call("read", "path", "a.rb"), { "role" => "tool_response", "content" => "ok" },
                native.call("execute", "command", "git commit -am x"), { "role" => "tool_response", "content" => "ok" },
                ReportFixtures.model("Done.")]

    expect(stats(messages, model: "local-qwen")).to have_attributes(steps: 3, calls: 2, first_commit: 2, first_edit: nil)
  end

  it "counts steers a person sent, inputs into a running turn, plugin nudges and follow-up prompts" do
    messages = [
      ReportFixtures.prompt("Build it.", turn_id: "t1"), *ReportFixtures.read("c1"),
      ReportFixtures.prompt("stop exploring", kind: "input"),
      ReportFixtures.prompt("from the coordinator", kind: "input", source: "chi_send"),
      ReportFixtures.prompt("commit now", kind: "steer", source: "user"),
      ReportFixtures.prompt("loop!", kind: "steer", source: "loop_guard"),
      *ReportFixtures.read("c2"), ReportFixtures.model("Done."),
      ReportFixtures.prompt("report", kind: "input", source: "delegate_report", turn_start: true, turn_id: "t2"),
      ReportFixtures.model("Noted."),
      ReportFixtures.prompt("go on", turn_id: "t3"), ReportFixtures.model("Went on.")
    ]

    expect(stats(messages)).to have_attributes(steers: 3, nudges: 1, follow_ups: 1)
  end

  it "counts the turns analytics.json has with no prompt of their own as continues" do
    messages = [ReportFixtures.prompt("Build it.", turn_id: "t1"), *ReportFixtures.read("c1"), *ReportFixtures.read("c2"),
                ReportFixtures.model("Done."), ReportFixtures.prompt("More.", turn_id: "t2"), ReportFixtures.model("Ok.")]
    records = %w[t1 k1 k2 t2].map { |id| { "id" => id, "status" => "completed" } }

    expect(stats(messages, turn_records: records).continues).to eq(2)
  end

  it "counts records marked continue: true when the records carry the mark" do
    messages = [ReportFixtures.prompt("Build it.", turn_id: "t1"), *ReportFixtures.read("c1"),
                ReportFixtures.model("Done.")]
    records = [
      { "id" => "t1", "status" => "completed" },
      { "id" => "k1", "status" => "completed", "continue" => true },
      { "id" => "k2", "status" => "completed", "continue" => true }
    ]

    expect(stats(messages, turn_records: records).continues).to eq(2)
  end

  it "doesn't count a reminder-only turn as a continue when the records carry marks" do
    messages = [ReportFixtures.prompt("Build it.", turn_id: "t1"), *ReportFixtures.read("c1"),
                ReportFixtures.model("Done.")]
    records = [
      { "id" => "t1", "status" => "completed" },
      { "id" => "r1", "status" => "completed" },
      { "id" => "k1", "status" => "completed", "continue" => true }
    ]

    expect(stats(messages, turn_records: records).continues).to eq(1)
  end

  it "counts no continue in a marked file whose only prompt-less turn is a reminder's" do
    messages = [ReportFixtures.prompt("Build it.", turn_id: "t1"), ReportFixtures.model("Done.")]
    records = [{ "id" => "t1", "status" => "completed", "continue" => false },
               { "id" => "r1", "status" => "completed", "continue" => false }]

    expect(stats(messages, turn_records: records).continues).to eq(0)
  end

  it "counts records over prompts for prompts without a turn id, and has no continues without analytics.json" do
    messages = [ReportFixtures.prompt("Build it."), *ReportFixtures.read("c1"), ReportFixtures.model("Done.")]

    expect(stats(messages, turn_records: [{ "id" => "a" }, { "id" => "b" }]).continues).to eq(1)
    expect(stats(messages).continues).to be_nil
  end

  it "reads an older file without prompt_notes as none" do
    expect(stats(ReportFixtures.build_messages, prompt_notes: nil)).to have_attributes(notes: [], notes_key: "none")
  end

  it "refuses a JSON file that isn't a session" do
    path = File.join(dir, "other.json")
    File.write(path, JSON.generate("hello" => 1))

    expect { described_class.read(path) }.to raise_error(KeyError)
  end
end
