# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "samagotchi/project_subfolders"
require "samagotchi/session_row"

RSpec.describe Samagotchi::ProjectSubfolders do
  around do |example|
    Dir.mktmpdir("project-subfolders") do |tmp|
      @tmp = File.realpath(tmp)
      example.run
    end
  end

  let(:home) { File.join(@tmp, "home").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:env) { { "XDG_CONFIG_HOME" => File.join(@tmp, "xdg") } }
  let(:projects) { File.join(@tmp, "xdg", "samagotchi", "memories", "projects") }
  let(:notes) { File.join(@tmp, "notes").tap { |dir| mark(dir) } }
  let(:target) { File.join(projects, "notes-0123abcd") }

  def mark(dir)
    FileUtils.mkdir_p(File.join(dir, ".chi"))
    File.write(File.join(dir, ".chi", "project.yml"), "id: notes-0123abcd\n")
  end

  def key(root) = Samagotchi::MemoryPaths.key_for_root(root)

  def row(cwd, live: false, project: cwd, id: "aaaaaaaa-1")
    instance_double(Samagotchi::SessionRow, id: id, cwd: cwd, live: live, project: project)
  end

  # A path-keyed memories folder for +path+ with +files+ (name → text).
  def memories(path, files)
    dir = File.join(projects, key(path))
    FileUtils.mkdir_p(dir)
    files.each { |name, text| File.write(File.join(dir, name), text) }
    dir
  end

  def find(rows) = described_class.find(notes, sessions: rows, env: env, home: home)

  describe ".find" do
    it "finds a subfolder's path-keyed memories from a session row, counting entries, not overlays or the index" do
      sub = File.join(notes, "sub").tap { |dir| FileUtils.mkdir_p(dir) }
      dir = memories(sub, "a.md" => "a", "a.claude-x.md" => "o", "b.md" => "b", "index.md" => "# Memory Index\n")

      found = find([row(sub), row(sub, id: "bbbbbbbb-2")])

      expect(found).to eq([described_class::Found.new(path: sub, dir: dir, count: 2)])
      expect(described_class.message(found))
        .to eq("memories saved from subfolders before init: #{sub} (2 memories); move them into the project " \
               "with chi project init --merge-subfolders")
    end

    it "skips the root itself, a folder outside it, a nested repository's and a symlink out of it" do
      outside = File.join(@tmp, "elsewhere").tap { |dir| FileUtils.mkdir_p(dir) }
      nested = File.join(notes, "repo").tap { |dir| FileUtils.mkdir_p(File.join(dir, ".git")) }
      link = File.join(notes, "out")
      File.symlink(outside, link)
      [notes, outside, nested, link].each { |path| memories(path, "a.md" => "a") }

      expect(find([row(notes), row(outside), row(nested), row(link)])).to eq([])
    end

    it "finds a subfolder that was a git repository then (its key the same formula) once .git is gone" do
      old_repo = File.join(notes, "was-repo").tap { |dir| FileUtils.mkdir_p(dir) }
      memories(old_repo, "a.md" => "a")

      expect(find([row(old_repo)]).map(&:path)).to eq([old_repo])
    end

    it "skips a folder with no memories or none at all, and a link" do
      empty = File.join(notes, "empty").tap { |dir| FileUtils.mkdir_p(dir) }
      memories(empty, "index.md" => "")
      linked = File.join(notes, "linked").tap { |dir| FileUtils.mkdir_p(dir) }
      FileUtils.mkdir_p(projects)
      File.symlink(target, File.join(projects, key(linked)))
      none = File.join(notes, "none")

      expect(find([row(empty), row(linked), row(none)])).to eq([])
    end

    it "uses the row's cwd when it stored no project" do
      sub = File.join(notes, "sub").tap { |dir| FileUtils.mkdir_p(dir) }
      memories(sub, "a.md" => "a")

      expect(find([row(sub, project: nil)]).map(&:count)).to eq([1])
    end
  end

  describe ".running" do
    it "names live sessions under the root by their stored root or their folder" do
      sub = File.join(notes, "sub").tap { |dir| FileUtils.mkdir_p(dir) }
      rows = [row(sub, live: true, id: "aaaaaaaa-1"), row(sub, id: "bbbbbbbb-2"),
              row(@tmp, live: true, id: "cccccccc-3")]

      running = described_class.running(notes, sessions: rows, home: home)

      expect(running.map(&:id)).to eq(["aaaaaaaa-1"])
      expect(described_class.running_message(notes, running))
        .to start_with("#{notes} has running sessions (aaaaaaaa): stop them (chi sessions stop ID) and rerun " \
                       "chi project init --merge-subfolders")
    end
  end

  describe ".merge" do
    let(:sub) { File.join(notes, "sub").tap { |dir| FileUtils.mkdir_p(dir) } }

    def index_line(name, desc = nil)
      Samagotchi::MemoryBundle::IndexUpdater.managed_line(name, "project", 1, desc)
    end

    def merge(found) = described_class.merge(found, target: target, env: env)

    before { require "samagotchi/memory_bundle/index_updater" }

    it "moves each entry with its overlays and index line, and removes the emptied folder (no link)" do
      dir = memories(sub, "a.md" => "a", "a.claude-x.md" => "o", "b.md" => "b",
                          "index.md" => "# Memory Index\n\n#{index_line("a", "the a")}\n#{index_line("b")}\n")

      lines = merge(find([row(sub)]))

      expect(lines).to eq(["moved 2 memories saved from #{sub} into #{target}: a, b", "removed the emptied #{dir}"])
      expect(Dir.children(target).sort).to eq(%w[.index.lock a.claude-x.md a.md b.md index.md])
      index = File.read(File.join(target, "index.md"))
      expect(index).to match(/^- \*\*a\*\* · project · .* — the a$/)
      expect(index).to match(/^- \*\*b\*\* · project · /)
      expect(File.exist?(dir) || File.symlink?(dir)).to be(false)
    end

    it "keeps the folder when its index.md has lines written by hand, and says so" do
      dir = memories(sub, "a.md" => "a",
                          "index.md" => "# Memory Index\n\nKeep these short.\n\n#{index_line("a")}\n")

      lines = merge(find([row(sub)]))

      expect(lines).to eq(["moved 1 memory saved from #{sub} into #{target}: a",
                           "#{dir} keeps its index.md: it has lines written by hand"])
      expect(File.read(File.join(dir, "index.md"))).to include("Keep these short.")
    end

    it "removes a folder whose index.md holds only the header and dangling managed lines" do
      header = Samagotchi::MemoryBundle::IndexUpdater.auto_index_header
      dir = memories(sub, "a.md" => "a", "index.md" => "#{header}\n\n#{index_line("a")}\n#{index_line("gone")}\n")

      expect(merge(find([row(sub)])).last).to eq("removed the emptied #{dir}")
    end

    it "keeps an entry the project already has in place, names it, and keeps the folder" do
      FileUtils.mkdir_p(target)
      File.write(File.join(target, "a.md"), "theirs")
      dir = memories(sub, "a.md" => "mine", "b.md" => "b", "index.md" => "#{index_line("a")}\n#{index_line("b")}\n")

      lines = merge(find([row(sub)]))

      expect(lines).to eq(["moved 1 memory saved from #{sub} into #{target}: b",
                           "kept in #{dir}: a (the project has one by that name)"])
      expect(File.read(File.join(target, "a.md"))).to eq("theirs")
      expect(File.read(File.join(dir, "a.md"))).to eq("mine")
      expect(File.read(File.join(dir, "index.md"))).to include("**a**").and(satisfy { |text| !text.include?("**b**") })
    end

    it "keeps a dotted memory with its own index line apart from another's overlays" do
      memories(sub, "h.md" => "h", "h.v2.md" => "v2", "index.md" => "#{index_line("h")}\n#{index_line("h.v2")}\n")

      lines = merge(find([row(sub)]))

      expect(lines.first).to eq("moved 2 memories saved from #{sub} into #{target}: h, h.v2")
      expect(File.read(File.join(target, "index.md"))).to include("**h.v2**")
    end

    it "keeps a bundle's entry and names files that aren't memories" do
      dir = memories(sub, "a.md" => "a", "notes.txt" => "x",
                          "index.md" => "#{Samagotchi::MemoryBundle::IndexUpdater.managed_line("a", "project", 1, nil, "kit")}\n")

      expect(merge(find([row(sub)]))).to eq(["kept in #{dir}: a (from bundle kit)",
                                             "#{dir} keeps files that aren't memories: notes.txt"])

      File.delete(File.join(dir, "a.md"))
      File.write(File.join(dir, "c.md"), "c")
      expect(merge(find([row(sub)]))).to eq(["moved 1 memory saved from #{sub} into #{target}: c",
                                             "#{dir} keeps files that aren't memories: notes.txt"])
    end

    it "says so when nothing was found" do
      expect(merge([])).to eq(["no memories saved from subfolders before init to move"])
    end
  end
end
