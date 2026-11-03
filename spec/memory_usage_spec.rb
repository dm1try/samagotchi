# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "spec_helper"
require "samagotchi/memory_command"
require "samagotchi/memory_usage"

# `chi memory usage` (docs/memory.md, "What the memories cost"): the counting
# from fixture sessions shaped like real files of both loops, and the command's
# two formats. Nothing is written: the fixture's state and memories dirs are
# only read.
RSpec.describe Samagotchi::MemoryUsage do
  SEP = Samagotchi::ToolResponse::SEPARATOR

  let(:tmp) { Dir.mktmpdir("memory-usage") }
  # A folder holding a .git directory is a project to MemoryPaths, so the
  # fixture has two projects and one folder in no repository.
  let(:repo) { File.join(tmp, "repo").tap { |dir| FileUtils.mkdir_p(File.join(dir, ".git")) } }
  let(:other) { File.join(tmp, "other").tap { |dir| FileUtils.mkdir_p(File.join(dir, ".git")) } }
  let(:loose) { File.join(tmp, "loose").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:state) { File.join(tmp, "state", "samagotchi", "sessions") }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  around { |example| with_config_home(File.join(tmp, "config")) { example.run } }

  def project_dir(cwd) = Samagotchi::MemoryPaths.project_dir(cwd: File.realpath(cwd))
  def system_dir = Samagotchi::MemoryPaths.system_dir

  def remember(dir, name, body)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{name}.md"), body)
  end

  def write_index(dir, lines)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "index.md"), "# Memory Index\n\n#{lines.join("\n")}\n")
  end

  # A session file of the shape chi saves, in the fixture state dir. project_root
  # is left unstored (as in a file from before the field) so the fallback to
  # working_directory is what counts it.
  def save_session(name, working_directory:, messages:, project_root: nil, test_run: false,
                   used: [], preloaded: [], updated_at: "2026-11-01T10:00:00.000Z")
    FileUtils.mkdir_p(state)
    File.write(File.join(state, "#{name}.json"), JSON.generate({
      "metadata_version" => 3, "id" => name, "mode" => "assist", "model_name" => "gemma",
      "working_directory" => working_directory, "project_root" => project_root, "messages" => messages,
      "created_at" => updated_at, "updated_at" => updated_at, "status" => "idle", "test_run" => test_run,
      "used_memory_names" => used, "preloaded_memory_names" => preloaded
    }))
  end

  def call(id, name, arguments)
    { "role" => "model", "content" => "", "tool_calls" => [{ "id" => id, "name" => name, "arguments" => arguments }] }
  end

  def result(id, text)
    { "role" => "tool_response", "tool_call_id" => id, "content" => text }
  end

  def report(top: 10, root: repo, scope: nil)
    sessions, unreadable = Samagotchi::MemoryUsage.load_sessions(state_dir: state)
    Dir.chdir(root) do
      Samagotchi::MemoryUsage.new(
        sessions: sessions, entries: Samagotchi::MemoryCommand.entries(scope), unreadable: unreadable,
        root: root, scopes: scope ? [scope] : Samagotchi::MemoryUsage::SCOPES
      ).report(top: top)
    end
  end

  def row(summary, name, scope) = summary.top.find { |use| use.name == name && use.scope == scope }

  def index_of(summary, scope) = summary.indexes.find { |index| index.scope == scope }

  # A folder's files and their mtimes: a usage run changes none of them.
  def snapshot(dir) = Dir.glob(File.join(dir, "**/*")).to_h { |path| [path, File.mtime(path)] }

  def build_fixture
    write_index(system_dir, [
      "- **identity** · system · 2026-11-01 · 50 — Who chi is",
      "- **guide** · system · 2026-11-01 · 10 — The team's guide",
      "- **big** · system · 2026-11-01 · 75 — Read, but cut",
      "- **bundle-notes** · system · 2026-11-01 · 20 · from team — A bundle's memory"
    ])
    remember(system_dir, "identity", "z" * 200)
    remember(system_dir, "guide", "g" * 40)
    remember(system_dir, "big", "b" * 300)
    remember(system_dir, "bundle-notes", "n" * 50)

    write_index(project_dir(repo), [
      "- **handoff** · project · 2026-11-01 · 25 — Where the work stands",
      "- **notes** · project · 2026-11-01 · 25 — Some notes",
      "- **dormant** · project · 2026-11-01 · 40 — Read once",
      "- **cold** · project · 2026-11-01 · 75 — Never opened"
    ])
    remember(project_dir(repo), "handoff", "x" * 100)
    remember(project_dir(repo), "notes", "y" * 100)
    remember(project_dir(repo), "dormant", "d" * 160)
    remember(project_dir(repo), "cold", "c" * 300)

    # The other project has a memory of its own with the same name.
    write_index(project_dir(other), ["- **handoff** · project · 2026-11-01 · 250 — Another repo's handoff"])
    remember(project_dir(other), "handoff", "o" * 1000)

    # A chat-loop session of this project: a read, a comma list, a read of a
    # system memory's file.
    save_session("chat", working_directory: repo, updated_at: "2026-10-20T10:00:00.000Z", messages: [
      { "role" => "user", "content" => "go" },
      call("c1", "memory_read", { "name" => "handoff" }),
      result("c1", "[memory_read]\n#{"x" * 100}"),
      call("c2", "memory_read", { "name" => "handoff, notes" }),
      result("c2", "[memory_read]\n#{"x" * 100}#{SEP}#{"y" * 100}"),
      call("c3", "read", { "path" => File.join(system_dir, "identity.md") }),
      result("c3", "[read]\n#{"z" * 200}")
    ])

    # A native-loop session of another project: its joined result carries no
    # tool_call_id and its call is markup in the model entry. The chat call
    # after it reads that project's own handoff, not this one.
    save_session("native", working_directory: other, messages: [
      { "role" => "user", "content" => "go" },
      { "role" => "model",
        "content" => "<tool_call>\n<function=memory_read>\n<parameter=name>\nidentity\n</parameter>\n</function>\n</tool_call>" },
      { "role" => "tool_response", "content" => "[memory_read]\n#{"z" * 200}" },
      call("c4", "memory_read", { "name" => "handoff" }),
      result("c4", "[memory_read]\n#{"o" * 1000}")
    ])

    # A read saved when reads were cut.
    save_session("cut", working_directory: repo, updated_at: "2026-10-30T10:00:00.000Z", messages: [
      { "role" => "user", "content" => "go" },
      call("c5", "memory_read", { "name" => "big" }),
      result("c5", "[memory_read]\n#{"b" * 200}\n[cut: 100 of 300 chars; read it in parts]")
    ])

    # A session with no stored project_root, working in this project's folder.
    save_session("outside", working_directory: repo, updated_at: "2026-10-25T10:00:00.000Z", messages: [
      { "role" => "user", "content" => "go" },
      call("c6", "memory_read", { "name" => "dormant" }),
      result("c6", "[memory_read]\n#{"d" * 160}")
    ])

    # A name with no memory behind it, a test session, a session with no user
    # message: none of them count.
    save_session("ghost", working_directory: repo, updated_at: "2026-11-02T10:00:00.000Z", messages: [
      { "role" => "user", "content" => "go" },
      call("c7", "memory_read", { "name" => "gone" }),
      result("c7", "Error: memory not found: gone"),
      call("c8", "memory_read", { "name" => "phantom" }),
      result("c8", "[memory_read]\n#{"p" * 40}")
    ])
    save_session("testrun", working_directory: repo, test_run: true, messages: [
      { "role" => "user", "content" => "go" },
      call("c9", "memory_read", { "name" => "guide" }),
      result("c9", "[memory_read]\n#{"g" * 40}")
    ])
    save_session("nouser", working_directory: repo, messages: [
      call("c10", "memory_read", { "name" => "guide" }),
      result("c10", "[memory_read]\n#{"g" * 40}")
    ])
    File.write(File.join(state, "broken.json"), "{not json")
  end

  it "counts reads of both saved shapes, splitting a comma list by share" do
    build_fixture
    summary = report

    expect(summary.sessions).to eq(5)
    expect(summary.unreadable).to eq(1)
    expect(summary.days).to eq(13)
    expect(summary.read_names).to eq(5)
    expect(summary.read_count).to eq(8)
    expect(summary.read_tokens).to eq(313)
    expect(summary.cut_reads).to eq(1)

    expect(row(summary, "handoff", "project")).to eq(
      Samagotchi::MemoryUsage::Use.new(name: "handoff", scope: "project", tokens: 57, reads: 2, cut_reads: 0,
                                       bytes: 100, size_tokens: 25, source: nil)
    )
    expect(row(summary, "notes", "project").tokens).to eq(28)
    expect(row(summary, "identity", "system").reads).to eq(2)
    expect(row(summary, "identity", "system").tokens).to eq(106)
    expect(row(summary, "big", "system").cut_reads).to eq(1)
  end

  it "reads a memory's file as a read of that memory" do
    build_fixture
    summary = report

    expect(row(summary, "identity", "system").reads).to eq(2)
    expect(row(summary, "identity", "system").bytes).to eq(200)
    expect(row(summary, "identity", "system").size_tokens).to eq(50)
  end

  it "does not credit a project memory with another project's reads, and credits a system one across projects" do
    build_fixture
    summary = report

    # The other project's 1000-character handoff is not in this project's rows.
    expect(row(summary, "handoff", "project").reads).to eq(2)
    expect(summary.top.sum(&:tokens)).to eq(299) # the phantom read is in the total, not a row
    expect(row(summary, "identity", "system").reads).to eq(2)
  end

  it "gates a read of a memory's file by project, as memory_read is" do
    build_fixture
    # A session of the other project reads its own handoff's file: `memory_line`
    # sends the model to the file for a big memory, so these reads are normal.
    save_session("otherfile", working_directory: other, messages: [
      { "role" => "user", "content" => "go" },
      call("c11", "read", { "path" => File.join(project_dir(other), "handoff.md") }),
      result("c11", "[read]\n#{"o" * 1000}")
    ])

    summary = report
    expect(row(summary, "handoff", "project").reads).to eq(2)
    expect(summary.read_count).to eq(8) # the other project's read is counted nowhere, not as a row
    expect(summary.unknown_names).to eq(1)
    expect(index_of(summary, "project").unread_lines).to eq(1)
  end

  it "splits a comma list by every name asked for, the index's own text included" do
    write_index(project_dir(repo), ["- **a** · project · 2026-11-01 · 100 — A"])
    remember(project_dir(repo), "a", "x" * 400)
    asked = "[memory_read]\n#{"I" * 4000}#{SEP}#{"x" * 400}"
    save_session("list", working_directory: repo, messages: [
      { "role" => "user", "content" => "go" },
      call("c1", "memory_read", { "name" => "index, a" }),
      result("c1", asked)
    ])

    summary = report
    # WorkingSet divides the one result by both names; the index is not a row,
    # but it is one of the names the share is worked out over.
    expect(row(summary, "a", "project").tokens).to eq(((asked.length / 4.0) / 2).ceil)
    expect(summary.read_names).to eq(1)
    expect(summary.read_tokens).to eq(row(summary, "a", "project").tokens)
  end

  it "counts a read of an overlay's file as a read of the memory it overlays" do
    write_index(project_dir(repo), ["- **tips** · project · 2026-11-01 · 100 — Tips"])
    remember(project_dir(repo), "tips", "t" * 100)
    remember(project_dir(repo), "tips.qwen3-6", "o" * 80)
    save_session("overlay", working_directory: repo, messages: [
      { "role" => "user", "content" => "go" },
      call("c1", "read", { "path" => File.join(project_dir(repo), "tips.qwen3-6.md") }),
      result("c1", "[read]\n#{"o" * 80}")
    ])

    summary = report
    expect(row(summary, "tips", "project").reads).to eq(1)
    expect(summary.unknown_names).to eq(0)
    expect(summary.not_read).to eq([])
  end

  it "keeps a dotted name's own reads when it is a memory of its own" do
    write_index(project_dir(repo), [
      "- **notes** · project · 2026-11-01 · 40 — Notes",
      "- **notes.v2** · project · 2026-11-01 · 40 — The newer notes"
    ])
    remember(project_dir(repo), "notes", "n" * 40)
    remember(project_dir(repo), "notes.v2", "v" * 40)
    save_session("dotted", working_directory: repo, messages: [
      { "role" => "user", "content" => "go" },
      call("c1", "read", { "path" => File.join(project_dir(repo), "notes.v2.md") }),
      result("c1", "[read]\n#{"v" * 40}")
    ])

    summary = report
    expect(row(summary, "notes.v2", "project").reads).to eq(1)
    expect(row(summary, "notes", "project")).to be_nil
  end

  it "counts only memory lines in the index's unread fraction" do
    write_index(project_dir(repo), [
      "- **a** · project · 2026-11-01 · 40 — A",
      "- **Important**: always rebase first",
      "- **b**: a legacy line"
    ])
    remember(project_dir(repo), "a", "x" * 40)
    remember(project_dir(repo), "b", "y" * 40)
    save_session("prose", working_directory: repo, messages: [
      { "role" => "user", "content" => "go" },
      call("c1", "memory_read", { "name" => "a" }),
      result("c1", "[memory_read]\n#{"x" * 40}")
    ])

    summary = report
    index = index_of(summary, "project")
    # The heading and the bold prose line are neither denominator nor unread;
    # the legacy line of a memory that has a file is.
    expect(index.lines).to eq(2)
    expect(index.unread_lines).to eq(1)
    expect(summary.not_read.map(&:name)).to eq(%w[b])
  end

  it "reads a cut only where the cut marker is its own line" do
    write_index(project_dir(repo), ["- **a** · project · 2026-11-01 · 100 — A"])
    remember(project_dir(repo), "a", "x" * 400)
    save_session("mentions", working_directory: repo, messages: [
      { "role" => "user", "content" => "go" },
      call("c1", "memory_read", { "name" => "a" }),
      result("c1", "[memory_read]\nthe old log says: [cut: 5 chars not shown] here")
    ])
    save_session("reallycut", working_directory: repo, messages: [
      { "role" => "user", "content" => "go" },
      call("c2", "memory_read", { "name" => "a" }),
      result("c2", "[memory_read]\n#{"x" * 300}\n[cut: 100 of 400 chars; read it in parts]")
    ])

    summary = report
    expect(summary.cut_reads).to eq(1)
    expect(row(summary, "a", "project").cut_reads).to eq(1)
  end

  it "counts a session file with a project_root that is not a path as unreadable" do
    build_fixture
    File.write(File.join(state, "odd_root.json"), JSON.generate({
      "id" => "odd", "mode" => "assist", "model_name" => "gemma", "working_directory" => repo,
      "project_root" => 123, "messages" => [{ "role" => "user", "content" => "go" }],
      "created_at" => "2026-11-01T10:00:00.000Z", "updated_at" => "2026-11-01T10:00:00.000Z"
    }))

    sessions, unreadable = described_class.load_sessions(state_dir: state)
    expect(unreadable).to eq(2)
    expect(sessions.map(&:id)).not_to include("odd")
    summary = report
    expect(summary.sessions).to eq(5)
    expect(summary.unreadable).to eq(2)
  end

  it "counts the sessions it skips, so a run with nothing counted says so" do
    save_session("testrun", working_directory: repo, test_run: true, messages: [{ "role" => "user", "content" => "go" }])
    save_session("nouser", working_directory: repo, messages: [])
    File.write(File.join(state, "broken.json"), "{not json")

    sessions, unreadable = described_class.load_sessions(state_dir: state)
    summary = described_class.new(sessions: sessions, entries: [], unreadable: unreadable).report
    expect(summary.sessions).to eq(0)
    expect(summary.skipped).to eq(2)
    expect(summary.unreadable).to eq(1)
    expect(summary.to_h["skipped"]).to eq(2)
  end

  it "matches a session with no stored project_root by the folder it works in" do
    write_index(project_dir(loose), ["- **near** · project · 2026-11-01 · 10 — A memory in a folder that is no repo"])
    remember(project_dir(loose), "near", "n" * 40)
    save_session("loose", working_directory: loose, messages: [
      { "role" => "user", "content" => "go" },
      call("c1", "memory_read", { "name" => "near" }),
      result("c1", "[memory_read]\n#{"n" * 40}")
    ])

    summary = report(root: loose)
    expect(summary.sessions).to eq(1)
    expect(row(summary, "near", "project")).not_to be_nil
    expect(summary.not_read).to eq([])
  end

  it "lists the memories no counted session read, largest first, without a bundle's" do
    build_fixture
    summary = report

    expect(summary.not_read_total).to eq(7)
    expect(summary.not_read.map(&:name)).to eq(%w[cold guide])
    expect(summary.not_read.map(&:scope)).to eq(%w[project system])
    expect(summary.not_read.map(&:tokens)).to eq([75, 10])
  end

  it "counts a session's own used and preloaded names as read" do
    write_index(project_dir(repo), ["- **dormant** · project · 2026-11-01 · 40 — Never opened"])
    remember(project_dir(repo), "dormant", "d" * 160)
    write_index(system_dir, ["- **guide** · system · 2026-11-01 · 10 — The team's guide"])
    remember(system_dir, "guide", "g" * 40)
    save_session("pre", working_directory: repo, preloaded: ["project/dormant"], used: ["guide"], messages: [
      { "role" => "user", "content" => "go" }
    ])

    summary = report
    expect(summary.read_count).to eq(0)
    expect(summary.not_read).to eq([])
    expect(summary.not_read_total).to eq(2)
    expect(index_of(summary, "project").unread_lines).to eq(0)
    expect(index_of(summary, "system").unread_lines).to eq(0)
  end

  it "measures each scope's index against its limit" do
    build_fixture
    summary = report

    # Only the memory lines count: the "# Memory Index" heading is paid in
    # tokens, but it is not a memory line.
    expect(index_of(summary, "system").lines).to eq(4)
    expect(index_of(summary, "system").unread_lines).to eq(2)
    expect(index_of(summary, "system").unread_percent).to eq(50)
    expect(index_of(summary, "system").tokens).to eq((File.read(File.join(system_dir, "index.md")).length / 4.0).ceil)
    expect(index_of(summary, "system").limit).to eq(2500)
    expect(index_of(summary, "project").lines).to eq(4)
    expect(index_of(summary, "project").unread_lines).to eq(1)
  end

  it "counts a read whose name has no memory, but not as a row" do
    build_fixture
    summary = report

    expect(summary.unknown_names).to eq(1)
    expect(summary.top.map(&:name)).not_to include("phantom")
    expect(row(summary, "phantom", "system")).to be_nil
  end

  it "counts what config.yml's memories: preloads as used, not as unread" do
    write_index(system_dir, ["- **always** · system · 2026-11-01 · 10 — Preloaded by config"])
    remember(system_dir, "always", "a" * 100)

    summary = described_class.new(sessions: [], entries: Samagotchi::MemoryCommand.entries,
                                  baseline: ["system/always"]).report
    expect(summary.not_read.map(&:name)).to eq([])
    expect(summary.not_read_total).to eq(1)
    expect(summary.indexes.first.unread_lines).to eq(0)
  end

  it "reports nothing with no sessions to count" do
    summary = described_class.new(sessions: [], entries: []).report
    expect(summary.sessions).to eq(0)
    expect(summary.read_count).to eq(0)
    expect(summary.days).to eq(0)
    expect(summary.top).to eq([])
  end

  it "keeps --top rows per section" do
    build_fixture
    summary = report(top: 2)

    expect(summary.top.map(&:name)).to eq(%w[identity big])
    expect(summary.not_read.map(&:name)).to eq(%w[cold guide])
  end

  it "counts every unread memory past the row limit" do
    remember(project_dir(repo), "one", "x" * 40)
    remember(project_dir(repo), "two", "x" * 30)
    remember(project_dir(repo), "three", "x" * 20)
    save_session("s", working_directory: repo, messages: [{ role: "user", content: "hi" }])
    summary = report(top: 1)

    expect(summary.not_read.map(&:name)).to eq(%w[one])
    expect(summary.not_read_count).to eq(3)
  end

  it "doesn't let another project's used name vouch for this project's memory of that name" do
    remember(project_dir(repo), "shared_name", "x" * 40)
    save_session("s", working_directory: other, used: ["shared_name"],
                      messages: [{ role: "user", content: "hi" }])

    expect(report.not_read.map(&:name)).to eq(%w[shared_name])
  end

  it "marks a memory a bundle owns, and leaves it out of the not-read list" do
    write_index(system_dir, ["- **team** · system · 2026-11-01 · 20 · from team — A bundle's memory"])
    remember(system_dir, "team", "t" * 80)
    save_session("bundled", working_directory: repo, messages: [
      { "role" => "user", "content" => "go" },
      call("c1", "memory_read", { "name" => "team" }),
      result("c1", "[memory_read]\n#{"t" * 80}")
    ])

    summary = report
    expect(row(summary, "team", "system")).to eq(
      Samagotchi::MemoryUsage::Use.new(name: "team", scope: "system", tokens: 24, reads: 1, cut_reads: 0,
                                       bytes: 80, size_tokens: 20, source: "team")
    )
    expect(summary.not_read_total).to eq(0)
  end

  describe "the command" do
    def run(*argv)
      with_env("XDG_STATE_HOME" => File.join(tmp, "state")) do
        Dir.chdir(repo) { Samagotchi::MemoryCommand.new(argv, stdout: out, stderr: err).run }
      end
    end

    before { build_fixture }

    it "prints the sections, with the cut caveat and the unknown names" do
      expect(run("usage")).to eq(0)
      expect(out.string.lines.first).to eq("5 sessions over 13 days, 1 unreadable file skipped, 2 sessions not counted (test run or no user message)\n")
      expect(out.string).to include("Most read, by tokens (these 5 of 5: 96% of 313 read tokens)")
      expect(out.string).to include("note: 1 of these reads came back cut")
      expect(out.string).to include("Not read in saved sessions: 2 of 7 of your own memories")
      expect(out.string).to include("Names read that have no memory now: 1")
    end

    it "reports the same numbers as json" do
      expect(run("usage", "--format", "json")).to eq(0)
      json = JSON.parse(out.string)
      expect(json["sessions"]).to eq(5)
      expect(json["days"]).to eq(13)
      expect(json["reads"]).to eq({ "count" => 8, "tokens" => 313, "cut_reads" => 1, "names" => 5 })
      expect(json["indexes"].map { |index| index["scope"] }).to eq(%w[project system])
      expect(json["top"].first).to eq({ "name" => "identity", "scope" => "system", "tokens" => 106, "reads" => 2,
                                        "cut_reads" => 0, "bytes" => 200, "size_tokens" => 50, "source" => nil })
      expect(json["not_read"]).to eq({ "count" => 2, "total" => 7,
                                       "largest" => [{ "name" => "cold", "scope" => "project", "bytes" => 300,
                                                       "tokens" => 75 },
                                                     { "name" => "guide", "scope" => "system", "bytes" => 40,
                                                       "tokens" => 10 }] })
      expect(json["unknown_names"]).to eq(1)
    end

    it "takes one scope and a row limit" do
      expect(run("usage", "--scope", "system", "--top", "1", "--format", "json")).to eq(0)
      json = JSON.parse(out.string)
      expect(json["indexes"].map { |index| index["scope"] }).to eq(["system"])
      expect(json["top"].size).to eq(1)
      expect(json["not_read"]["largest"].map { |entry| entry["name"] }).to eq(["guide"])
      expect(json["not_read"]["total"]).to eq(3)
    end

    it "says so with nothing saved, and exits 0" do
      FileUtils.rm_rf(File.join(tmp, "state"))
      expect(run("usage")).to eq(0)
      expect(out.string).to eq("no sessions to count: nothing saved in #{File.join(tmp, "state", "samagotchi", "sessions")}\n")
    end

    it "says no reads when a session read nothing" do
      FileUtils.rm_rf(state)
      save_session("quiet", working_directory: repo, messages: [{ "role" => "user", "content" => "go" }])
      expect(run("usage")).to eq(0)
      expect(out.string).to include("1 session over 0 days")
      expect(out.string).to include("No memory reads in these sessions.")
      expect(out.string).not_to include("Most read")
    end

    it "refuses a bad --top, a stray NAME and an unknown format" do
      expect(run("usage", "--top", "0")).to eq(2)
      expect(run("usage", "--top", "abc")).to eq(2)
      expect(run("usage", "extra")).to eq(2)
      expect(run("usage", "--format", "yaml")).to eq(2)
      expect(err.string.lines.map(&:chomp)).to eq([
        "chi memory usage: --top must be a positive integer (see chi memory usage --help)",
        "chi memory usage: --top must be a positive integer (see chi memory usage --help)",
        "chi memory usage: usage takes no NAME (unexpected extra) (see chi memory usage --help)",
        "chi memory usage: unknown format \"yaml\": use --format text|json (see chi memory usage --help)"
      ])
    end

    it "counts config.yml's memories: baseline as used" do
      config = File.join(tmp, "config", "samagotchi", "config.yml")
      File.write(config, "#{File.read(config)}memories:\n  - system/guide\n")
      expect(run("usage", "--format", "json")).to eq(0)
      json = JSON.parse(out.string)
      expect(json["not_read"]["count"]).to eq(1)
      expect(json["not_read"]["largest"].map { |entry| entry["name"] }).to eq(["cold"])
    end

    it "says what is in the dir when nothing is counted" do
      FileUtils.rm_rf(state)
      save_session("testrun", working_directory: repo, test_run: true, messages: [{ "role" => "user", "content" => "go" }])
      save_session("nouser", working_directory: repo, messages: [])
      File.write(File.join(state, "broken.json"), "{not json")

      expect(run("usage")).to eq(0)
      expect(out.string).to eq("no sessions to count: 1 file that could not be read and 2 sessions not counted " \
                               "(test runs or no user message) in #{File.join(tmp, "state", "samagotchi", "sessions")}\n")
    end

    it "counts the system memories every prompt carries as used, not unread" do
      write_index(system_dir, [
        "- **identity** · system · 2026-11-01 · 10 — Who chi is",
        "- **never opened** · system · 2026-11-01 · 160 — Nobody reads it"
      ])
      remember(system_dir, "identity", "i" * 40)
      FileUtils.rm_rf(state)
      save_session("quiet", working_directory: repo, messages: [{ "role" => "user", "content" => "go" }])

      expect(run("usage", "--format", "json")).to eq(0)
      json = JSON.parse(out.string)
      system = json["indexes"].find { |index| index["scope"] == "system" }
      expect(system["unread_lines"]).to eq(1)
      expect(json["not_read"]["largest"].map { |entry| entry["name"] }).not_to include("identity")
      expect(json["not_read"]["largest"].map { |entry| entry["name"] }).to include("never opened")
    end

    it "prints - where a counted read's memory has no file" do
      write_index(project_dir(repo), ["- **ghost** · project · 2026-11-01 · 9 KB — A line whose file is gone"])
      save_session("ghostread", working_directory: repo, messages: [
        { "role" => "user", "content" => "go" },
        call("c1", "memory_read", { "name" => "ghost", "scope" => "project" }),
        result("c1", "[memory_read]\n#{"g" * 90}")
      ])

      expect(run("usage", "--format", "json")).to eq(0)
      ghost = JSON.parse(out.string)["top"].find { |row| row["name"] == "ghost" }
      expect(ghost).to eq({ "name" => "ghost", "scope" => "project", "tokens" => 26, "reads" => 1,
                            "cut_reads" => 0, "bytes" => nil, "size_tokens" => nil, "source" => nil })
      expect(run("usage")).to eq(0)
      expect(out.string).to match(/^  ghost\s+\d+\s+1\s+-\s+project$/)
    end

    it "prints no empty table when every read is of a name with no memory" do
      FileUtils.rm_rf(state)
      save_session("phantom", working_directory: repo, messages: [
        { "role" => "user", "content" => "go" },
        call("c1", "memory_read", { "name" => "phantom" }),
        result("c1", "[memory_read]\n#{"p" * 40}")
      ])

      expect(run("usage")).to eq(0)
      expect(out.string).to include("Most read, by tokens: none of these reads names a memory still there (1 name read, 14 tokens)")
      expect(out.string).not_to include("Memory  tokens  reads  size  scope  from")
    end

    it "refuses a --top bigger than the report can hold" do
      expect(run("usage", "--top", "99999999999999999999")).to eq(2)
      expect(run("usage", "--top", "1001")).to eq(2)
      expect(run("usage", "--top", "1000")).to eq(0)
      expect(err.string.lines.map(&:chomp)).to eq([
        "chi memory usage: --top must be at most 1000 (see chi memory usage --help)",
        "chi memory usage: --top must be at most 1000 (see chi memory usage --help)"
      ])
    end

    it "tolerates an index with a byte that isn't valid UTF-8" do
      File.write(File.join(project_dir(repo), "index.md"),
                 "# Memory Index\n\n- **a** · project · 2026-11-01 · 10 — A \xFF note\n".b)
      expect(run("usage", "--format", "json")).to eq(0)
      expect(JSON.parse(out.string)["indexes"].first["lines"]).to eq(1)
      expect(run("ls", "--scope", "project")).to eq(0)
      expect(out.string).to include("  a  ")
    end

    it "writes nothing to the sessions or the memories" do
      first = [snapshot(state), snapshot(system_dir), snapshot(project_dir(repo))]
      run("usage")
      expect([snapshot(state), snapshot(system_dir), snapshot(project_dir(repo))]).to eq(first)
    end
  end
end
