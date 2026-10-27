# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "samagotchi/web/project_list"

RSpec.describe Samagotchi::Web::ProjectList do
  def git(*args)
    out, status = Open3.capture2e("git", "-c", "user.name=x", "-c", "user.email=x@x",
                                  "-c", "init.defaultBranch=main", *args)
    raise "git #{args.join(" ")} failed: #{out}" unless status.success?

    out
  end

  around do |example|
    Dir.mktmpdir("web-project-list") do |tmp|
      @tmp = File.realpath(tmp)
      example.run
    end
  end

  let(:root) { File.join(@tmp, "alpha").tap { |dir| git("init", "-q", dir) } }
  let(:other) { File.join(@tmp, "beta").tap { |dir| git("init", "-q", dir) } }
  let(:folder) { File.join(root, "lib").tap { |dir| FileUtils.mkdir_p(dir) } }

  def summary(root, **values)
    { project_root: root, updated_at: "2026-10-27T12:00:00Z", pending_question: nil, pending_card: nil }.merge(values)
  end

  it "groups sessions by repo root, folds worktrees into that root and skips archived or invalid roots" do
    worktree = File.join(@tmp, "alpha-worktree")
    git("-C", root, "commit", "--allow-empty", "-m", "initial")
    git("-C", root, "worktree", "add", "-b", "worktree", worktree)
    worktree_root = Samagotchi::ProjectScope.root_for(worktree)
    missing = File.join(@tmp, "missing")

    rows = described_class.build(
      [summary(root), summary(worktree_root), summary(other, archived: true),
       summary(missing), summary(File.join(@tmp, "not-a-repo")), summary(nil)],
      start_dir: folder, current_root: root
    )

    expect(rows.map { |row| row[:root] }).to eq([root])
    expect(rows.first).to include(name: "alpha", dir: folder, sessions: 2, default: true, current: true)
  end

  it "adds the start project with no sessions, using the start folder as its dir" do
    rows = described_class.build([], start_dir: folder, current_root: nil)

    expect(rows).to eq([{ name: "alpha", root: root, root_label: root, dir: folder, sessions: 0, waiting: 0,
                          updated_at: nil, default: true, current: false }])
  end

  it "puts the default project first, then orders projects by latest session update" do
    rows = described_class.build(
      [summary(other, updated_at: "2026-10-27T14:00:00Z"),
       summary(root, updated_at: "2026-10-27T11:00:00Z"),
       summary(other, updated_at: "2026-10-27T15:00:00Z")],
      start_dir: folder, current_root: other
    )

    expect(rows.map { |row| [row[:root], row[:updated_at], row[:default], row[:current]] }).to eq([
      [root, "2026-10-27T11:00:00Z", true, false],
      [other, "2026-10-27T15:00:00Z", false, true]
    ])
    expect(rows.last[:dir]).to eq(other)
  end

  it "counts open questions and cards once per summary, excluding relayed or id-less attention" do
    rows = described_class.build(
      [summary(root, pending_question: { id: "q" }),
       summary(root, pending_question: { id: "relayed", relayed_to: "parent" }),
       summary(root, pending_card: { id: "card" }),
       summary(root, pending_card: {}),
       summary(root)],
      start_dir: folder, current_root: root
    )

    expect(rows.first).to include(sessions: 5, waiting: 2)
  end

  it "keeps same-basename roots distinguishable and omits the default outside a repo" do
    first = File.join(@tmp, "one", "same")
    second = File.join(@tmp, "two", "same")
    [first, second].each { |dir| git("init", "-q", dir) }

    rows = described_class.build([summary(first), summary(second)], start_dir: @tmp, current_root: nil)

    expect(rows.map { |row| row[:name] }).to eq(%w[same same])
    expect(rows.map { |row| row[:root_label] }).to contain_exactly(first, second)
    expect(rows.map { |row| row[:default] }).to all(be(false))
  end
end
