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

  # A mark as this chi makes it: it names what it missed.
  # The mark as a retry would have left it, naming +sha+ as the bundle's text.
  def mark_names(sha, legacy_base: false)
    raw = JSON.parse(File.read(manifest_path))
    raw["files"]["a.md"]["incoming_sha"] = sha
    raw["files"]["a.md"]["legacy_base"] = true if legacy_base
    File.write(manifest_path, JSON.pretty_generate(raw))
  end

  def new_mark
    raw = JSON.parse(File.read(manifest_path))
    raw["files"]["a.md"]["incoming_sha"] = Digest::SHA256.hexdigest(File.read(File.join(source, "a.md")))
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
    let(:merged) { doc(intro: "my intro", tail: "the tail\nand a new line") }

    before { marked_at_two(mine: doc(intro: "my intro"), shipped: doc(tail: "the tail\nand a new line")) }

    it "merges once, the base the incoming file and the mark gone, then does nothing" do
      result = remerge

      expect(result.merged).to eq(["a.md"])
      expect(result.trash_copy).to include("Copied to the trash first: a.md")
      expect(File.read(target)).to eq(merged)
      expect(base).to eq(doc(tail: "the tail\nand a new line"))
      expect(entry.except(:merged_version, :merged_at, :merged_trash)).to eq(checksum: Digest::SHA256.hexdigest(doc(tail: "the tail\nand a new line")), description: "What a is")
      expect(entry).to include(merged_version: "2.0.0")
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
      new_mark
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
      mark_names("another-digest")
    end

    it "leaves it alone, running no git" do
      expect(Samagotchi::MemoryBundle::TextMerge).not_to receive(:merge)
      result = remerge

      expect(result).not_to be_work
      expect(File.read(target)).to eq(doc(intro: "my intro"))
      expect(entry).to include(conflict: true, incoming_sha: "another-digest")
    end

    it "reads as behind in the mark's words" do
      expect(remerge.behind.map(&:file)).to eq(["a.md"])
    end

    it "isn't behind when the file is level with the text the mark names" do
      mark_names(Digest::SHA256.hexdigest(doc(intro: "my intro")))

      expect(remerge).to have_attributes(behind: [], merged: [], settled: [])
    end
  end

  context "when the bundle has no such file now" do
    def expect_left_alone(result)
      expect(result).not_to be_work
      expect(result.behind.map(&:line)).to eq(["a.md stays behind 2.0.0: not in the bundle now, nothing to merge"])
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

    it "isn't behind when level with the mark's text, or missing" do
      FileUtils.rm_f(File.join(source, "a.md"))
      mark_names(Digest::SHA256.hexdigest(doc(intro: "my intro")))
      expect(remerge.behind).to be_empty

      mark_names("other")
      FileUtils.rm_f(target)
      expect(remerge.behind).to be_empty
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

    it "settles one that already holds the bundle's change, with no claim of a merge" do
      both = doc(intro: "my intro", tail: "tail two")
      marked_at_two(mine: both, shipped: doc(tail: "tail two"))
      result = remerge

      expect(result).to have_attributes(merged: [], settled: ["a.md"], trash_copy: nil)
      expect(File.read(target)).to eq(both)
      expect(entry).not_to have_key(:conflict)
      expect(base).to eq(doc(tail: "tail two"))
    end

    it "leaves one equal to its base, with a mark this chi made, for the next upgrade, which saves it first" do
      marked_at_two(mine: doc, shipped: doc(tail: "tail two"))
      new_mark
      result = remerge

      expect(result.behind.map(&:line)).to eq(["a.md stays behind 2.0.0: #{Samagotchi::MemoryBundle::FileStanding::WAITS_FOR_UPGRADE}"])
      expect(File.read(target)).to eq(doc)
      expect(entry).to include(conflict: true, why: Samagotchi::MemoryBundle::FileStanding::WAITS_FOR_UPGRADE)
      expect(trash_files).to be_empty
      expect(remerge).not_to be_work
    end

    it "leaves a missing one" do
      marked_at_two(mine: doc, shipped: doc(tail: "tail two"))
      FileUtils.rm_f(target)

      expect(remerge).to have_attributes(merged: [], behind: [], warnings: ["a.md: #{Samagotchi::MemoryBundle::FileStanding::FILE_MISSING}"])
      expect(remerge).not_to be_work
      expect(File.exist?(target)).to be false
    end

    it "gives a model overlay no index line" do
      marked_at_two(mine: doc(intro: "my intro"), shipped: doc(tail: "the tail\nand a new line"))
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

  # 0.149 took a file with no base as its own base: base = the user's text U.
  # A merge then reads the bundle's text as "undo U", and takes U out of the file.
  describe "a mark from an older chi whose base is the user's own text" do
    let(:user_text) { doc(intro: "my intro") }
    let(:live) { "#{user_text}one more edit\n" }
    let(:shipped) { doc }
    let(:why) { "chi can't tell whether it holds edits of yours (#{Samagotchi::MemoryBundle::FileStanding::LEGACY_BASE})" }

    before { allow(Gem).to receive(:path).and_return([]) }

    # What 0.149 left, at 2.0.0, and one more edit since.
    def legacy_mark(version: "2.0.0")
      write_source("1.0.0", doc)
      install
      File.write(provenance.base_path("a.md"), user_text)
      File.write(target, live)
      raw = JSON.parse(File.read(manifest_path))
      raw["version"] = version
      File.write(manifest_path, JSON.pretty_generate(raw))
      old_mark
      write_source(version, shipped)
    end

    def expect_kept
      expect(File.read(target)).to eq(live)
      expect(base).to eq(user_text)
      expect(entry).to include(conflict: true, legacy_base: true)
      expect(trash_files).to be_empty
    end

    it "doesn't let a retry take the user's lines out" do
      legacy_mark
      result = remerge

      expect(result).to have_attributes(merged: [], settled: [], stamped: ["a.md"])
      expect_kept
    end

    it "keeps the protection once its digest is recorded: a later run is the same" do
      legacy_mark
      remerge
      expect(entry).to include(incoming_sha: Digest::SHA256.hexdigest(shipped))
      stamp = File.mtime(manifest_path)

      expect(remerge).not_to be_work
      expect(File.mtime(manifest_path)).to eq(stamp)
      expect_kept
    end

    it "doesn't let a new version's upgrade take them out, and the warning says why" do
      legacy_mark
      write_source("3.0.0", shipped)
      up = install(upgrade: true)

      expect(up.results["a.md"][:status]).to eq("conflict")
      expect(up.merged_files).to be_empty
      expect(up.warnings).to include(a_string_including(why))
      expect_kept
    end

    it "keeps it through a retry, then upgrades, then a plain install" do
      legacy_mark
      remerge
      write_source("3.0.0", shipped)
      install(upgrade: true)
      expect_kept
      write_source("4.0.0", doc(intro: "the intro again", tail: "tail four"))
      expect(install(upgrade: true).results["a.md"][:status]).to eq("conflict")
      expect_kept
      write_source("5.0.0", shipped)
      install
      expect_kept
    end

    context "when the file is the base: nothing but the bundle's text would be left of it" do
      before do
        legacy_mark
        File.write(target, user_text)
      end

      it "doesn't let a retry replace it" do
        expect(remerge).to have_attributes(merged: [], stamped: ["a.md"])
        expect(File.read(target)).to eq(user_text)
        expect(base).to eq(user_text)
        expect(entry).to include(conflict: true, legacy_base: true)
        expect(trash_files).to be_empty
      end

      it "doesn't let an upgrade fast-forward over it, and says why, in a dry run too" do
        write_source("3.0.0", shipped)
        dry = install(upgrade: true, dry_run: true)
        expect(dry.results["a.md"][:status]).to eq("conflict")
        expect(dry.summary).not_to include("Fast-forward")
        expect(dry.summary).to include(why)

        up = install(upgrade: true)
        expect(up.results["a.md"][:status]).to eq("conflict")
        expect(up.warnings).to include(a_string_including(why))
        expect(File.read(target)).to eq(user_text)
        expect(base).to eq(user_text)
        expect(trash_files).to be_empty
      end
    end

    # Nothing of the file goes, so the guard's reason doesn't hold.
    it "lets a file equal to its base take an update that only adds, a spare copy in the trash, and says so" do
      write_source("1.0.0", doc)
      install
      old_mark
      added = doc(tail: "the tail\nand a new line")
      write_source("2.0.0", added)
      up = install(upgrade: true)

      expect(File.read(target)).to eq(added)
      expect(trash_files).to eq("a.md" => doc)
      expect(up.warnings).to include(a_string_including("your copy is in the trash"))
      expect(entry).not_to include(:conflict, :legacy_base, :incoming_sha)
      expect(base).to eq(added)
    end

    it "doesn't count a line the bundle kept but moved as taken out, and counts a lost repeat" do
      merger = Samagotchi::MemoryBundle::Merger
      expect(merger.removes_lines?("a\nb\n", "b\nnew\na\n")).to be false
      expect(merger.removes_lines?("a\n\nb\n", "a\nb\n")).to be true
      expect(merger.removes_lines?("a\na\n", "a\n")).to be true
      expect(merger.removes_lines?("a", "a\n")).to be false
    end

    # What the guard costs: it can't tell this base from the user's text.
    it "leaves a file that really is the bundle's old text behind, unchanged, until --force" do
      write_source("1.0.0", doc)
      install
      old_mark
      write_source("2.0.0", doc(tail: "tail two"))
      up = install(upgrade: true)

      expect(up.results["a.md"][:status]).to eq("conflict")
      expect(File.read(target)).to eq(doc)
      expect(base).to eq(doc)
      expect(entry).to include(conflict: true, legacy_base: true)
      expect(remerge).not_to be_work

      install(upgrade: true, force: true)
      expect(File.read(target)).to eq(doc(tail: "tail two"))
      expect(entry).not_to include(:conflict, :legacy_base, :incoming_sha)
      expect(trash_files.keys).to eq(["a.md"])
    end

    it "says the same in a dry run and in a plan's forecast" do
      legacy_mark
      write_source("3.0.0", shipped)
      dry = install(upgrade: true, dry_run: true)

      expect(dry.results["a.md"][:status]).to eq("conflict")
      expect(dry.summary).to include(why)
      expect(Samagotchi::MemoryBundle::Merger::Upgrade.new(provenance: provenance, target_dir: memories, source_dir: source).forecast(["a.md"]))
        .to have_attributes(merged: [], conflicts: ["a.md"])
      expect(File.read(target)).to eq(live)
      expect(entry).not_to have_key(:legacy_base)
    end

    it "still merges when the merge takes no line out, and the mark and the protection go" do
      write_source("1.0.0", doc)
      install
      File.write(target, doc(intro: "my intro"))
      old_mark
      write_source("1.0.0", doc(tail: "the tail\nand a new line"))
      result = remerge

      expect(result.merged).to eq(["a.md"])
      expect(File.read(target)).to eq(doc(intro: "my intro", tail: "the tail\nand a new line"))
      expect(entry).not_to include(:conflict, :legacy_base, :incoming_sha)
    end

    it "lets it go once the file no longer stands to lose lines, even after a stamp" do
      legacy_mark
      remerge
      File.write(target, "#{doc}my line\n")

      expect(remerge.settled).to eq(["a.md"])
      expect(File.read(target)).to eq("#{doc}my line\n")
      expect(entry).not_to include(:conflict, :legacy_base, :incoming_sha)
    end

    it "goes when an agent step settles the file" do
      legacy_mark
      remerge
      provenance.resolve_conflicts("a.md" => { incoming: File.join(source, "a.md"), current: target })

      expect(entry).not_to include(:conflict, :legacy_base, :incoming_sha)
    end

    it "doesn't touch a mark this chi made: a merge there may take the bundle's removals" do
      write_source("1.0.0", doc)
      install
      File.write(target, doc(intro: "my intro"))
      write_source("2.0.0", doc(tail: "my tail"))
      FileUtils.mkdir_p(File.join(tmpdir, "no-git"))
      with_env("PATH" => File.join(tmpdir, "no-git")) { install(upgrade: true) }
      expect(entry).to include(conflict: true)
      expect(entry).not_to have_key(:legacy_base)

      expect(remerge.merged).to eq(["a.md"])
      expect(File.read(target)).to eq(doc(intro: "my intro", tail: "my tail"))
      expect(File.read(target)).not_to include("the tail")
    end
  end

  # All the known marks have a base some chi shipped: provably not the user's text.
  describe "a mark from an older chi whose base is a version chi shipped" do
    let(:gems) { File.join(tmpdir, "gems") }
    let(:edited) { doc(intro: "my intro") }
    let(:reworded) { doc(tail: "tail two") }

    def ship_in_gem(version, text, name: "demo", dir: "some-old-dir", file: "a.md", manifest: nil)
      bundle = File.join(gems, "gems", "samagotchi-#{version}", "lib", "samagotchi", "bundles", dir)
      FileUtils.mkdir_p(bundle)
      File.write(File.join(bundle, file), text)
      File.write(File.join(bundle, "manifest.yml"), manifest || YAML.dump({ "name" => name, "version" => "0.1.0", "scope" => "system" }))
      bundle
    end

    def old_marked(mine)
      write_source("1.0.0", doc)
      install
      File.write(target, mine)
      old_mark
    end

    before { allow(Gem).to receive(:path).and_return([gems]) }

    it "merges a line the bundle reworded, on a retry, and settles: base incoming, mark and flag gone" do
      ship_in_gem("0.1.0", "another bundle's older text\n")
      ship_in_gem("0.2.0", doc)
      old_marked(edited)
      write_source("1.0.0", reworded)
      result = remerge

      expect(result.merged).to eq(["a.md"])
      expect(File.read(target)).to eq(doc(intro: "my intro", tail: "tail two"))
      expect(base).to eq(reworded)
      expect(entry).not_to include(:conflict, :legacy_base, :incoming_sha)
    end

    it "merges on a new version's upgrade, after a stamp too" do
      ship_in_gem("0.2.0", doc)
      old_marked(edited)
      mark_names("older-text", legacy_base: true)
      write_source("2.0.0", reworded)
      up = install(upgrade: true)

      expect(up.merged_files).to eq(["a.md"])
      expect(entry).not_to include(:conflict, :legacy_base, :incoming_sha)
    end

    it "lets a file equal to that base take the update, a spare copy in the trash" do
      ship_in_gem("0.2.0", doc)
      old_marked(doc)
      write_source("2.0.0", reworded)
      up = install(upgrade: true)

      expect(File.read(target)).to eq(reworded)
      expect(trash_files).to eq("a.md" => doc)
      expect(up.warnings).to include(a_string_including("your copy is in the trash"))
      expect(entry).not_to include(:conflict, :legacy_base)
    end

    it "keeps a real conflict a mark, its file and base untouched" do
      ship_in_gem("0.2.0", doc)
      old_marked(doc(tail: "my tail"))
      write_source("1.0.0", reworded)

      expect(remerge).to have_attributes(merged: [], stamped: ["a.md"])
      expect(File.read(target)).to eq(doc(tail: "my tail"))
      expect(base).to eq(doc)
      expect(entry).to include(conflict: true, legacy_base: true)
    end

    context "with no proof" do
      def expect_blocked
        old_marked(edited)
        write_source("1.0.0", reworded)
        expect(remerge.merged).to eq([])
        expect(File.read(target)).to eq(edited)
        expect(base).to eq(doc)
        expect(entry).to include(conflict: true)
      end

      it "blocks with no gems at all" do
        expect_blocked
      end

      it "blocks when another bundle shipped those bytes" do
        ship_in_gem("0.2.0", doc, name: "someone-else")
        expect_blocked
      end

      it "blocks when another file of the bundle had those bytes, or other bytes of that size" do
        ship_in_gem("0.2.0", doc, file: "b.md")
        ship_in_gem("0.3.0", doc.tr("e", "x"))
        expect_blocked
      end

      it "blocks on a gem that only looks like samagotchi's" do
        bundle = ship_in_gem("0.2.0", doc)
        FileUtils.mv(File.dirname(bundle, 4), File.join(gems, "gems", "samagotchi-tools-0.2.0"))
        expect_blocked
      end

      it "blocks when the manifest doesn't parse or isn't a mapping" do
        ship_in_gem("0.2.0", doc, manifest: "name: [unclosed\n")
        ship_in_gem("0.3.0", doc, manifest: "- not a mapping\n")
        expect_blocked
      end

      it "blocks when a gem's folder or file can't be read" do
        skip "root reads anything" if Process.uid.zero?
        bundle = ship_in_gem("0.2.0", doc)
        File.chmod(0o000, File.join(bundle, "a.md"))
        File.chmod(0o000, ship_in_gem("0.3.0", doc))
        begin
          expect_blocked
        ensure
          File.chmod(0o644, File.join(bundle, "a.md"))
          File.chmod(0o755, File.join(gems, "gems", "samagotchi-0.3.0", "lib", "samagotchi", "bundles", "some-old-dir"))
        end
      end

      it "blocks a file equal to its base from fast-forwarding too" do
        ship_in_gem("0.2.0", doc, name: "someone-else")
        old_marked(doc)
        write_source("2.0.0", reworded)
        up = install(upgrade: true)

        expect(up.results["a.md"][:status]).to eq("conflict")
        expect(File.read(target)).to eq(doc)
        expect(trash_files).to be_empty
      end

      it "doesn't look at the gems unless the guard would fire" do
        old_marked(edited)
        write_source("1.0.0", doc(tail: "the tail\nand a new line"))
        expect(Gem).not_to receive(:path)

        expect(remerge.merged).to eq(["a.md"])
      end
    end
  end

  it "marks a merge a live write got in front of, the mark saying so" do
    marked_at_two(mine: doc(intro: "my intro"), shipped: doc(tail: "the tail\nand a new line"))
    allow_any_instance_of(Samagotchi::MemoryBundle::Trash).to receive(:copy).and_wrap_original do |copy, *args, **opts|
      File.write(target, "a live memory_write\n")
      copy.call(*args, **opts)
    end
    result = remerge

    expect(result.merged).to be_empty
    expect(result.behind.map(&:why)).to eq(["no merge possible (#{Samagotchi::MemoryBundle::TextMerge::RACED})"])
    expect(entry).to include(conflict: true, why: "no merge possible (#{Samagotchi::MemoryBundle::TextMerge::RACED})")
    expect(File.read(target)).to eq("a live memory_write\n")
  end

  it "leaves a file it can't replace, marked, with a note, when the trash can't hold the copy" do
    marked_at_two(mine: doc(intro: "my intro"), shipped: doc(tail: "the tail\nand a new line"))
    File.write(File.join(Samagotchi::MemoryPaths.bundles_dir, ".trash"), "in the way\n")
    result = remerge

    expect(result.merged).to eq([])
    expect(result.behind.first.line).to start_with("a.md stays behind 2.0.0: left as it is (")
    expect(File.read(target)).to eq(doc(intro: "my intro"))
    expect(entry).to include(conflict: true)
    expect(base).to eq(doc)
  end

  it "stamps only an entry still marked" do
    write_source("1.0.0", doc)
    install
    provenance.refresh_marks([Samagotchi::MemoryBundle::FileStanding::Behind.new(file: "a.md")], source)

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
