# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"

require "samagotchi/memory_bundle/installer"
require "samagotchi/memory_bundle/remerge"

# The retry at the same version: what comes back to a file marked conflict.
RSpec.describe Samagotchi::MemoryBundle::Remerge do
  let(:tmpdir) { Dir.mktmpdir("samagotchi-remerge-") }
  let(:memories) { Samagotchi::MemoryPaths.system_dir }
  let(:provenance) { Samagotchi::MemoryBundle::Provenance.new(name: "demo") }
  let(:target) { File.join(memories, "a.md") }
  let(:source) { File.join(tmpdir, "src") }

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

  after { FileUtils.rm_rf(tmpdir) }

  def doc(intro: "the intro", tail: "the tail")
    "# Title\n\n#{intro}\n\none\ntwo\nthree\nfour\nfive\nsix\n\n## Notes\n\n#{tail}\n"
  end

  def write_source(version, text, extra: {})
    FileUtils.rm_rf(source)
    FileUtils.mkdir_p(source)
    File.write(File.join(source, "a.md"), text)
    File.write(File.join(source, "manifest.yml"),
               YAML.dump({ "name" => "demo", "version" => version, "scope" => "system",
                           "files" => { "a.md" => { "sha256" => "fake", "description" => "What a is" } } }.merge(extra)))
    source
  end

  def install(**opts) = Samagotchi::MemoryBundle::Installer.new(source: source, name: "demo", strict: true, **opts).tap(&:run)

  def remerge(dry_run: false)
    described_class.new(name: "demo", scope: "system", target_dir: memories, source_dir: source).run(dry_run: dry_run)
  end

  def entry = provenance.read[:files][:"a.md"]
  def base = File.read(provenance.base_path("a.md"))
  def manifest_path = File.join(provenance.bundle_dir, "manifest.json")

  def trash_files
    Dir.glob(File.join(Samagotchi::MemoryPaths.bundles_dir, ".trash", "*", "*")).to_h { |f| [File.basename(f), File.read(f)] }
  end

  # A mark as 0.149 left it: the old base, and no digest of what it missed.
  def old_mark
    raw = JSON.parse(File.read(manifest_path))
    raw["files"]["a.md"] = raw["files"]["a.md"].except("incoming_sha").merge("conflict" => true)
    File.write(manifest_path, JSON.pretty_generate(raw))
  end

  # An edit marked conflict at 2.0.0, and the base from 1.0.0.
  def marked_at_two(mine:, shipped:)
    write_source("1.0.0", doc)
    install
    File.write(target, mine)
    raw = JSON.parse(File.read(manifest_path))
    raw["version"] = "2.0.0"
    File.write(manifest_path, JSON.pretty_generate(raw))
    old_mark
    write_source("2.0.0", shipped)
  end

  context "with a mark with no digest (older chi) that merges now" do
    let(:merged) { doc(intro: "my intro", tail: "tail two") }

    before { marked_at_two(mine: doc(intro: "my intro"), shipped: doc(tail: "tail two")) }

    it "merges once, the base the incoming file and the mark gone, then does nothing" do
      result = remerge

      expect(result.merged).to eq(["a.md"])
      expect(result.trash_copy).to include("Copied to the trash first: a.md")
      expect(File.read(target)).to eq(merged)
      expect(base).to eq(doc(tail: "tail two"))
      expect(entry).to eq(checksum: Digest::SHA256.hexdigest(doc(tail: "tail two")), description: "What a is")
      expect(trash_files).to eq("a.md" => doc(intro: "my intro"))

      expect(Samagotchi::MemoryBundle::TextMerge).not_to receive(:merge)
      before = File.mtime(manifest_path)
      expect(remerge).to eq(described_class::NOTHING)
      expect(File.mtime(manifest_path)).to eq(before)
    end

    it "leaves the version, installed_at and the assets alone" do
      FileUtils.mkdir_p(provenance.guardrails_dir)
      rule = File.join(provenance.guardrails_dir, "r.yml")
      File.write(rule, "x\n")
      stamp = File.stat(rule).ino
      was = provenance.read
      remerge

      now = provenance.read
      expect(now.slice(:version, :installed_at, :source)).to eq(was.slice(:version, :installed_at, :source))
      expect(File.stat(rule).ino).to eq(stamp)
    end

    it "refreshes the file's index line" do
      remerge

      line = File.read(File.join(memories, "index.md"))[/^- \*\*a\*\*.*$/]
      expect(line).to include("from demo", "What a is", merged.bytesize.to_s)
    end

    it "answers in a dry run, writing nothing" do
      result = remerge(dry_run: true)

      expect(result.merged).to eq(["a.md"])
      expect(result).to be_work
      expect(File.read(target)).to eq(doc(intro: "my intro"))
      expect(entry).to include(conflict: true)
      expect(base).to eq(doc)
      expect(trash_files).to be_empty
    end

    it "keeps a write that came in during the merge, with the mark on" do
      allow_any_instance_of(Samagotchi::MemoryBundle::Trash).to receive(:copy).and_wrap_original do |copy, *args, **opts|
        File.write(target, "a live memory_write\n")
        copy.call(*args, **opts)
      end
      result = remerge

      expect(result.merged).to eq([])
      expect(File.read(target)).to eq("a live memory_write\n")
      expect(entry).to include(conflict: true)
      expect(base).to eq(doc)
    end
  end

  context "with a real conflict" do
    before { marked_at_two(mine: doc(tail: "my tail"), shipped: doc(tail: "tail two")) }

    it "leaves the file, base and mark, and only records the digest, once" do
      result = remerge

      expect(result.merged).to eq([])
      expect(result.stamped).to eq(["a.md"])
      expect(File.read(target)).to eq(doc(tail: "my tail"))
      expect(base).to eq(doc)
      expect(entry).to include(conflict: true, incoming_sha: Digest::SHA256.hexdigest(doc(tail: "tail two")))
      expect(trash_files).to be_empty

      before = File.mtime(manifest_path)
      again = remerge
      expect(again).not_to be_work
      expect(File.mtime(manifest_path)).to eq(before)
    end

    it "records nothing in a dry run" do
      expect(remerge(dry_run: true).stamped).to eq(["a.md"])
      expect(entry).not_to have_key(:incoming_sha)
    end

    it "merges once the user's edit no longer overlaps" do
      remerge
      File.write(target, doc(intro: "my intro"))

      expect(remerge.merged).to eq(["a.md"])
      expect(File.read(target)).to eq(doc(intro: "my intro", tail: "tail two"))
      expect(entry).not_to have_key(:conflict)
      expect(entry).not_to have_key(:incoming_sha)
    end
  end

  context "when the shipped text isn't the one the mark names" do
    before do
      marked_at_two(mine: doc(intro: "my intro"), shipped: doc(tail: "tail two"))
      provenance.stamp_incoming("a.md" => "another-digest")
    end

    it "leaves it alone, running no git" do
      expect(Samagotchi::MemoryBundle::TextMerge).not_to receive(:merge)
      result = remerge

      expect(result).not_to be_work
      expect(File.read(target)).to eq(doc(intro: "my intro"))
      expect(entry).to include(conflict: true, incoming_sha: "another-digest")
    end
  end

  context "when the bundle has no such file now" do
    def expect_left_alone(result)
      expect(result).not_to be_work
      expect(result.notes).to eq(["a.md: not in the bundle now, nothing to merge"])
      expect(File.read(target)).to eq(doc(intro: "my intro"))
      expect(base).to eq(doc)
      expect(entry).to include(conflict: true)
    end

    before { marked_at_two(mine: doc(intro: "my intro"), shipped: doc(tail: "tail two")) }

    it "skips a file gone from the source, keeping its mark, base and text" do
      FileUtils.rm_f(File.join(source, "a.md"))
      expect_left_alone(remerge)
      expect_left_alone(remerge(dry_run: true))
    end

    it "skips a file the manifest no longer lists" do
      File.write(File.join(source, "b.md"), "b\n")
      write_b = YAML.safe_load_file(File.join(source, "manifest.yml")).merge("files" => { "b.md" => "sha256:fake" })
      File.write(File.join(source, "manifest.yml"), YAML.dump(write_b))
      expect_left_alone(remerge)
    end

    it "skips one that is a symlink now: never a memory" do
      FileUtils.rm_f(File.join(source, "a.md"))
      File.write(File.join(tmpdir, "secret"), doc(tail: "tail two"))
      File.symlink(File.join(tmpdir, "secret"), File.join(source, "a.md"))
      expect_left_alone(remerge)
    end
  end

  describe "other marked files" do
    it "settles one the user brought level with the bundle" do
      marked_at_two(mine: doc(tail: "tail two"), shipped: doc(tail: "tail two"))
      result = remerge

      expect(result.settled).to eq(["a.md"])
      expect(result.merged).to eq([])
      expect(entry).not_to have_key(:conflict)
      expect(base).to eq(doc(tail: "tail two"))
      expect(trash_files).to be_empty
    end

    it "settles one whose bundle text is back at the base: nothing to miss" do
      marked_at_two(mine: doc(intro: "my intro"), shipped: doc)
      expect(remerge.settled).to eq(["a.md"])
      expect(File.read(target)).to eq(doc(intro: "my intro"))
      expect(entry).not_to have_key(:conflict)
    end

    it "leaves one equal to its base for the next upgrade, which saves it first" do
      marked_at_two(mine: doc, shipped: doc(tail: "tail two"))
      result = remerge

      expect(result).not_to be_work
      expect(File.read(target)).to eq(doc)
      expect(entry).to include(conflict: true)
      expect(trash_files).to be_empty
    end

    it "leaves a missing one" do
      marked_at_two(mine: doc, shipped: doc(tail: "tail two"))
      FileUtils.rm_f(target)

      expect(remerge).not_to be_work
      expect(File.exist?(target)).to be false
    end

    it "gives a model overlay no index line" do
      marked_at_two(mine: doc(intro: "my intro"), shipped: doc(tail: "tail two"))
      FileUtils.mv(target, File.join(memories, "a.deepseek.md"))
      File.write(target, doc)
      manifest = YAML.safe_load_file(File.join(source, "manifest.yml"))
      manifest["files"] = { "a.md" => "sha256:fake", "a.deepseek.md" => "sha256:fake" }
      File.write(File.join(source, "manifest.yml"), YAML.dump(manifest))
      FileUtils.cp(File.join(source, "a.md"), File.join(source, "a.deepseek.md"))
      raw = JSON.parse(File.read(manifest_path))
      raw["files"] = { "a.md" => raw["files"]["a.md"].except("conflict"), "a.deepseek.md" => raw["files"]["a.md"] }
      File.write(manifest_path, JSON.pretty_generate(raw))
      FileUtils.cp(provenance.base_path("a.md"), provenance.base_path("a.deepseek.md"))

      expect(remerge.merged).to eq(["a.deepseek.md"])
      expect(File.read(File.join(memories, "index.md"))).not_to include("a.deepseek")
    end
  end

  it "leaves a file it can't replace, marked, with a note, when the trash can't hold the copy" do
    marked_at_two(mine: doc(intro: "my intro"), shipped: doc(tail: "tail two"))
    File.write(File.join(Samagotchi::MemoryPaths.bundles_dir, ".trash"), "in the way\n")
    result = remerge

    expect(result.merged).to eq([])
    expect(result.notes.first).to start_with("a.md: left as it is (")
    expect(File.read(target)).to eq(doc(intro: "my intro"))
    expect(entry).to include(conflict: true)
    expect(base).to eq(doc)
  end

  it "stamps only an entry still marked" do
    write_source("1.0.0", doc)
    install
    provenance.stamp_incoming("a.md" => "digest")

    expect(entry).not_to have_key(:incoming_sha)
  end

  it "reads nothing with no marks" do
    write_source("1.0.0", doc)
    install
    expect(Samagotchi::MemoryBundle::Manifest).not_to receive(:read)
    expect(remerge).to eq(described_class::NOTHING)
  end

  it "answers nothing when there is no record" do
    expect(described_class.new(name: "gone", scope: "system", target_dir: memories, source_dir: source).run).to eq(described_class::NOTHING)
  end

  describe "the mark's digest" do
    it "is recorded by an upgrade's conflict, and goes when a later upgrade merges" do
      write_source("1.0.0", doc)
      install
      File.write(target, doc(tail: "my tail"))
      write_source("2.0.0", doc(tail: "tail two"))
      install(upgrade: true)
      expect(entry).to include(conflict: true, incoming_sha: Digest::SHA256.hexdigest(doc(tail: "tail two")))

      File.write(target, doc(intro: "my intro"))
      write_source("3.0.0", doc(tail: "tail three"))
      install(upgrade: true)
      expect(entry).not_to have_key(:conflict)
      expect(entry).not_to have_key(:incoming_sha)
    end

    it "is recorded when there is no git too, so the retry finds the same text" do
      write_source("1.0.0", doc)
      install
      File.write(target, doc(intro: "my intro"))
      write_source("2.0.0", doc(tail: "tail two"))
      FileUtils.mkdir_p(File.join(tmpdir, "no-git"))
      with_env("PATH" => File.join(tmpdir, "no-git")) do
        install(upgrade: true)
        expect(entry).to include(conflict: true)
        expect(remerge.merged).to eq([])
      end
      expect(File.read(target)).to eq(doc(intro: "my intro"))

      expect(remerge.merged).to eq(["a.md"])
    end

    it "follows a plain install that keeps a mark: it is that source's text the file missed" do
      write_source("1.0.0", doc)
      install
      File.write(target, doc(tail: "my tail"))
      write_source("2.0.0", doc(tail: "tail two"))
      install(upgrade: true)
      write_source("3.0.0", doc(tail: "tail three"))
      install

      expect(entry).to include(conflict: true, incoming_sha: Digest::SHA256.hexdigest(doc(tail: "tail three")))
    end

    it "goes when an agent step settles the file" do
      write_source("1.0.0", doc)
      install
      File.write(target, doc(tail: "my tail"))
      write_source("2.0.0", doc(tail: "tail two"))
      install(upgrade: true)
      provenance.resolve_conflicts("a.md" => { incoming: File.join(source, "a.md"), current: target })

      expect(entry).to eq(checksum: Digest::SHA256.hexdigest(doc(tail: "tail two")), description: "What a is")
    end
  end
end
