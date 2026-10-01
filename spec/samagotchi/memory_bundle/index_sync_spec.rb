# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/memory_bundle/index_sync"
require "samagotchi/memory_bundle/installer"

# A memory changed by write/edit gets its index line refreshed as
# memory_write does (the ToolRunner calls IndexSync.refresh).
RSpec.describe Samagotchi::MemoryBundle::IndexSync do
  let(:tmpdir) { Dir.mktmpdir("index-sync-") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }
  # MemoryRead takes the project override as the project's own dir,
  # IndexUpdater as the base the project key goes under: this one path is
  # both.
  let(:project_dir) { Samagotchi::MemoryPaths.project_dir }
  let(:today) { Date.today.iso8601 }

  before do
    FileUtils.mkdir_p([system_dir, project_dir])
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  def index(dir) = File.read(File.join(dir, "index.md"))

  it "refreshes an edited memory's bytes and date, keeping its description and the rest of the index" do
    Samagotchi::Tools::MemoryWrite.call("hello", path: "skill_release", scope: "project",
                                                 description: "Release: tag, push")
    File.open(File.join(project_dir, "index.md"), "a") { |f| f.puts("\nMy own notes.") }
    path = File.join(project_dir, "skill_release.md")
    File.write(path, "hello, longer")

    expect(described_class.refresh(path)).to be(true)
    expect(index(project_dir)).to include("- **skill_release** · project · #{today} · 13 — Release: tag, push\n")
    expect(index(project_dir)).to include("My own notes.")
    expect(index(project_dir).scan("skill_release").size).to eq(1)
  end

  it "adds a line for a memory created with write, in its own scope" do
    path = File.join(system_dir, "notes.md")
    File.write(path, "abc")
    expect(described_class.refresh(path)).to be(true)
    expect(index(system_dir)).to include("- **notes** · system · #{today} · 3\n")
  end

  it "finds the scope through a symlinked dir" do
    link = File.join(tmpdir, "link")
    File.symlink(project_dir, link)
    File.write(File.join(link, "notes.md"), "abc")
    expect(described_class.refresh(File.join(link, "notes.md"))).to be(true)
    expect(index(project_dir)).to include("- **notes** · project")
  end

  it "leaves the index alone for index.md, a hidden file, a model overlay, a non-.md and a file elsewhere" do
    File.write(File.join(project_dir, "notes.md"), "base")
    others = [File.join(project_dir, "index.md"), File.join(project_dir, ".draft.md"),
              File.join(project_dir, "notes.qwen36.md"), File.join(project_dir, "notes.txt"),
              File.join(tmpdir, "README.md"), File.join(project_dir, "missing.md")]
    others.each { |p| File.write(p, "x") unless p.end_with?("missing.md") }
    File.write(File.join(project_dir, "index.md"), "# mine\n")

    others.each { |p| expect(described_class.refresh(p)).to be(false), p }
    expect(index(project_dir)).to eq("# mine\n")
  end

  it "doesn't take a symlinked .md for a memory (write/edit would follow it out of the memories dir)" do
    target = File.join(tmpdir, "elsewhere.md")
    File.write(target, "x")
    link = File.join(project_dir, "notes.md")
    File.symlink(target, link)
    expect(described_class.memory_scope(link)).to be_nil
    expect(described_class.memory_scope(File.join(project_dir, "plain.md"))).to eq("project")
    expect(described_class.refresh(link)).to be(false)
  end

  it "indexes a dotted memory name that has no base file next to it" do
    path = File.join(project_dir, "notes.v2.md")
    File.write(path, "x")
    expect(described_class.refresh(path)).to be(true)
    expect(index(project_dir)).to include("- **notes.v2** · project")
  end

  it "never raises: a failure is logged and reported as false" do
    path = File.join(project_dir, "notes.md")
    File.write(path, "x")
    allow(Samagotchi::MemoryBundle::IndexUpdater).to receive(:update_index).and_raise(Errno::EACCES)
    expect(described_class.refresh(path)).to be(false)
  end
end
