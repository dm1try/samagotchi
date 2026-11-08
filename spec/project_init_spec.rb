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
    expect(File.file?(marker(target))).to be(true)
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
