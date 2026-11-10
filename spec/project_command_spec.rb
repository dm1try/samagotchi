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
  def id_of(dir) = Samagotchi::MemoryPaths.lookup(dir, home: home).id
  def marker(dir) = File.join(dir, ".chi", "project.yml")

  def git_init(dir)
    output, status = Open3.capture2e("git", "init", "-q", dir)
    raise "git init failed: #{output}" unless status.success?
  end

  def session_row(id, cwd, live:, project: nil)
    instance_double(Samagotchi::SessionRow, id: id, cwd: cwd, live: live, project: project)
  end

  describe "init" do
    it "marks the folder, creating it when missing, and names its root and memories folder" do
      notes = File.join(@tmp, "notes")

      expect(run("init", notes)).to eq(0), err.string
      id = id_of(notes)
      expect(id).to match(/\Anotes-\h{8}\z/)
      expect(File.read(marker(notes))).to eq("#{Samagotchi::ProjectInit::MARKER_TEXT}id: #{id}\n")
      expect(out.string).to eq("#{notes} is now a chi project (#{marker(notes)})\nid       #{id}\n" \
                               "memories #{File.join(projects, id)}\n")
    end

    it "defaults to this folder and keeps the memories already in its folder: moved to the id, the old name a link" do
      notes = File.join(@tmp, "notes").tap { |dir| FileUtils.mkdir_p(dir) }
      FileUtils.mkdir_p(File.join(projects, key(notes)))
      %w[a.md b.md index.md].each { |name| File.write(File.join(projects, key(notes), name), "x") }

      expect(run("init", cwd: notes)).to eq(0), err.string
      id = id_of(notes)
      expect(out.string.lines.drop(1)).to eq([
        "id       #{id}\n",
        "memories #{File.join(projects, id)} (2 memories)\n",
        "moved #{File.join(projects, key(notes))} to #{File.join(projects, id)} (the old name links to it, for an older chi)\n"
      ])
      expect(File.readlink(File.join(projects, key(notes)))).to eq(id)
    end

    it "adopts an id for an older marker, refused while a session of the project runs" do
      notes = File.join(@tmp, "notes")
      FileUtils.mkdir_p(File.dirname(marker(notes)))
      File.write(marker(notes), "")
      FileUtils.mkdir_p(File.join(projects, key(notes)))
      rows.push(session_row("aaaaaaaa-1", notes, live: true, project: notes))

      expect(run("init", notes)).to eq(1)
      expect(err.string).to start_with("chi project init: #{notes} has running sessions (aaaaaaaa): stop them")
      expect(id_of(notes)).to be_nil

      rows.clear
      expect(run("init", notes)).to eq(0), err.string
      id = id_of(notes)
      expect(out.string.lines.map(&:chomp)).to eq([
        "#{notes} now has the chi project id #{id}: its memories and project context stay with it when the folder " \
        "moves or is renamed",
        "moved #{File.join(projects, key(notes))} to #{File.join(projects, id)} (the old name links to it, for an older chi)"
      ])
    end

    it "gives a marked folder its own id with --new-id, and refuses it elsewhere" do
      notes = File.join(@tmp, "notes")
      run("init", notes)
      id = id_of(notes)
      FileUtils.mkdir_p(File.join(projects, id))
      File.write(File.join(projects, id, "a.md"), "x")
      out.truncate(0)
      out.rewind

      expect(run("init", "--new-id", notes)).to eq(0), err.string
      fresh = id_of(notes)
      expect(out.string).to eq("#{notes} has a chi project id of its own now: #{fresh} (was #{id})\n" \
                               "copied #{File.join(projects, id)} to #{File.join(projects, fresh)}\n")
      expect(run("init", "--new-id", @tmp)).to eq(1)
      expect(err.string).to eq("chi project init --new-id: #{@tmp} is not a marked chi project folder: --new-id gives " \
                               "one (made with chi project init) an id of its own\n")
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
      expect(out.string).to eq("#{notes} is already a chi project (id #{id_of(notes)})\n")
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

    it "names memories saved from a subfolder before init, pointing at --merge-subfolders" do
      notes = File.join(@tmp, "notes")
      sub = File.join(notes, "sub").tap { |dir| FileUtils.mkdir_p(dir) }
      FileUtils.mkdir_p(File.join(projects, key(sub)))
      File.write(File.join(projects, key(sub), "a.md"), "a")
      rows.push(session_row("aaaaaaaa-1", sub, live: false, project: sub))

      expect(run("init", notes)).to eq(0), err.string
      expect(out.string).to include("memories saved from subfolders before init: #{sub} (1 memory); move them " \
                                    "into the project with chi project init --merge-subfolders\n")
    end

    describe "--merge-subfolders" do
      let(:notes) { File.join(@tmp, "notes") }
      let(:sub) { File.join(notes, "sub").tap { |dir| FileUtils.mkdir_p(dir) } }
      let(:old) { File.join(projects, key(sub)) }

      before do
        FileUtils.mkdir_p(old)
        File.write(File.join(old, "a.md"), "a")
      end

      it "marks the folder when it isn't yet and moves the subfolder's memories into the project" do
        rows.push(session_row("aaaaaaaa-1", sub, live: false, project: sub))

        expect(run("init", "--merge-subfolders", notes)).to eq(0), err.string
        target = File.join(projects, id_of(notes))
        expect(out.string).to include("#{notes} is now a chi project")
        expect(out.string).not_to include("memories saved from subfolders before init")
        expect(out.string.lines.last(2)).to eq(["moved 1 memory saved from #{sub} into #{target}: a\n",
                                                "removed the emptied #{old}\n"])
        expect(File.read(File.join(target, "a.md"))).to eq("a")
      end

      it "is refused, moving nothing, while a session in a subfolder runs" do
        run("init", notes)
        rows.push(session_row("aaaaaaaa-1", sub, live: true, project: sub))

        expect(run("init", "--merge-subfolders", notes)).to eq(1)
        expect(err.string).to start_with("chi project init: #{notes} has running sessions (aaaaaaaa): stop them " \
                                         "(chi sessions stop ID) and rerun chi project init --merge-subfolders")
        expect(File.exist?(File.join(old, "a.md"))).to be(true)
      end

      it "says when nothing was found, and takes no --new-id with it" do
        run("init", notes)
        out.truncate(0)
        out.rewind
        expect(run("init", "--merge-subfolders", notes)).to eq(0)
        expect(out.string.lines.last).to eq("no memories saved from subfolders before init to move\n")

        expect(run("init", "--merge-subfolders", "--new-id", notes)).to eq(2)
        expect(err.string).to include("--merge-subfolders and --new-id")
      end
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
      expect(out.string).to eq("kind     marker\nroot     #{notes}\ntop      #{notes}\nid       #{id_of(notes)}\n" \
                               "memories #{File.join(projects, id_of(notes))}\n")
    end

    it "notes memories saved from a subfolder before init" do
      notes = File.join(@tmp, "notes")
      run("init", notes)
      out.truncate(0)
      out.rewind
      sub = File.join(notes, "sub").tap { |dir| FileUtils.mkdir_p(dir) }
      FileUtils.mkdir_p(File.join(projects, key(sub)))
      File.write(File.join(projects, key(sub), "a.md"), "a")
      rows.push(session_row("aaaaaaaa-1", sub, live: false, project: sub))

      expect(run(cwd: sub)).to eq(0)
      expect(out.string.lines.last).to eq("note     memories saved from subfolders before init: #{sub} (1 memory); " \
                                          "move them into the project with chi project init --merge-subfolders\n")
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
