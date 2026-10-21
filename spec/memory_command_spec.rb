# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "spec_helper"
require "samagotchi/memory_command"

RSpec.describe Samagotchi::MemoryCommand do
  let(:tmp) { Dir.mktmpdir("memory-command") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
  let(:project_dir) { File.join(tmp, "project-memories") }
  let(:trash_root) { File.join(system_dir, ".bundles", ".trash") }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:write) { Samagotchi::Tools::MemoryWrite }

  around { |example| with_config_home(File.join(tmp, "config")) { example.run } }

  before { allow(Samagotchi::MemoryPaths).to receive(:project_dir).and_return(project_dir) }

  after { FileUtils.rm_rf(tmp) }

  def run(*argv) = described_class.new(argv, stdout: out, stderr: err).run
  def remember(name, scope, description: nil, body: "#{name}\n") = write.call(body, path: name, scope: scope, description: description)
  def index(scope) = File.read(File.join(scope == "project" ? project_dir : system_dir, "index.md"))
  def today = Date.today.iso8601

  it "prints its usage, and refuses an unknown subcommand, scope, format or a stray argument" do
    expect(run).to eq(0)
    expect(out.string).to start_with("Usage: chi memory <ls|rm> [options]")
    expect(run("help")).to eq(0)

    expect(run("mv")).to eq(2)
    expect(run("ls", "--scope", "team")).to eq(2)
    expect(run("ls", "--format", "yaml")).to eq(2)
    expect(run("ls", "extra")).to eq(2)
    expect(run("rm")).to eq(2)
    expect(run("rm", "a", "b")).to eq(2)
    expect(err.string.lines).to eq([
      "chi memory: unknown subcommand mv (see chi memory --help)\n",
      "chi memory ls: unknown scope \"team\": use --scope project|system (see chi memory ls --help)\n",
      "chi memory ls: unknown format \"yaml\": use --format text|json (see chi memory ls --help)\n",
      "chi memory ls: ls takes no NAME (unexpected extra) (see chi memory ls --help)\n",
      "chi memory rm: give the memory's NAME (see chi memory rm --help)\n",
      "chi memory rm: rm takes one NAME (unexpected b) (see chi memory rm --help)\n"
    ])
  end

  describe "ls" do
    it "lists both scopes, project first, with sizes, dates, owners, descriptions and overlays" do
      remember("handoff", "project", description: "Where the work stands")
      write.call("tuned\n", path: "handoff", scope: "project", current_model_only: true, model_key: "qwen3-6")
      remember("identity", "system", description: "Who chi is")
      File.write(File.join(system_dir, "index.md"),
                 "#{index("system")}- **guide** · system · 2026-10-03 · 9 · from team — The team's guide\n" \
                 "- **Important** prose that isn't a memory\n- **legacy**: an old line\n")
      File.write(File.join(system_dir, "guide.md"), "guide\n")
      File.write(File.join(system_dir, "legacy.md"), "old\n")
      File.write(File.join(system_dir, "loose.md"), "by hand\n")
      File.write(File.join(project_dir, "index.md"), "#{index("project")}- **gone** · project · 2026-10-01 · 4\n")

      expect(run("ls")).to eq(0)

      expect(out.string).to eq(<<~TEXT)
        project  gone         2026-10-01             [no file]
        project  handoff   8  #{today}             Where the work stands [overlays: qwen3-6]
        system   guide     6  2026-10-03  from team  The team's guide
        system   identity  9  #{today}             Who chi is
        system   legacy    4  #{today}             an old line
        system   loose     8  #{today}             [no index line]
      TEXT
    end

    it "leaves out an index line whose name is a path, which rm would refuse" do
      remember("notes", "system")
      File.write(File.join(system_dir, "index.md"), "#{index("system")}- **../../x** · system · 2026-10-01 · 4\n- **a\\b** · system · 2026-10-01 · 4\n")

      expect(run("ls", "--format", "json")).to eq(0)
      expect(JSON.parse(out.string).map { |row| row["name"] }).to eq(%w[notes])
    end

    it "lists thousands of memories with overlays in well under a second" do
      FileUtils.mkdir_p(system_dir)
      lines = (1..2000).map do |i|
        File.write(File.join(system_dir, "m#{i}.md"), "x\n")
        File.write(File.join(system_dir, "m#{i}.k-#{i % 3}.md"), "o\n") if i.even?
        "- **m#{i}** · system · 2026-10-01 · 2 — memory #{i}"
      end
      File.write(File.join(system_dir, "index.md"), "# Memory Index\n\n#{lines.join("\n")}\n")

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(run("ls", "--scope", "system", "--format", "json")).to eq(0)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      rows = JSON.parse(out.string)
      expect(rows.size).to eq(2000)
      expect(rows.find { |row| row["name"] == "m2" }["overlays"]).to eq(%w[k-2])
      expect(elapsed).to be < 1.5
    end

    it "lists one scope with --scope, as JSON with --format json, and says when there are none" do
      remember("handoff", "project", description: "x" * 70)
      remember("identity", "system")

      expect(run("ls", "--scope", "project", "--format", "json")).to eq(0)
      expect(JSON.parse(out.string)).to eq([{
        "name" => "handoff", "scope" => "project", "path" => File.join(project_dir, "handoff.md"), "bytes" => 8,
        "date" => today, "source" => nil, "description" => "x" * 70, "overlays" => [], "indexed" => true, "file" => true
      }])

      out.truncate(0)
      out.rewind
      expect(run("ls", "--scope", "project")).to eq(0)
      expect(out.string).to eq("project  handoff  8  #{today}  #{"x" * 59}…\n")

      FileUtils.rm_rf(project_dir)
      out.truncate(0)
      out.rewind
      expect(run("ls", "--scope", "project")).to eq(0)
      expect(out.string).to eq("no memories in project scope\n")
    end
  end

  describe "rm" do
    it "moves the memory and its model overlays to the bundle trash and drops its index line, saying where" do
      remember("handoff", "project", description: "Where the work stands")
      remember("keep", "project")
      write.call("tuned\n", path: "handoff", scope: "project", current_model_only: true, model_key: "qwen3-6")

      expect(run("rm", "handoff")).to eq(0)

      trash = Dir.glob(File.join(trash_root, "memory-handoff-*")).first
      expect(out.string).to eq("Memory 'handoff' removed from project scope: moved to #{trash} " \
                               "(`chi bundle trash` lists and empties it); index line dropped.\n")
      expect(Dir.children(trash).sort).to eq(%w[handoff.md handoff.qwen3-6.md])
      expect(Dir.children(project_dir).grep(/\.md\z/).sort).to eq(%w[index.md keep.md])
      expect(index("project")).not_to include("handoff")
    end

    it "refuses a name in both scopes without --scope, naming both, and takes the one --scope names" do
      remember("notes", "project")
      remember("notes", "system")

      expect(run("rm", "notes")).to eq(2)
      expect(err.string).to eq("chi memory rm: notes is in both scopes: chi memory rm notes --scope project, " \
                               "or --scope system (see chi memory rm --help)\n")
      expect(File.exist?(File.join(project_dir, "notes.md"))).to be(true)

      expect(run("rm", "notes", "--scope", "system")).to eq(0)
      expect([File.exist?(File.join(project_dir, "notes.md")), File.exist?(File.join(system_dir, "notes.md"))]).to eq([true, false])
    end

    it "fails for a name in neither scope, a bundle's memory, the index and a path" do
      remember("guide", "system")
      File.write(File.join(system_dir, "index.md"), index("system").sub(/(\*\*guide\*\* · .*)$/, "\\1 · from team"))

      expect(run("rm", "nope")).to eq(1)
      expect(run("rm", "guide")).to eq(1)
      expect(run("rm", "index", "--scope", "system")).to eq(1)
      expect(run("rm", "../x")).to eq(1)
      expect(err.string.lines).to eq([
        "chi memory rm: no memory 'nope' in project or system scope\n",
        "chi memory rm: memory 'guide' came from bundle team; `chi bundle uninstall team` removes it\n",
        "chi memory rm: the index can't be removed; it is kept up to date for you\n",
        "chi memory rm: invalid memory name '../x': use a plain name (no /, \\ or ..)\n"
      ])
      expect(File.exist?(File.join(system_dir, "guide.md"))).to be(true)
    end

    it "removes one model overlay alone by NAME.KEY, leaving its memory and index line" do
      remember("handoff", "project")
      write.call("tuned\n", path: "handoff", scope: "project", current_model_only: true, model_key: "qwen3-6")

      expect(run("rm", "handoff.qwen3-6")).to eq(0)

      expect(out.string).to end_with("(`chi bundle trash` lists and empties it).\n")
      expect(Dir.children(project_dir).grep(/\.md\z/).sort).to eq(%w[handoff.md index.md])
      expect(index("project")).to include("**handoff**")
    end
  end
end
