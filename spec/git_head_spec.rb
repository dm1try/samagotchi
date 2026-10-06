# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/git_head"

RSpec.describe Samagotchi::GitHead do
  let(:root) { File.realpath(Dir.mktmpdir("git-head")) }

  after { FileUtils.rm_rf(root) }

  it "reads the branch a folder has checked out: a linked worktree's own, a detached sha, none outside git" do
    main = File.join(root, "app")
    FileUtils.mkdir_p(File.join(main, ".git", "worktrees", "app-fix"))
    File.write(File.join(main, ".git", "HEAD"), "ref: refs/heads/main\n")
    File.write(File.join(main, ".git", "worktrees", "app-fix", "HEAD"), "ref: refs/heads/fix/flaky\n")
    FileUtils.mkdir_p(File.join(root, "app-fix", "lib"))
    File.write(File.join(root, "app-fix", ".git"), "gitdir: #{File.join(main, ".git", "worktrees", "app-fix")}\n")
    FileUtils.mkdir_p(File.join(root, "detached", ".git"))
    File.write(File.join(root, "detached", ".git", "HEAD"), "0123456789abcdef0123456789abcdef01234567\n")

    expect([main, File.join(root, "app-fix", "lib"), File.join(root, "detached"), root].map { |d| described_class.branch(d) })
      .to eq(["main", "fix/flaky", "01234567", nil])
  end

  it "is nil for a repo whose HEAD is empty or a folder that is gone" do
    FileUtils.mkdir_p(File.join(root, "empty", ".git"))
    File.write(File.join(root, "empty", ".git", "HEAD"), "")

    expect(described_class.branch(File.join(root, "empty"))).to be_nil
    expect(described_class.branch(File.join(root, "gone"))).to be_nil
  end
end
