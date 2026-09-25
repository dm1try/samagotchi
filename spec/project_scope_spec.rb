# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "spec_helper"
require "samagotchi/project_scope"
require "samagotchi/session"
require "samagotchi/session_manager"

RSpec.describe Samagotchi::ProjectScope do
  def git(*args)
    out, status = Open3.capture2e("git", "-c", "user.name=x", "-c", "user.email=x@x",
                                  "-c", "init.defaultBranch=main", *args)
    raise "git #{args.join(" ")} failed: #{out}" unless status.success?

    out
  end

  around do |example|
    Dir.mktmpdir("project-scope") { |tmp| @tmp = tmp; example.run }
  end

  # Not realpathed on purpose: on macOS the tmp dir is a symlink
  # (/var → /private/var), and roots come back realpathed.
  let(:real_tmp) { File.realpath(@tmp) }
  let(:repo) do
    dir = File.join(@tmp, "repo")
    git("init", "-q", dir)
    git("-C", dir, "commit", "-q", "--allow-empty", "-m", "init")
    dir
  end
  let(:repo_root) { File.join(real_tmp, "repo") }
  let(:worktree) do
    dir = File.join(@tmp, "repo-wt")
    git("-C", repo, "worktree", "add", "-q", "-b", "wt", dir)
    dir
  end
  let(:plain) { File.join(@tmp, "plain").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:state_dir) { File.join(@tmp, "state") }

  describe ".root_for" do
    it "is the checkout for a repo, a subfolder of it and a linked worktree" do
      sub = File.join(repo, "lib", "deep")
      FileUtils.mkdir_p(sub)

      expect(described_class.root_for(repo)).to eq(repo_root)
      expect(described_class.root_for(sub)).to eq(repo_root)
      expect(described_class.root_for(worktree)).to eq(repo_root)
    end

    it "is nil outside any repo, for an empty folder name and for a missing folder in no repo" do
      expect(described_class.root_for(plain)).to be_nil
      expect(described_class.root_for("")).to be_nil
      expect(described_class.root_for(nil)).to be_nil
      expect(described_class.root_for(File.join(@tmp, "gone"))).to be_nil
    end

    it "reuses a cache across calls" do
      cache = {}
      described_class.root_for(repo, cache: cache)
      expect(cache).to eq(repo => repo_root)
      cache[repo] = "/cached"
      expect(described_class.root_for(repo, cache: cache)).to eq("/cached")
    end
  end

  describe "the session's project" do
    def session_in(dir, preview: "")
      Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: dir).tap do |s|
        s.first_preview = preview
        s.save(state_dir: state_dir)
      end
    end

    it "is stored at creation and read back (nil outside a repo)" do
      in_repo = session_in(worktree)
      outside = session_in(plain)

      expect(JSON.parse(File.read(File.join(state_dir, "#{in_repo.id}.json")))["project_root"]).to eq(repo_root)
      expect(Samagotchi::Session.load(in_repo.id, state_dir: state_dir).project_root).to eq(repo_root)
      expect(Samagotchi::Session.load(outside.id, state_dir: state_dir).project_root).to be_nil
    end

    it "falls back to the folder's project for a file without the field" do
      session = session_in(repo)
      path = File.join(state_dir, "#{session.id}.json")
      data = JSON.parse(File.read(path))
      data.delete("project_root")
      File.write(path, JSON.generate(data))

      expect(Samagotchi::Session.load(session.id, state_dir: state_dir).project_root).to eq(repo_root)
      expect(Samagotchi::Session.list(state_dir: state_dir, project_root: repo_root).map(&:id)).to eq([session.id])
    end

    it "keeps the stored project when the worktree folder is gone" do
      session = session_in(worktree)
      git("-C", repo, "worktree", "remove", "--force", worktree)
      expect(File.exist?(worktree)).to be false

      expect(Samagotchi::Session.list(state_dir: state_dir, project_root: repo_root).map(&:id)).to eq([session.id])
    end

    it "filters Session.list before offset and limit" do
      # updated_at has millisecond precision: keep the order unambiguous.
      ids = %w[a b c].map { |p| session_in(repo, preview: p).id.tap { sleep 0.005 } }
      session_in(plain)
      sleep 0.005
      ids << session_in(repo, preview: "d").id
      newest_first = ids.reverse

      listed = Samagotchi::Session.list(state_dir: state_dir, project_root: repo_root, offset: 1, limit: 2)
      expect(listed.map(&:id)).to eq(newest_first[1, 2])
      expect(Samagotchi::Session.list(state_dir: state_dir).size).to eq(5)
    end

    it "is passed through by SessionManager.list_sessions and session_summaries" do
      mine = session_in(repo)
      session_in(plain)

      expect(Samagotchi::SessionManager.list_sessions(state_dir: state_dir, project_root: repo_root).map(&:id))
        .to eq([mine.id])
      expect(Samagotchi::SessionManager.session_summaries(state_dir: state_dir, project_root: repo_root).map { |s| s[:id] })
        .to eq([mine.id])
      expect(Samagotchi::SessionManager.session_summaries(state_dir: state_dir).size).to eq(2)
    end
  end
end
