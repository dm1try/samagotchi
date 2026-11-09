# frozen_string_literal: true

require "samagotchi/memory_paths"
require "digest"
require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe Samagotchi::MemoryPaths do
  describe ".system_dir" do
    it "lives next to config.yml under XDG_CONFIG_HOME" do
      expect(described_class.system_dir(env: { "XDG_CONFIG_HOME" => "/xdg" })).to eq("/xdg/samagotchi/memories")
    end

    it "falls back to ~/.config when XDG_CONFIG_HOME is blank" do
      expect(described_class.system_dir(env: { "XDG_CONFIG_HOME" => " " }))
        .to eq(File.join(Dir.home, ".config", "samagotchi", "memories"))
    end

    it "reads ENV on every call, not once at load" do
      original = ENV["XDG_CONFIG_HOME"]
      ENV["XDG_CONFIG_HOME"] = "/first"
      first = described_class.system_dir
      ENV["XDG_CONFIG_HOME"] = "/second"
      expect([first, described_class.system_dir]).to eq(%w[/first/samagotchi/memories /second/samagotchi/memories])
    ensure
      ENV["XDG_CONFIG_HOME"] = original
    end
  end

  describe ".project_dir" do
    it "keys the folder by basename and MD5 of the project root" do
      Dir.mktmpdir do |tmp|
        root = File.realpath(tmp)
        key = "#{File.basename(root)}_#{Digest::MD5.hexdigest(root)[0..7]}"
        expect(described_class.project_dir(env: { "XDG_CONFIG_HOME" => "/xdg" }, cwd: root))
          .to eq("/xdg/samagotchi/memories/projects/#{key}")
      end
    end
  end

  describe ".project_root" do
    def git(*args)
      out, status = Open3.capture2e("git", "-c", "user.name=x", "-c", "user.email=x@x",
                                    "-c", "init.defaultBranch=main", *args)
      raise "git #{args.join(" ")} failed: #{out}" unless status.success?

      out
    end

    def repo_with_commit(dir)
      git("init", "-q", dir)
      git("-C", dir, "commit", "-q", "--allow-empty", "-m", "init")
    end

    around do |example|
      Dir.mktmpdir { |tmp| @tmp = tmp; example.run }
    end

    let(:real_tmp) { File.realpath(@tmp) }

    it "is the directory itself outside any git repository" do
      dir = File.join(@tmp, "plain")
      FileUtils.mkdir_p(dir)
      expect(described_class.project_root(dir)).to eq(dir)
      expect(described_class.project_key(dir)).to eq("plain_#{Digest::MD5.hexdigest(dir)[0..7]}")
      expect(described_class.key_for_root(dir)).to eq(described_class.project_key(dir))
    end

    it "is the checkout for the repo root and a nested subdirectory" do
      repo = File.join(real_tmp, "repo")
      git("init", "-q", repo)
      FileUtils.mkdir_p(File.join(repo, "lib", "deep"))

      expect(described_class.project_root(repo)).to eq(repo)
      expect(described_class.project_root(File.join(repo, "lib", "deep"))).to eq(repo)
      expect(described_class.project_key(File.join(repo, "lib", "deep"))).to eq(described_class.project_key(repo))
    end

    it "gives a linked worktree the main checkout's key, even through a symlinked tmp path" do
      # @tmp is not realpathed: on macOS it is /var/..., a symlink to /private/var/...,
      # while git writes the worktree's .git file with real paths.
      repo = File.join(@tmp, "repo")
      repo_with_commit(repo)
      tree = File.join(@tmp, "repo-feature")
      git("-C", repo, "worktree", "add", "-q", "-b", "feature", tree)

      expect(described_class.project_root(tree)).to eq(File.join(real_tmp, "repo"))
      expect(described_class.project_key(tree)).to eq(described_class.project_key(repo))
      expect(described_class.project_key(tree)).to start_with("repo_")
    end

    it "gives the git dir holding a folder's own HEAD: .git in the main checkout, the linked worktree's own, nil outside git" do
      repo = File.join(real_tmp, "repo")
      repo_with_commit(repo)
      tree = File.join(real_tmp, "repo-feature")
      git("-C", repo, "worktree", "add", "-q", "-b", "feature", tree)
      FileUtils.mkdir_p(File.join(tree, "lib"))
      FileUtils.mkdir_p(File.join(@tmp, "plain"))

      expect(described_class.git_dir(repo)).to eq(File.join(repo, ".git"))
      expect(described_class.git_dir(File.join(tree, "lib"))).to eq(File.join(repo, ".git", "worktrees", "repo-feature"))
      expect(described_class.git_dir(File.join(@tmp, "plain"))).to be_nil
    end

    it "keys a submodule-shaped .git file (no commondir) by that gitdir" do
      gitdir = File.join(real_tmp, "sup", ".git", "modules", "sub")
      FileUtils.mkdir_p(gitdir)
      sub = File.join(real_tmp, "sup", "sub")
      FileUtils.mkdir_p(sub)
      File.write(File.join(sub, ".git"), "gitdir: ../.git/modules/sub\n")

      expect(described_class.project_root(sub)).to eq(gitdir)
    end

    it "gives a ./.bare repo and its worktrees one key" do
      proj = File.join(real_tmp, "proj")
      bare = File.join(proj, ".bare")
      repo_with_commit(File.join(real_tmp, "src"))
      git("clone", "-q", "--bare", File.join(real_tmp, "src"), bare)
      File.write(File.join(proj, ".git"), "gitdir: ./.bare\n")
      git("-C", proj, "worktree", "add", "-q", File.join(proj, "main"), "main")

      expect(described_class.project_root(proj)).to eq(bare)
      expect(described_class.project_root(File.join(proj, "main"))).to eq(bare)
    end

    it "keys a worktree of a bare repository by the bare dir" do
      bare = File.join(real_tmp, "x.git")
      repo_with_commit(File.join(real_tmp, "src"))
      git("clone", "-q", "--bare", File.join(real_tmp, "src"), bare)
      tree = File.join(real_tmp, "x-main")
      git("-C", bare, "worktree", "add", "-q", tree, "main")

      expect(described_class.project_root(tree)).to eq(bare)
    end

    it "keys a malformed .git file by the directory holding it, without raising" do
      dir = File.join(real_tmp, "broken")
      FileUtils.mkdir_p(File.join(dir, "sub"))
      File.write(File.join(dir, ".git"), "not a gitdir line\n")

      expect(described_class.project_root(File.join(dir, "sub"))).to eq(dir)
    end
  end

  describe ".lookup" do
    around do |example|
      Dir.mktmpdir { |tmp| @tmp = tmp; example.run }
    end

    # Not realpathed on purpose: on macOS the tmp dir is a symlink
    # (/var → /private/var), and a marked root comes back realpathed.
    let(:real_tmp) { File.realpath(@tmp) }
    let(:home) { File.join(@tmp, "home").tap { |dir| FileUtils.mkdir_p(dir) } }

    def mark(dir)
      FileUtils.mkdir_p(File.join(dir, ".chi"))
      File.write(File.join(dir, described_class::MARKER), "# chi project marker\n")
      dir
    end

    def git_init(dir)
      out, status = Open3.capture2e("git", "init", "-q", dir)
      raise "git init failed: #{out}" unless status.success?
    end

    def look(dir) = described_class.lookup(dir, home: home)

    it "finds a marker at the top and from a subfolder, as the realpath of the marked folder" do
      notes = mark(File.join(@tmp, "notes"))
      sub = File.join(notes, "sub", "deep").tap { |dir| FileUtils.mkdir_p(dir) }
      root = File.join(real_tmp, "notes")

      expect(look(notes)).to eq(described_class::ProjectLookup.new(kind: :marker, root: root, top: root))
      expect(look(sub)).to eq(look(notes))
      expect(look(File.join(real_tmp, "notes", "sub")).root).to eq(root)
    end

    it "gives a symlinked spelling of the marked folder its realpath root" do
      notes = mark(File.join(@tmp, "notes"))
      FileUtils.mkdir_p(File.join(notes, "sub"))
      link = File.join(@tmp, "link")
      File.symlink(notes, link)

      expect(look(File.join(link, "sub")).root).to eq(File.realpath(notes))
    end

    it "walks the real path: a link into the middle of a marked project is in it" do
      notes = mark(File.join(@tmp, "notes"))
      deep = File.join(notes, "deep").tap { |dir| FileUtils.mkdir_p(File.join(dir, "x")) }
      link = File.join(@tmp, "into-deep")
      File.symlink(deep, link)

      expect(look(File.join(link, "x"))).to eq(look(File.realpath(File.join(link, "x"))))
      expect(look(File.join(link, "x")).root).to eq(File.realpath(notes))
    end

    it "walks the real path: a link from inside a marked project out to another folder is not in it" do
      marked = mark(File.join(@tmp, "mk"))
      target = File.join(@tmp, "other", "target").tap { |dir| FileUtils.mkdir_p(dir) }
      File.symlink(target, File.join(marked, "lnk"))

      expect(look(File.join(marked, "lnk")).kind).to eq(:none)
      expect(look(File.join(marked, "lnk")).kind).to eq(look(File.realpath(target)).kind)
    end

    it "is none outside a repo and a marker: the folder itself as root, no top" do
      plain = File.join(@tmp, "plain").tap { |dir| FileUtils.mkdir_p(dir) }

      expect(look(plain)).to eq(described_class::ProjectLookup.new(kind: :none, root: plain, top: nil))
    end

    it "lets git win over a marker above the .git and below it" do
      above = mark(File.join(@tmp, "above"))
      repo = File.join(above, "repo")
      git_init(repo)
      inside = mark(File.join(repo, "inner"))

      expect(look(repo).kind).to eq(:git)
      expect(look(inside)).to have_attributes(kind: :git, root: File.join(real_tmp, "above", "repo"))
    end

    it "takes the nearest marker: a marked folder inside another is its own project" do
      outer = mark(File.join(@tmp, "outer"))
      inner = mark(File.join(outer, "inner"))

      expect(look(File.join(inner, "x")).root).to eq(File.join(real_tmp, "outer", "inner"))
      expect(look(File.join(outer, "y")).root).to eq(File.join(real_tmp, "outer"))
    end

    it "needs project.yml: a bare .chi/ dir is no marker" do
      dir = File.join(@tmp, "dotchi")
      FileUtils.mkdir_p(File.join(dir, ".chi"))

      expect(look(dir).kind).to eq(:none)
    end

    it "ignores a marker in $HOME or above it, and in /" do
      mark(home)
      below = File.join(home, "work").tap { |d| FileUtils.mkdir_p(d) }
      expect(look(below).kind).to eq(:none)
      expect(look(home).kind).to eq(:none)

      mark(@tmp)
      expect(look(File.join(@tmp, "elsewhere")).kind).to eq(:none)
      expect(described_class.above_home?("/", home: nil)).to be(true)
      expect(described_class.above_home?(home, home: home)).to be(true)
      expect(described_class.above_home?(File.join(home, "work"), home: home)).to be(false)
    end

    it "keeps a marked project under $HOME" do
      project = mark(File.join(home, "notes"))

      expect(look(File.join(project, "sub")).kind).to eq(:marker)
    end

    it "keeps the old cwd-fallback key at the top, and the same key after git init" do
      notes = File.join(@tmp, "notes").tap { |dir| FileUtils.mkdir_p(dir) }
      # Before: a worker in the folder keyed on its physical Dir.pwd.
      before = described_class.project_key(File.realpath(notes))

      mark(notes)
      expect(described_class.key_for_root(look(notes).root)).to eq(before)

      git_init(notes)
      expect(described_class.project_key(notes)).to eq(before)
    end

    describe "a marker's id" do
      def mark_id(dir, text)
        mark(dir)
        File.write(File.join(dir, described_class::MARKER), text)
        dir
      end

      it "carries a valid id in the lookup and keys the project by it, from any subfolder" do
        notes = mark_id(File.join(@tmp, "notes"), "# chi project marker\nid: notes-0a1b2c3d\n")
        sub = File.join(notes, "sub").tap { |dir| FileUtils.mkdir_p(dir) }
        root = File.join(real_tmp, "notes")

        expect(look(sub)).to eq(described_class::ProjectLookup.new(kind: :marker, root: root, top: root, id: "notes-0a1b2c3d"))
        expect(described_class.project_key(sub)).to eq("notes-0a1b2c3d")
        expect(described_class.project_dir(env: { "XDG_CONFIG_HOME" => "/xdg" }, cwd: sub))
          .to eq("/xdg/samagotchi/memories/projects/notes-0a1b2c3d")
      end

      it "keeps the path key for a marker with no id, an invalid id or bad YAML, and reads the file again after an edit" do
        notes = mark(File.join(@tmp, "notes"))
        path_key = described_class.key_for_root(File.join(real_tmp, "notes"))
        marker = File.join(notes, described_class::MARKER)

        expect([look(notes).id, described_class.project_key(notes)]).to eq([nil, path_key])
        ["id: ../up\n", "id: 12345678\n", "id: [a\n", "- a list\n", "id: #{"x" * 65}\n"].each do |text|
          File.write(marker, text)
          expect([text, look(notes).id, described_class.project_key(notes)]).to eq([text, nil, path_key])
        end
        File.write(marker, "id: notes-0a1b2c3d\n")
        expect(described_class.project_key(notes)).to eq("notes-0a1b2c3d")
      end

      it "never keys a git repository by an id: a marker with an id beside or above the .git is ignored" do
        repo = mark_id(File.join(@tmp, "repo"), "id: repo-0a1b2c3d\n")
        git_init(repo)
        above = mark_id(File.join(@tmp, "above"), "id: above-0a1b2c3d\n")
        inner = File.join(above, "inner")
        git_init(inner)

        expect(look(repo)).to have_attributes(kind: :git, id: nil)
        expect(described_class.project_key(repo)).to eq(described_class.key_for_root(File.join(real_tmp, "repo")))
        expect(look(inner)).to have_attributes(kind: :git, id: nil)
      end

      it "ignores the id of a marker in $HOME or /, as it ignores the marker" do
        mark_id(home, "id: home-0a1b2c3d\n")

        expect(look(home)).to have_attributes(kind: :none, id: nil)
        expect(look(File.join(home, "work").tap { |dir| FileUtils.mkdir_p(dir) }).id).to be_nil
      end

      it "keys by the id a caller holds (.key_for), the path key without one; .key_for_root reads no file" do
        notes = mark_id(File.join(@tmp, "notes"), "id: notes-0a1b2c3d\n")
        root = File.realpath(notes)

        expect(described_class.key_for(root: root, id: "notes-0a1b2c3d")).to eq("notes-0a1b2c3d")
        expect(described_class.key_for(root: root, id: nil)).to eq("notes_#{Digest::MD5.hexdigest(root)[0..7]}")
        expect(described_class.key_for_root(root)).to eq("notes_#{Digest::MD5.hexdigest(root)[0..7]}")
      end
    end

    it "answers the readers from the one lookup" do
      notes = mark(File.join(@tmp, "notes"))
      root = File.join(real_tmp, "notes")
      plain = File.join(@tmp, "plain").tap { |dir| FileUtils.mkdir_p(dir) }

      expect([described_class.in_project?(notes), described_class.in_repo?(notes)]).to eq([true, false])
      expect([described_class.marked_root(notes), described_class.project_top(notes)]).to eq([root, root])
      expect([described_class.in_project?(plain), described_class.marked_root(plain), described_class.project_top(plain)])
        .to eq([false, nil, nil])
    end
  end

  describe ".common_git_dir" do
    def git(*args)
      out, status = Open3.capture2e("git", "-c", "user.name=x", "-c", "user.email=x@x",
                                    "-c", "init.defaultBranch=main", *args)
      raise "git #{args.join(" ")} failed: #{out}" unless status.success?

      out
    end

    around do |example|
      Dir.mktmpdir { |tmp| @tmp = tmp; example.run }
    end

    let(:real_tmp) { File.realpath(@tmp) }

    it "is the same real dir for the main checkout, a worktree and a subfolder of it" do
      repo = File.join(real_tmp, "repo")
      git("init", "-q", repo)
      git("-C", repo, "commit", "-q", "--allow-empty", "-m", "init")
      tree = File.join(real_tmp, "repo-feature")
      git("-C", repo, "worktree", "add", "-q", "-b", "feature", tree)
      FileUtils.mkdir_p(File.join(tree, "lib"))

      expect(described_class.common_git_dir(repo)).to eq(File.join(repo, ".git"))
      expect(described_class.common_git_dir(File.join(tree, "lib"))).to eq(File.join(repo, ".git"))
    end

    it "is the bare dir of a ./.bare layout, and nil outside any repository" do
      proj = File.join(real_tmp, "proj")
      bare = File.join(proj, ".bare")
      git("init", "-q", File.join(real_tmp, "src"))
      git("-C", File.join(real_tmp, "src"), "commit", "-q", "--allow-empty", "-m", "init")
      git("clone", "-q", "--bare", File.join(real_tmp, "src"), bare)
      File.write(File.join(proj, ".git"), "gitdir: ./.bare\n")
      git("-C", proj, "worktree", "add", "-q", File.join(proj, "main"), "main")
      plain = File.join(real_tmp, "plain")
      FileUtils.mkdir_p(plain)

      expect(described_class.common_git_dir(File.join(proj, "main"))).to eq(bare)
      expect(described_class.common_git_dir(proj)).to eq(bare)
      expect(described_class.common_git_dir(plain)).to be_nil
    end
  end

  describe ".scope_dir" do
    let(:env) { { "XDG_CONFIG_HOME" => "/xdg" } }

    it "maps system (or no scope) to system_dir and project to project_dir; nil for anything else" do
      expect(%w[system project].push("", nil, " system", "other").map { |scope| described_class.scope_dir(scope, env: env, cwd: "/tmp") })
        .to eq(["/xdg/samagotchi/memories", described_class.project_dir(env: env, cwd: "/tmp"),
                "/xdg/samagotchi/memories", "/xdg/samagotchi/memories", nil, nil])
    end
  end

  describe ".scope_dir!" do
    let(:env) { { "XDG_CONFIG_HOME" => "/xdg" } }

    it "is scope_dir for a scope it knows" do
      expect(["system", "", "project"].map { |scope| described_class.scope_dir!(scope, env: env, cwd: "/tmp") })
        .to eq(["/xdg/samagotchi/memories", "/xdg/samagotchi/memories", described_class.project_dir(env: env, cwd: "/tmp")])
    end

    it "raises ArgumentError for any other scope" do
      expect { described_class.scope_dir!("team", env: env) }.to raise_error(ArgumentError, "invalid scope: team")
    end
  end

  describe ".bundles_dir" do
    it "sits inside the system memories dir" do
      expect(described_class.bundles_dir(env: { "XDG_CONFIG_HOME" => "/xdg" })).to eq("/xdg/samagotchi/memories/.bundles")
    end
  end
end
