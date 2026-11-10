# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "samagotchi/project_init"

RSpec.describe Samagotchi::ProjectInit do
  around do |example|
    Dir.mktmpdir("project-init") do |tmp|
      @tmp = File.realpath(tmp)
      example.run
    end
  end

  let(:home) { File.join(@tmp, "home").tap { |dir| FileUtils.mkdir_p(dir) } }

  def marker(dir) = File.join(dir, Samagotchi::MemoryPaths::MARKER)

  def git_init(dir)
    output, status = Open3.capture2e("git", "init", "-q", dir)
    raise "git init failed: #{output}" unless status.success?
  end

  it "creates a project at the real path" do
    target = File.join(@tmp, "notes")
    File.symlink(@tmp, File.join(@tmp, "link"))

    outcome = described_class.call(File.join(@tmp, "link", "notes"), home: home)

    expect([outcome.kind, outcome.reason, outcome.root, outcome.top, outcome.nested_in]).to eq(
      [:created, nil, target, target, nil]
    )
    expect(outcome.message).to be_nil
    expect(outcome.id).to match(/\Anotes-\h{8}\z/)
    expect(File.read(marker(target))).to eq("#{described_class::MARKER_TEXT}id: #{outcome.id}\n")
    expect(Samagotchi::MemoryPaths.lookup(target, home: home).id).to eq(outcome.id)
  end

  it "creates a project nested inside a marked project" do
    outer = File.join(@tmp, "outer")
    FileUtils.mkdir_p(File.dirname(marker(outer)))
    File.write(marker(outer), "")

    outcome = described_class.call(File.join(outer, "inner"), home: home)

    expect([outcome.kind, outcome.root, outcome.nested_in]).to eq(
      [:created, File.join(outer, "inner"), outer]
    )
    expect(outcome.message).to be_nil
  end

  it "returns the git root and top without writing a marker" do
    repo = File.join(@tmp, "repo")
    git_init(repo)

    outcome = described_class.call(File.join(repo, "new"), home: home)

    expect([outcome.kind, outcome.root, outcome.top]).to eq([:git, repo, repo])
    expect(outcome.message).to eq("#{repo}/new is in the git repository #{repo}: the repository already is the " \
                                  "project, nothing written")
    expect(File.exist?(marker(repo))).to be(false)
  end

  it "recognizes an already-marked folder" do
    target = File.join(@tmp, "notes")
    FileUtils.mkdir_p(File.dirname(marker(target)))
    File.write(marker(target), "")

    outcome = described_class.call(target, home: home)

    expect([outcome.kind, outcome.root, outcome.top]).to eq([:already_marked, target, target])
    expect(outcome.message).to eq("#{target} is already a chi project")
  end

  it "refuses home and folders above it" do
    [home, @tmp, "/"].each do |target|
      outcome = described_class.call(target, home: home)

      expect([outcome.kind, outcome.reason]).to eq(%i[refused above_home])
      expect(outcome.message).to include("is $HOME, a folder above it or /")
    end
  end

  it "returns a write failure when an existing file blocks the path" do
    target = File.join(@tmp, "file")
    File.write(target, "")

    outcome = described_class.call(File.join(target, "child"), home: home)

    expect([outcome.kind, outcome.reason]).to eq(%i[refused write_failed])
    expect(outcome.message).to include("couldn't write #{marker(File.join(target, "child"))}")
  end

  describe "ids: .adopt and .new_id" do
    let(:env) { { "XDG_CONFIG_HOME" => File.join(@tmp, "xdg") } }
    let(:state_dir) { File.join(@tmp, "state", "samagotchi", "sessions") }
    let(:projects) { Samagotchi::MemoryPaths.projects_dir(env: env) }
    let(:contexts) { File.join(@tmp, "state", "samagotchi", "context", "projects") }
    let(:history) { File.join(@tmp, "state", "samagotchi", "plugins", "skills", "history") }
    let(:notes) do
      File.join(@tmp, "notes").tap do |dir|
        FileUtils.mkdir_p(File.dirname(marker(dir)))
        File.write(marker(dir), "# an older marker\nother: kept\n")
      end
    end
    let(:path_key) { Samagotchi::MemoryPaths.key_for_root(notes) }

    def remember(dir, name, text = "x")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, name), text)
    end

    def adopt(dir = notes, sessions: []) = described_class.adopt(dir, home: home, env: env, state_dir: state_dir, sessions: sessions)

    def row(id, project, live:) = Struct.new(:id, :project, :live, keyword_init: true).new(id: id, project: project, live: live)

    it "moves an older marker's folders to a new id, links the old names to them, then writes the id" do
      remember(File.join(projects, path_key), "notes.md", "remembered")
      remember(File.join(contexts, path_key), "ci.json", "{}")
      remember(File.join(history, "project-#{path_key}", "skill_x"), "1.md")

      outcome = adopt

      id = outcome.id
      expect([outcome.kind, id]).to match([:adopted, /\Anotes-\h{8}\z/])
      expect(File.read(marker(notes))).to eq("# an older marker\nother: kept\nid: #{id}\n")
      expect(Samagotchi::MemoryPaths.lookup(notes, home: home).id).to eq(id)
      [[projects, ""], [contexts, ""], [history, "project-"]].each do |base, prefix|
        expect(File.directory?(File.join(base, "#{prefix}#{id}"))).to be(true)
        expect(File.readlink(File.join(base, "#{prefix}#{path_key}"))).to eq("#{prefix}#{id}")
      end
      # The memory tools' folder (the id) and an older chi's (the path key, through the link) hold the same memory.
      expect(File.read(File.join(Samagotchi::MemoryPaths.project_dir(env: env, cwd: notes), "notes.md"))).to eq("remembered")
      expect(File.read(File.join(projects, path_key, "notes.md"))).to eq("remembered")
      expect(outcome.message.lines.map(&:chomp)).to eq([
        "#{notes} now has the chi project id #{id}: its memories and project context stay with it when the folder " \
        "moves or is renamed",
        "moved #{File.join(projects, path_key)} to #{File.join(projects, id)} (the old name links to it, for an older chi)",
        "moved #{File.join(contexts, path_key)} to #{File.join(contexts, id)} (the old name links to it, for an older chi)",
        "moved #{File.join(history, "project-#{path_key}")} to #{File.join(history, "project-#{id}")} (the old name " \
        "links to it, for an older chi)"
      ])
    end

    it "only writes the id when no folder has the path key yet: no move, no link to a missing folder" do
      outcome = adopt

      expect(outcome.kind).to eq(:adopted)
      expect(outcome.message.lines.size).to eq(1)
      expect([File.exist?(File.join(projects, path_key)), File.symlink?(File.join(projects, path_key))]).to eq([false, false])
      expect(Dir.exist?(contexts)).to be(false)
    end

    it "marks a folder that has path-keyed memories without an id from .call (the web row); .adopt moves them" do
      plain = File.join(@tmp, "plain").tap { |dir| FileUtils.mkdir_p(dir) }
      key = Samagotchi::MemoryPaths.key_for_root(plain)
      remember(File.join(projects, key), "notes.md")

      called = described_class.call(plain, home: home, env: env, state_dir: state_dir)
      expect([called.kind, called.id]).to eq([:created, nil])
      expect(File.read(marker(plain))).to eq(described_class::MARKER_TEXT)
      expect(File.symlink?(File.join(projects, key))).to be(false)

      FileUtils.rm_rf(File.join(plain, ".chi"))
      outcome = adopt(plain)
      expect([outcome.kind, outcome.id]).to match([:created, /\Aplain-\h{8}\z/])
      expect(outcome.message).to eq("moved #{File.join(projects, key)} to #{File.join(projects, outcome.id)} (the old " \
                                    "name links to it, for an older chi)")
      expect(File.read(File.join(projects, outcome.id, "notes.md"))).to eq("x")
    end

    it "says an invalid id was replaced" do
      File.write(marker(notes), "id: ../bad\n")

      outcome = adopt

      expect(outcome.message.lines[1]).to start_with('its id "../bad" is not a valid id')
      expect(outcome.message.lines[1]).to end_with(": replaced")
      expect(File.read(marker(notes))).to eq("id: #{outcome.id}\n")
    end

    it "keeps an id it has, and the web row's .call never adopts" do
      remember(File.join(projects, path_key), "notes.md")
      called = described_class.call(notes, home: home)
      expect([called.kind, called.id, called.message]).to eq([:already_marked, nil, "#{notes} is already a chi project"])
      expect(File.directory?(File.join(projects, path_key))).to be(true)
      expect(File.symlink?(File.join(projects, path_key))).to be(false)

      id = adopt.id
      again = adopt
      expect([again.kind, again.id, again.message]).to eq([:already_marked, id, "#{notes} is already a chi project (id #{id})"])
    end

    it "refuses while a running session belongs to the project, moving and writing nothing" do
      remember(File.join(projects, path_key), "notes.md")
      sessions = [row("aaaaaaaa-1", notes, live: true), row("bbbbbbbb-2", notes, live: false),
                  row("cccccccc-3", File.join(@tmp, "other"), live: true)]

      outcome = adopt(sessions: sessions)

      expect([outcome.kind, outcome.reason]).to eq(%i[refused running])
      expect(outcome.message).to eq("#{notes} has running sessions (aaaaaaaa): stop them (chi sessions stop ID) and rerun " \
                                    "chi project init, which moves the project's folders while no session can write to them")
      expect(File.read(marker(notes))).to eq("# an older marker\nother: kept\n")
      expect(File.symlink?(File.join(projects, path_key))).to be(false)
    end

    it "refuses when a folder named by the id exists already, before moving anything" do
      remember(File.join(projects, path_key), "notes.md")
      remember(File.join(contexts, path_key), "ci.json")
      remember(File.join(contexts, "notes-0a1b2c3d"), "other.json")
      allow(Samagotchi::ProjectId).to receive(:generate).and_return("notes-0a1b2c3d")

      outcome = adopt

      expect([outcome.kind, outcome.reason]).to eq(%i[refused id_taken])
      expect(outcome.message).to eq("#{File.join(contexts, "notes-0a1b2c3d")} already exists: chi project init can't move " \
                                    "#{File.join(contexts, path_key)} there; nothing moved")
      expect(File.symlink?(File.join(projects, path_key))).to be(false)
      expect(File.read(marker(notes))).not_to include("id:")
    end

    it "leaves the path key reaching the moved folders when it stops before the id, and a rerun finishes with the same id" do
      remember(File.join(projects, path_key), "notes.md", "remembered")
      remember(File.join(contexts, path_key), "ci.json")
      allow(Samagotchi::AtomicFile).to receive(:write).and_raise(Errno::ENOSPC)

      expect(adopt).to have_attributes(kind: :refused, reason: :write_failed)
      id = File.readlink(File.join(projects, path_key))
      expect(Samagotchi::MemoryPaths.project_dir(env: env, cwd: notes)).to eq(File.join(projects, path_key))
      expect(File.read(File.join(projects, path_key, "notes.md"))).to eq("remembered")

      allow(Samagotchi::AtomicFile).to receive(:write).and_call_original
      outcome = adopt
      expect([outcome.kind, outcome.id]).to eq([:adopted, id])
      expect(Samagotchi::MemoryPaths.project_dir(env: env, cwd: notes)).to eq(File.join(projects, id))
    end

    it "takes the files of a folder a worker made again between the move and the link, then links" do
      remember(File.join(projects, path_key), "notes.md", "old")
      raced = false
      allow(File).to receive(:symlink).and_wrap_original do |original, target, link|
        unless raced
          raced = true
          remember(link, "late.md", "late")
          remember(link, "notes.md", "both")
        end
        original.call(target, link)
      end

      outcome = adopt

      id = outcome.id
      expect(File.read(File.join(projects, id, "late.md"))).to eq("late")
      expect(File.read(File.join(projects, id, "notes.md"))).to eq("old")
      expect(File.symlink?(File.join(projects, path_key))).to be(false)
      expect(File.read(File.join(projects, path_key, "notes.md"))).to eq("both")
      expect(outcome.message.lines[1]).to include("files written to the old folder meanwhile")
    end

    it "names memories an earlier path left (the same name, another hash), merging nothing" do
      earlier = File.join(projects, "notes_0123abcd")
      remember(earlier, "old.md")

      outcome = adopt

      expect(outcome.message.lines.last).to eq("memories with this folder's name under another key: #{earlier} " \
                                              "(another path's hash); if they are this project's, move their files " \
                                              "into #{File.join(projects, outcome.id)}")
      expect(File.directory?(earlier)).to be(true)
    end

    it "names an id-keyed orphan by its project id, not by a hash, when adopting an id" do
      other = File.join(projects, "notes-0123abcd")
      remember(other, "old.md")

      outcome = adopt

      expect(outcome.message.lines.last).to eq("memories with this folder's name under another key: #{other} " \
                                              "(project id notes-0123abcd); if they are this project's, move their " \
                                              "files into #{File.join(projects, outcome.id)}")
      expect(File.directory?(other)).to be(true)
    end

    it "gives a marked folder a new id with a copy of its folders (--new-id), the old ones kept" do
      id = adopt.id
      remember(File.join(projects, id), "notes.md", "shared")
      File.write(File.join(projects, id, ".root"), "#{notes}\n")
      remember(File.join(contexts, id), "ci.json")

      outcome = described_class.new_id(notes, home: home, env: env, state_dir: state_dir)

      fresh = outcome.id
      expect([outcome.kind, fresh]).to match([:new_id, /\Anotes-\h{8}\z/])
      expect(fresh).not_to eq(id)
      expect(File.read(marker(notes))).to eq("# an older marker\nother: kept\nid: #{fresh}\n")
      expect(File.read(File.join(projects, fresh, "notes.md"))).to eq("shared")
      expect(File.read(File.join(projects, fresh, ".root"))).to eq("#{notes}\n")
      expect(File.read(File.join(projects, id, "notes.md"))).to eq("shared")
      expect(File.exist?(File.join(contexts, fresh, "ci.json"))).to be(true)
      expect(outcome.message.lines.map(&:chomp)).to eq([
        "#{notes} has a chi project id of its own now: #{fresh} (was #{id})",
        "copied #{File.join(projects, id)} to #{File.join(projects, fresh)}",
        "copied #{File.join(contexts, id)} to #{File.join(contexts, fresh)}"
      ])
    end

    it "does not copy a memory folder taken by another project's path key when assigning a new id" do
      victim = File.join(@tmp, "victim")
      FileUtils.mkdir_p(File.join(victim, ".git"))
      victim_key = Samagotchi::MemoryPaths.key_for_root(File.realpath(victim))
      File.write(marker(notes), "# an older marker\nother: kept\nid: #{victim_key}\n")
      taken = File.join(projects, victim_key)
      remember(taken, "victim.md", "not notes' memory")

      outcome = described_class.new_id(notes, home: home, env: env, state_dir: state_dir)

      expect(outcome.kind).to eq(:new_id)
      expect(outcome.id).to match(/\Anotes-\h{8}\z/)
      expect(File.read(marker(notes))).to include("id: #{outcome.id}")
      expect(File.exist?(File.join(projects, outcome.id, "victim.md"))).to be(false)
      expect(File.read(File.join(taken, "victim.md"))).to eq("not notes' memory")
      expect(outcome.message).to include("did not copy", taken)
    end

    it "refuses --new-id outside a marked folder's top" do
      FileUtils.mkdir_p(File.join(notes, "sub"))
      [File.join(notes, "sub"), File.join(@tmp, "plain")].each do |dir|
        outcome = described_class.new_id(dir, home: home, env: env, state_dir: state_dir)
        expect([outcome.kind, outcome.reason]).to eq(%i[refused not_marked])
        expect(outcome.message).to eq("#{dir} is not a marked chi project folder: --new-id gives one (made with chi " \
                                      "project init) an id of its own")
      end
    end
  end

  describe ".ensure_folder" do
    it "makes a missing folder and returns nil, without a marker" do
      target = File.join(@tmp, "repo", "new", "sub")

      expect(described_class.ensure_folder(target)).to be_nil
      expect(File.directory?(target)).to be(true)
      expect(File.exist?(marker(target))).to be(false)
    end

    it "leaves an existing folder as it is" do
      target = File.join(@tmp, "here")
      FileUtils.mkdir_p(target)
      File.write(File.join(target, "keep"), "x")

      expect(described_class.ensure_folder(target)).to be_nil
      expect(File.read(File.join(target, "keep"))).to eq("x")
    end

    it "words a failure as a refused write_failed outcome" do
      file = File.join(@tmp, "file")
      File.write(file, "")

      outcome = described_class.ensure_folder(File.join(file, "child"))

      expect([outcome.kind, outcome.reason]).to eq(%i[refused write_failed])
      expect(outcome.message).to start_with("couldn't create #{File.join(file, "child")}: ")
    end
  end
end
