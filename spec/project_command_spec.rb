# frozen_string_literal: true

require "fileutils"
require "open3"
require "stringio"
require "tmpdir"
require "samagotchi/project_command"
require "samagotchi/session_row"

RSpec.describe Samagotchi::ProjectCommand do
  around do |example|
    Dir.mktmpdir("project-command") do |tmp|
      @tmp = File.realpath(tmp)
      example.run
    end
  end

  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:home) { File.join(@tmp, "home").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:env) { { "XDG_CONFIG_HOME" => File.join(@tmp, "xdg") } }
  let(:projects) { File.join(@tmp, "xdg", "samagotchi", "memories", "projects") }
  let(:rows) { [] }

  def run(*argv, cwd: @tmp)
    described_class.new(argv, stdout: out, stderr: err, cwd: cwd, env: env, home: home, sessions: -> { rows }).run
  end

  def key(root) = Samagotchi::MemoryPaths.key_for_root(root)
  def marker(dir) = File.join(dir, ".chi", "project.yml")

  def git_init(dir)
    output, status = Open3.capture2e("git", "init", "-q", dir)
    raise "git init failed: #{output}" unless status.success?
  end

  def session_row(id, cwd, live:)
    instance_double(Samagotchi::SessionRow, id: id, cwd: cwd, live: live)
  end

  describe "init" do
    it "marks the folder, creating it when missing, and names its root and memories folder" do
      notes = File.join(@tmp, "notes")

      expect(run("init", notes)).to eq(0), err.string
      expect(File.read(marker(notes))).to eq(described_class::MARKER_TEXT)
      expect(out.string).to eq("#{notes} is now a chi project (#{marker(notes)})\n" \
                               "memories #{File.join(projects, key(notes))}\n")
    end

    it "defaults to this folder and counts the memories already in its folder" do
      notes = File.join(@tmp, "notes").tap { |dir| FileUtils.mkdir_p(dir) }
      FileUtils.mkdir_p(File.join(projects, key(notes)))
      %w[a.md b.md index.md].each { |name| File.write(File.join(projects, key(notes), name), "x") }

      expect(run("init", cwd: notes)).to eq(0), err.string
      expect(out.string.lines.last).to eq("memories #{File.join(projects, key(notes))} (2 memories)\n")
    end

    it "writes nothing in a git repository, and says the repository is the project" do
      repo = File.join(@tmp, "repo")
      git_init(repo)

      expect(run("init", File.join(repo, "sub"))).to eq(0)
      expect(Dir.exist?(File.join(repo, "sub"))).to be(false)
      expect(Dir.exist?(File.join(repo, ".chi"))).to be(false)
      expect(out.string).to eq("#{repo}/sub is in the git repository #{repo}: the repository already is the project, " \
                               "nothing written\n")
    end

    it "says when the folder already is one" do
      notes = File.join(@tmp, "notes")
      run("init", notes)
      out.truncate(0)
      out.rewind

      expect(run("init", notes)).to eq(0)
      expect(out.string).to eq("#{notes} is already a chi project\n")
    end

    it "refuses $HOME, a folder above it and /, writing nothing" do
      [home, @tmp, "/"].each do |dir|
        expect(run("init", dir)).to eq(1)
        expect(File.exist?(marker(dir))).to be(false)
      end
      expect(err.string.lines.first).to eq("chi project init: #{home} is $HOME, a folder above it or /: it can't be a chi " \
                                           "project (every folder under it would be one); mark a folder inside it\n")
    end

    it "marks a folder inside another marked project as its own project, nested in it" do
      outer = File.join(@tmp, "outer")
      run("init", outer)
      out.truncate(0)
      out.rewind

      expect(run("init", File.join(outer, "inner"))).to eq(0)
      expect(out.string.lines.first).to eq("#{outer}/inner is now a chi project, its own project nested in #{outer} " \
                                           "(#{marker(File.join(outer, "inner"))})\n")
    end

    it "names the running sessions in the folder to restart, and the chi web restart for the saved ones" do
      notes = File.join(@tmp, "notes")
      FileUtils.mkdir_p(File.join(notes, "sub"))
      git_init(File.join(notes, "repo"))
      FileUtils.mkdir_p(File.join(notes, "inner", ".chi"))
      File.write(marker(File.join(notes, "inner")), "")
      rows.push(session_row("aaaaaaaa-1", File.join(notes, "sub"), live: true),
                session_row("dddddddd-4", File.join(notes, "repo"), live: true),
                session_row("eeeeeeee-5", File.join(notes, "inner"), live: true),
                session_row("bbbbbbbb-2", notes, live: false),
                session_row("cccccccc-3", File.join(@tmp, "notes-other"), live: true))

      expect(run("init", notes)).to eq(0)
      expect(out.string.lines.last(2)).to eq(
        ["running sessions in it keep the old project in their prompt until restarted (chi sessions restart ID): aaaaaaaa\n",
         "2 saved session(s) in it join the project in a running chi web after its restart\n"]
      )
    end

    it "takes one folder at most" do
      expect(run("init", "a", "b")).to eq(2)
      expect(err.string).to include("init takes one folder")
    end
  end

  describe "show" do
    it "says marker, the root, the top and the memories folder, from a subfolder" do
      notes = File.join(@tmp, "notes")
      run("init", notes)
      out.truncate(0)
      out.rewind
      FileUtils.mkdir_p(File.join(notes, "sub"))

      expect(run(cwd: File.join(notes, "sub"))).to eq(0)
      expect(out.string).to eq("kind     marker\nroot     #{notes}\ntop      #{notes}\n" \
                               "memories #{File.join(projects, key(notes))}\n")
    end

    it "says git, and that a marker inside the repository is ignored" do
      repo = File.join(@tmp, "repo")
      git_init(repo)
      FileUtils.mkdir_p(File.join(repo, "sub", ".chi"))
      File.write(marker(File.join(repo, "sub")), "")

      expect(run(cwd: File.join(repo, "sub"))).to eq(0)
      expect(out.string).to eq("kind     git\nroot     #{repo}\ntop      #{repo}\nmemories #{File.join(projects, key(repo))}\n" \
                               "note     #{marker(File.join(repo, "sub"))} is ignored: the git repository is the project\n")
    end

    it "says when $HOME is a git repository" do
      git_init(home)
      work = File.join(home, "work").tap { |dir| FileUtils.mkdir_p(dir) }

      run(cwd: work)
      expect(out.string).to include("note     #{home} is $HOME, a git repository: every folder under it is in that repository\n")
    end

    it "says none outside both, with the folder's own memories folder" do
      plain = File.join(@tmp, "plain").tap { |dir| FileUtils.mkdir_p(dir) }

      expect(run(cwd: plain)).to eq(0)
      expect(out.string).to eq("kind     none\nmemories #{File.join(projects, key(plain))}\n" \
                               "note     no git repository or chi project marker here: chi project init makes this folder a project\n")
    end
  end
end
