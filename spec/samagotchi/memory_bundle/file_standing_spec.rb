# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"

require "samagotchi/memory_bundle/builder"
require "samagotchi/memory_bundle/installer"
require "samagotchi/memory_bundle/remerge"
require "samagotchi/memory_bundle/listing"
require "samagotchi/memory_bundle/status"
require "samagotchi/memory_bundle/uninstaller"

# What chi says of a bundle file that stays behind, and what the record keeps
# for it to say that.
RSpec.describe Samagotchi::MemoryBundle::FileStanding do
  let(:behind) { described_class::Behind }

  describe "the words" do
    it "says what a file missed, three headings and a count" do
      headings = ["## A", "## B", "## C", "## D", "## E"]

      expect(behind.new(file: "x.md", version: "1", missed: headings.first(3)).line).to eq("x.md stays behind 1: missed ## A, ## B, ## C")
      expect(behind.new(file: "x.md", version: "1", missed: headings).line).to eq("x.md stays behind 1: missed ## A, ## B, ## C and 2 more")
      expect(behind.new(file: "x.md", version: "1", missed: headings.first(3), places: 1).line).to end_with("## C and 1 more")
    end

    it "adds a change under no heading to the named ones, however few" do
      expect(described_class.missed_words(["## A"], 1)).to eq("missed ## A and 1 more")
      expect(described_class.missed_words(["## A"], 5)).to eq("missed ## A and 5 more")
      expect(described_class.missed_words(["## A", "## B", "## C", "## D"], 1)).to eq("missed ## A, ## B, ## C and 2 more")
    end

    it "counts places when there are no headings" do
      expect(behind.new(file: "x.md", version: "1", places: 1).line).to eq("x.md stays behind 1: missed 1 place")
      expect(behind.new(file: "x.md", version: "1", places: 2).line).to eq("x.md stays behind 1: missed 2 places")
    end

    it "says why before what, and nothing beyond behind when it knows neither" do
      why = described_class.no_merge("git not found")

      expect(behind.new(file: "x.md", version: "1", why: why, missed: ["## A"]).line).to eq("x.md stays behind 1: no merge possible (git not found); missed ## A")
      expect(behind.new(file: "x.md", version: "1").line).to eq("x.md stays behind 1")
      expect(behind.new(file: "x.md", version: "1").line(dry_run: true)).to eq("x.md would stay behind 1")
    end

    it "doesn't claim edits for a base it can't vouch for" do
      words = described_class.no_merge(described_class::LEGACY_BASE)

      expect(words).to start_with("chi can't tell whether it holds edits of yours")
      expect(behind.new(file: "x.md", version: "1", why: words).line).not_to include("kept", "your edits")
    end

    it "reads a wrong shape as nothing known" do
      file = behind.new(file: "x.md", version: "1", why: { "a" => 1 }, missed: { "x" => 1 }, places: { "a" => 1 })

      expect(file.line).to eq("x.md stays behind 1")
      expect(behind.new(file: "x.md", missed: ["## A", 3, nil], places: "2")).to have_attributes(missed: ["## A"], places: 0)
    end

    it "joins any file name and heading in one line" do
      name = "заметки.md".dup.force_encoding(Encoding::US_ASCII)
      line = behind.new(file: name, version: "1", missed: ["## Выводы — главное".b]).line

      expect(line).to eq("заметки.md stays behind 1: missed ## Выводы — главное")
      expect(described_class.merged_line([name], "1")).to eq("merged 1 into your заметки.md")
      expect(described_class.clauses("b", "1", behind: [behind.new(file: name, version: "1")]).first).to include("chi bundle diff b заметки.md")
    end

    it "counts in one wording" do
      expect(described_class.behind_count(1)).to eq("1 file behind")
      expect(described_class.behind_count(2)).to eq("2 files behind")
      expect(described_class.stay_behind(1)).to eq("1 file stays behind")
      expect(described_class.stay_behind(2)).to eq("2 files stay behind")
      expect(described_class.behind_count(2, unsure: true)).to eq("2 files may be behind")
      expect(described_class.stay_behind(1, unsure: true)).to eq("1 file may be behind")
    end

    it "gives a report's clauses, the diff hint once" do
      files = [behind.new(file: "a.md", version: "2", missed: ["## A"]), behind.new(file: "b.md", version: "2")]

      expect(described_class.clauses("demo", "2", merged: ["c.md"], behind: files))
        .to eq(["merged 2 into your c.md", "a.md stays behind 2: missed ## A (chi bundle diff demo a.md)", "b.md stays behind 2"])
    end
  end

  describe "a marked file in the record" do
    let(:tmpdir) { Dir.mktmpdir("samagotchi-standing-") }
    let(:memories) { Samagotchi::MemoryPaths.system_dir }
    let(:provenance) { Samagotchi::MemoryBundle::Provenance.new(name: "demo") }
    let(:target) { File.join(memories, "a.md") }
    let(:source) { File.join(tmpdir, "src") }
    let(:saved) { provenance.incoming_path("a.md") }

    around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

    after { FileUtils.rm_rf(tmpdir) }

    def doc(steps: "one", rules: "two", intro: "intro")
      "# T\n\n#{intro}\n\n## Steps\n\n#{steps}\n\n## Rules\n\n#{rules}\n"
    end

    def write_source(version, text)
      FileUtils.rm_rf(source)
      FileUtils.mkdir_p(source)
      File.write(File.join(source, "a.md"), text)
      File.write(File.join(source, "manifest.yml"),
                 YAML.dump({ "name" => "demo", "version" => version, "scope" => "system", "files" => { "a.md" => "sha256:fake" } }))
    end

    def install(**opts) = Samagotchi::MemoryBundle::Installer.new(source: source, name: "demo", strict: true, **opts).tap(&:run)
    def entry = provenance.read[:files][:"a.md"]
    def remerge = Samagotchi::MemoryBundle::Remerge.new(name: "demo", scope: "system", target_dir: memories, source_dir: source).run
    def behind_lines = provenance.record.behind_files.map(&:line)

    # Installed at 1.0.0, edited, and left behind 2.0.0 by a real conflict in
    # ## Steps; the bundle changed ## Rules too, which a merge would have brought.
    def left_behind
      write_source("1.0.0", doc)
      install
      File.write(target, doc(steps: "mine"))
      write_source("2.0.0", doc(steps: "theirs", rules: "new rules"))
      install(upgrade: true)
    end

    context "with a heading that isn't ASCII" do
      def non_ascii(steps: "one") = "# Заметки\n\n## Шаги — главное\n\n#{steps}\n\n## caf\xE9\n\nsame\n".b

      before do
        write_source("1.0.0", non_ascii)
        install
        File.binwrite(target, non_ascii(steps: "мой"))
        write_source("2.0.0", non_ascii(steps: "новый"))
      end

      it "records it through a manifest round trip, the upgrade going through" do
        up = install(upgrade: true)

        expect(up.results["a.md"][:status]).to eq("conflict")
        expect(provenance.record.version).to eq("2.0.0")
        expect(entry[:missed]).to eq(["## Шаги — главное"])
        expect(behind_lines).to eq(["a.md stays behind 2.0.0: missed ## Шаги — главное"])
        expect(File.binread(target)).to eq(non_ascii(steps: "мой"))
      end

      it "finds the mark unchanged at the next retry, with no write" do
        install(upgrade: true)
        expect(remerge).not_to be_work
      end
    end

    it "handles a file name that isn't ASCII" do
      name = "заметки.md"
      FileUtils.rm_rf(source)
      FileUtils.mkdir_p(source)
      File.write(File.join(source, name), doc)
      File.write(File.join(source, "manifest.yml"), YAML.dump({ "name" => "demo", "version" => "1.0.0", "scope" => "system", "files" => { name => "sha256:fake" } }))
      install
      File.write(File.join(memories, name), doc(steps: "мой — шаг"))
      File.write(File.join(source, name), doc(steps: "новый"))
      File.write(File.join(source, "manifest.yml"), YAML.dump({ "name" => "demo", "version" => "2.0.0", "scope" => "system", "files" => { name => "sha256:fake" } }))
      install(upgrade: true)

      expect(behind_lines).to eq(["заметки.md stays behind 2.0.0: missed ## Steps"])
      expect(File.exist?(provenance.incoming_path(name))).to be true
    end

    it "reads a wrong-shaped record as nothing known, in every surface" do
      left_behind
      manifest = File.join(provenance.bundle_dir, "manifest.json")
      raw = JSON.parse(File.read(manifest))
      raw["files"]["a.md"].merge!("missed" => { "x" => 1 }, "missed_places" => {}, "why" => 7)
      File.write(manifest, JSON.generate(raw))

      expect(behind_lines).to eq(["a.md stays behind 2.0.0"])
      expect(Samagotchi::MemoryBundle::Listing.installed(shipped: []).first.behind.size).to eq(1)
      expect(Samagotchi::MemoryBundle::Status.bundle_status("demo").files["a.md"][:behind]).not_to be_nil
    end

    it "records what the bundle changed, not only where the conflict is" do
      up = left_behind

      expect(entry).to include(conflict: true, missed: ["## Steps", "## Rules"])
      expect(up.behind.map(&:line)).to eq(["a.md stays behind 2.0.0: missed ## Steps, ## Rules"])
      expect(behind_lines).to eq(["a.md stays behind 2.0.0: missed ## Steps, ## Rules"])
    end

    it "names the changed intro beside a heading, and counts only the hunks under no heading" do
      write_source("1.0.0", doc)
      install
      File.write(target, doc(steps: "mine", intro: "my intro"))
      write_source("2.0.0", doc(steps: "theirs", intro: "new intro"))
      install(upgrade: true)

      expect(entry).to include(missed: ["# T", "## Steps"])
      expect(entry).not_to have_key(:missed_places)

      plain = "one\n\ntwo\n\nthree\n\nfour\n\nfive\n\nsix\n\nseven\n"
      write_source("3.0.0", plain)
      install(upgrade: true, force: true)
      File.write(target, plain.sub("one", "mine 1").sub("seven", "mine 7"))
      write_source("4.0.0", plain.sub("one", "new 1").sub("seven", "new 7"))
      install(upgrade: true)

      expect(entry).to include(missed_places: 2)
      expect(behind_lines).to eq(["a.md stays behind 4.0.0: missed 2 places"])
    end

    it "doesn't call a section missed that the user brought over by hand" do
      write_source("1.0.0", doc)
      install
      File.write(target, doc(steps: "mine", rules: "new rules"))
      write_source("2.0.0", doc(steps: "theirs", rules: "new rules"))
      install(upgrade: true)

      expect(entry[:missed]).to eq(["## Steps"])
    end

    it "saves the bundle's text until the file settles, and the folder goes with the last" do
      left_behind
      expect(File.read(saved)).to eq(doc(steps: "theirs", rules: "new rules"))

      File.write(target, doc(rules: "new rules"))
      write_source("2.0.0", doc(steps: "theirs", rules: "new rules"))
      expect(remerge.merged).to eq(["a.md"])
      expect(File.exist?(saved)).to be false
      expect(Dir.exist?(File.dirname(saved))).to be false
      expect(entry.keys).not_to include(:why, :missed, :missed_places, :conflict)
    end

    it "goes through when the text can't be saved: the record must follow the assets" do
      write_source("1.0.0", doc)
      install
      File.write(target, doc(steps: "mine"))
      File.write(File.join(provenance.bundle_dir, "incoming"), "in the way\n")
      write_source("2.0.0", doc(steps: "theirs"))
      up = install(upgrade: true)

      expect(up.behind.map(&:file)).to eq(["a.md"])
      expect(provenance.record.version).to eq("2.0.0")
      expect(entry).to include(conflict: true, incoming_sha: Digest::SHA256.hexdigest(doc(steps: "theirs")))
    end

    it "notes a merge whichever way the run ended, and none in a dry run" do
      write_source("1.0.0", doc)
      install
      File.write(target, doc(intro: "mine"))
      write_source("2.0.0", doc(rules: "new"))
      install(upgrade: true, dry_run: true)
      expect(provenance.record.merge_notes).to be_empty

      allow_any_instance_of(Samagotchi::MemoryBundle::Provenance).to receive(:write).and_raise("the disk is full")
      expect { install(upgrade: true) }.to raise_error("the disk is full")
      expect(provenance.record.merge_notes.map { |note| [note.file, note.version] }).to eq([["a.md", "2.0.0"]])
      expect(provenance.record.version).to eq("1.0.0")
    end

    it "gives one answer to behind, a restored file's saved text going too" do
      left_behind
      recorded = provenance.record
      File.write(target, File.read(saved))
      expect(recorded.behind_files).to be_empty
      expect(remerge.behind).to be_empty

      provenance.record_restored("a.md", File.join(source, "a.md"))
      expect(File.exist?(saved)).to be false
      expect(entry.keys).not_to include(:conflict, :missed)
    end

    it "clears a note only for that merge: another with the same version stays" do
      write_source("1.0.0", doc)
      install
      provenance.note_merged(["a.md"], version: "1.0.0", trash: nil, at: Time.at(1))
      read = provenance.record.merge_notes
      provenance.note_merged(["a.md"], version: "1.0.0", trash: nil, at: Time.at(2))

      provenance.clear_merge_notes(read)
      expect(provenance.record.merge_notes.size).to eq(1)
    end

    it "fails no report when a note can't be cleared" do
      write_source("1.0.0", doc)
      install
      File.write(File.join(provenance.bundle_dir, "manifest.json"), "not json")

      expect { provenance.clear_merge_notes([], files: ["a.md"]) }.not_to raise_error
    end

    it "ends a merge's note when --force replaces the file" do
      write_source("1.0.0", doc)
      install
      File.write(target, doc(intro: "mine"))
      write_source("2.0.0", doc(rules: "new"))
      install(upgrade: true)
      expect(provenance.record.merge_notes.size).to eq(1)

      write_source("3.0.0", doc(rules: "newer"))
      install(upgrade: true, force: true)
      expect(provenance.record.merge_notes).to be_empty
    end

    it "drops the saved text when an upgrade settles the file" do
      left_behind
      File.write(target, doc(steps: "newer", rules: "new rules"))
      write_source("3.0.0", doc(steps: "newer", rules: "new rules"))
      install(upgrade: true)

      expect(File.exist?(saved)).to be false
    end

    it "replaces the saved text and the record at the next version's conflict" do
      left_behind
      write_source("3.0.0", doc(steps: "theirs again", rules: "new rules", intro: "new intro"))
      install(upgrade: true)

      expect(File.read(saved)).to eq(doc(steps: "theirs again", rules: "new rules", intro: "new intro"))
      expect(behind_lines).to eq(["a.md stays behind 3.0.0: missed # T, ## Steps, ## Rules"])
    end

    it "keeps the mark through a plain install, its words those of the source it now speaks of" do
      left_behind
      write_source("3.0.0", doc(steps: "theirs", rules: "new rules", intro: "new intro"))
      install

      expect(entry).to include(conflict: true, missed: ["# T", "## Steps", "## Rules"])
      expect(File.read(saved)).to eq(doc(steps: "theirs", rules: "new rules", intro: "new intro"))
    end

    it "drops an old reason at a plain install: no merge ran for this source" do
      left_behind
      FileUtils.mkdir_p(File.join(tmpdir, "no-git"))
      with_env("PATH" => File.join(tmpdir, "no-git")) { remerge }
      expect(entry).to include(why: "no merge possible (git not found)")

      write_source("3.0.0", doc(steps: "theirs", rules: "new rules"))
      install
      expect(entry).not_to have_key(:why)
    end

    it "isn't behind once its bytes equal the bundle's, marked or not" do
      left_behind
      File.write(target, File.read(saved))

      expect(provenance.record.files["a.md"][:conflict]).to be true
      expect(behind_lines).to be_empty
    end

    it "isn't behind when the file is gone: that is a missing file" do
      left_behind
      FileUtils.rm_f(target)

      expect(behind_lines).to be_empty
    end

    it "counts a marked file it can't read as behind" do
      skip "root reads anything" if Process.uid.zero?
      left_behind
      File.chmod(0o000, target)
      begin
        expect(behind_lines.size).to eq(1)
      ensure
        File.chmod(0o644, target)
      end
    end

    it "reads an older mark, with no digest or words, as behind" do
      left_behind
      raw = JSON.parse(File.read(File.join(provenance.bundle_dir, "manifest.json")))
      raw["files"]["a.md"] = raw["files"]["a.md"].slice("checksum", "conflict")
      File.write(File.join(provenance.bundle_dir, "manifest.json"), JSON.pretty_generate(raw))

      expect(behind_lines).to eq(["a.md may be behind 2.0.0: #{described_class::UNSURE}"])
    end

    it "doesn't count an older mark as behind when the file is level with its source" do
      left_behind
      raw = JSON.parse(File.read(File.join(provenance.bundle_dir, "manifest.json")))
      raw["files"]["a.md"] = raw["files"]["a.md"].slice("checksum", "conflict")
      File.write(File.join(provenance.bundle_dir, "manifest.json"), JSON.pretty_generate(raw))
      expect(behind_lines.size).to eq(1)

      File.write(target, File.read(File.join(source, "a.md")))
      expect(behind_lines).to be_empty
    end

    it "is sure of an older mark a retry gave a reason" do
      left_behind
      raw = JSON.parse(File.read(File.join(provenance.bundle_dir, "manifest.json")))
      raw["files"]["a.md"] = raw["files"]["a.md"].slice("checksum", "conflict").merge("why" => "a reason")
      File.write(File.join(provenance.bundle_dir, "manifest.json"), JSON.pretty_generate(raw))

      expect(behind_lines).to eq(["a.md stays behind 2.0.0: a reason"])
    end

    it "names no sections for an older mark, whose base may be the user's text" do
      left_behind
      raw = JSON.parse(File.read(File.join(provenance.bundle_dir, "manifest.json")))
      raw["files"]["a.md"] = raw["files"]["a.md"].slice("checksum", "conflict")
      File.write(File.join(provenance.bundle_dir, "manifest.json"), JSON.pretty_generate(raw))
      FileUtils.rm_rf(File.dirname(saved))

      expect(remerge.behind.map(&:missed)).to eq([[]])
      expect(remerge.behind.first.why).to eq(described_class::LEGACY_CONFLICT)
      expect(entry).to include(incoming_sha: Digest::SHA256.hexdigest(File.read(File.join(source, "a.md"))), legacy_base: true)
      expect(File.exist?(saved)).to be true
    end

    it "records a reason that changes, once, and writes nothing while it stays" do
      left_behind
      manifest = File.join(provenance.bundle_dir, "manifest.json")
      expect(remerge).not_to be_work
      FileUtils.mkdir_p(File.join(tmpdir, "no-git"))
      with_env("PATH" => File.join(tmpdir, "no-git")) do
        expect(remerge.stamped).to eq(["a.md"])
        expect(entry[:why]).to eq("no merge possible (git not found)")
        expect(remerge).not_to be_work
      end
      before = File.mtime(manifest)
      expect(remerge.stamped).to eq(["a.md"])
      expect(entry).not_to have_key(:why)
      expect(File.mtime(manifest)).to be >= before
    end

    it "is swept by an uninstall and left out of a build" do
      left_behind
      File.write(target, File.read(saved))
      out = File.join(tmpdir, "built")
      Samagotchi::MemoryBundle::Builder.new(scope: "system", name: "mine", out: out, files: ["a.md"]).run
      expect(Dir.glob(File.join(out, "**", "*"), File::FNM_DOTMATCH).map { |f| File.basename(f) }).not_to include("incoming")

      Samagotchi::MemoryBundle::Uninstaller.new(name: "demo", force: true).run
      expect(File.exist?(provenance.bundle_dir)).to be false
    end
  end
end
