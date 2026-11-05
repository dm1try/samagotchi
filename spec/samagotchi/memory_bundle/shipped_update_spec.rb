# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "fileutils"
require "yaml"
require "digest"
require "samagotchi/memory_bundle/shipped_update"
require "samagotchi/memory_bundle/uninstaller"
require "samagotchi/plugin/loader"

RSpec.describe Samagotchi::MemoryBundle::ShippedUpdate do
  let(:tmp) { Dir.mktmpdir("shipped-update") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
  let(:shipped) { Samagotchi::MemoryBundle::SourceNormalizer::SHIPPED_DIR }

  around { |example| with_config_home(File.join(tmp, "config")) { example.run } }

  after do
    FileUtils.remove_entry(tmp)
  end

  # A copy of a shipped bundle as an older gem shipped it: under
  # <root>/lib/samagotchi/bundles/<dir>, at +version+, each .md replaced
  # by +md+ (so the shipped one differs).
  def old_copy(dir, version: "0.0.1", md: nil, root: File.join(tmp, "gems", "samagotchi-0.0.1"), manifest: {})
    dest = File.join(root, "lib", "samagotchi", "bundles", dir)
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp_r(File.join(shipped, dir), dest)
    data = YAML.load_file(File.join(dest, "manifest.yml"))
    data["version"] = version
    if md
      (data["files"] || {}).each_key do |key|
        File.write(File.join(dest, key), md)
        data["files"][key] = "sha256:#{Digest::SHA256.hexdigest(md)}"
      end
    end
    File.write(File.join(dest, "manifest.yml"), YAML.dump(data.merge(manifest)))
    dest
  end

  def install(source, name, force: false)
    # An old copy is installed as the older chi that shipped it did, from
    # its own shipped dir.
    Samagotchi::MemoryBundle::Installer.new(source: source, name: name, scope: "system", strict: true, force: force,
                                            shipped_dir: File.dirname(source)).run
  end

  def version_of(name) = Samagotchi::MemoryBundle::Provenance.new(name: name).read[:version]
  def shipped_version(dir) = YAML.load_file(File.join(shipped, dir, "manifest.yml"))["version"]

  def plugin_loads?(name)
    record = Samagotchi::MemoryBundle::Provenance.new(name: name).record
    Samagotchi::Plugin::Loader.unloadable_reason(Samagotchi::MemoryBundle::Provenance.new(name: name).plugin_path(record), record).nil?
  end

  def mtimes
    Dir.glob(File.join(system_dir, "**", "*"), File::FNM_DOTMATCH).select { |f| File.file?(f) }.to_h { |f| [f, File.mtime(f)] }
  end

  it "updates an older bundle installed from chi; the plugin loads, and a second pass changes nothing" do
    install(old_copy("btw"), "btw")

    rows = described_class.plan
    expect(rows.map { |r| [r.name, r.from, r.to, r.status] }).to eq([["btw", "0.0.1", shipped_version("btw"), :would_update]])

    applied = described_class.apply(rows)
    expect(applied.first).to have_attributes(status: :updated, kept: [])
    expect(version_of("btw")).to eq(shipped_version("btw"))
    expect(Samagotchi::MemoryBundle::Provenance.new(name: "btw").read[:source]).to eq(File.join(shipped, "btw"))
    expect(plugin_loads?("btw")).to be(true)

    before = mtimes
    again = described_class.apply(described_class.plan)
    expect(again.map { |r| [r.name, r.status] }).to eq([["btw", :up_to_date]])
    expect(mtimes).to eq(before)
  end

  it "keeps an edited .md that conflicts, and the hook still loads (its sha is recorded)" do
    install(old_copy("known-names", md: "old words\n"), "known-names")
    File.write(File.join(system_dir, "known_names.md"), "old words\nmy note\n")

    rows = described_class.plan
    expect(rows.first).to have_attributes(status: :would_update, kept: ["known_names.md"])

    row = described_class.apply(rows).first
    expect(row).to have_attributes(status: :updated, kept: ["known_names.md"])
    expect(File.read(File.join(system_dir, "known_names.md"))).to eq("old words\nmy note\n")
    data = Samagotchi::MemoryBundle::Provenance.new(name: "known-names").read
    expect(data[:version]).to eq(shipped_version("known-names"))
    hook = File.join(Samagotchi::MemoryBundle::Provenance.new(name: "known-names").hooks_dir, "known_names.rb")
    expect("sha256:#{Digest::SHA256.hexdigest(File.read(hook))}").to eq(data[:hooks][:"known_names.rb"][:sha256])
    expect(described_class.plan.first.status).to eq(:up_to_date)
  end

  describe "an edit that merges clean" do
    let(:root) { File.join(tmp, "gem", "lib", "samagotchi", "bundles") }
    let(:dir) { File.join(root, "merged") }
    let(:live) { File.join(system_dir, "note.md") }

    def note(intro: "the intro", tail: "the tail")
      "# Note\n\n#{intro}\n\none\ntwo\nthree\nfour\nfive\n\n#{tail}\n"
    end

    def ship_note(version, text)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "note.md"), text)
      File.write(File.join(dir, "manifest.yml"),
                 YAML.dump({ "name" => "merged", "version" => version, "scope" => "system",
                             "files" => { "note.md" => "sha256:#{Digest::SHA256.hexdigest(text)}" } }))
    end

    before do
      ship_note("1.0.0", note)
      install(dir, "merged")
      File.write(live, note(intro: "my intro"))
      ship_note("2.0.0", note(tail: "tail two"))
    end

    it "plans it as merged, not kept, writing nothing, then merges and names the trash copy" do
      rows = described_class.plan(shipped_dir: root)
      expect(rows.first).to have_attributes(status: :would_update, merged: ["note.md"], kept: [])
      expect(File.read(live)).to eq(note(intro: "my intro"))

      row = described_class.apply(rows).first
      expect(row).to have_attributes(status: :updated, merged: ["note.md"], kept: [])
      expect(row.trash_copy).to include("Copied to the trash first: note.md")
      expect(File.read(live)).to eq(note(intro: "my intro", tail: "tail two"))
      expect(File.read(Samagotchi::MemoryBundle::Provenance.new(name: "merged").base_path("note.md"))).to eq(note(tail: "tail two"))
    end
  end

  describe "a file marked conflict at the same version" do
    let(:root) { File.join(tmp, "gem", "lib", "samagotchi", "bundles") }
    let(:dir) { File.join(root, "merged") }
    let(:live) { File.join(system_dir, "note.md") }
    let(:record) { File.join(Samagotchi::MemoryBundle::Provenance.new(name: "merged").bundle_dir, "manifest.json") }

    def note(intro: "the intro", tail: "the tail")
      "# Note\n\n#{intro}\n\none\ntwo\nthree\nfour\nfive\n\n#{tail}\n"
    end

    def ship_note(version, text, scope: "system")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "note.md"), text)
      File.write(File.join(dir, "manifest.yml"),
                 YAML.dump({ "name" => "merged", "version" => version, "scope" => scope,
                             "files" => { "note.md" => "sha256:#{Digest::SHA256.hexdigest(text)}" } }))
    end

    def mark(version:)
      raw = JSON.parse(File.read(record))
      raw["version"] = version
      raw["files"]["note.md"]["conflict"] = true
      File.write(record, JSON.pretty_generate(raw))
    end

    before do
      ship_note("1.0.0", note)
      install(dir, "merged")
      ship_note("2.0.0", note(tail: "the tail\nand a new line"))
      mark(version: "2.0.0")
    end

    it "plans would_merge, writing nothing, merges on apply, and is up to date after" do
      File.write(live, note(intro: "my intro"))

      rows = described_class.plan(shipped_dir: root)
      expect(rows.first).to have_attributes(status: :would_merge, from: "2.0.0", to: nil, merged: ["note.md"], kept: [])
      expect(File.read(live)).to eq(note(intro: "my intro"))

      row = described_class.apply(rows).first
      expect(row).to have_attributes(status: :merged, from: "2.0.0", to: nil, merged: ["note.md"])
      expect(row.trash_copy).to include("Copied to the trash first: note.md")
      expect(File.read(live)).to eq(note(intro: "my intro", tail: "the tail\nand a new line"))

      expect(described_class.plan(shipped_dir: root).first).to have_attributes(status: :up_to_date, merged: [])
    end

    it "stays quiet on a real conflict, the first run only recording its digest" do
      File.write(live, note(tail: "my tail\nand another line"))

      first = described_class.apply(described_class.plan(shipped_dir: root)).first
      expect(first).to have_attributes(status: :up_to_date, merged: [], note: nil)
      expect(File.read(live)).to eq(note(tail: "my tail\nand another line"))
      expect(JSON.parse(File.read(record))["files"]["note.md"]).to include("conflict" => true, "incoming_sha" => Digest::SHA256.hexdigest(note(tail: "the tail\nand a new line")))

      stamp = File.mtime(record)
      expect(described_class.apply(described_class.plan(shipped_dir: root)).first.status).to eq(:up_to_date)
      expect(File.mtime(record)).to eq(stamp)
    end

    it "says when the bundle has no such file now, keeping it" do
      File.write(live, note(intro: "my intro"))
      FileUtils.rm_f(File.join(dir, "note.md"))

      expect(described_class.plan(shipped_dir: root).first)
        .to have_attributes(status: :up_to_date, note: nil,
                            behind: [Samagotchi::MemoryBundle::FileStanding::Behind.new(file: "note.md", version: "2.0.0", why: "not in the bundle now, nothing to merge")])
    end

    it "leaves a project-scope bundle to chi bundle upgrade in the project" do
      project = Samagotchi::MemoryPaths.scope_dir("project")
      FileUtils.mkdir_p(project)
      File.write(File.join(project, "note.md"), note(intro: "my intro"))
      raw = JSON.parse(File.read(record))
      raw["scope"] = "project"
      File.write(record, JSON.pretty_generate(raw))

      rows = described_class.apply(described_class.plan(shipped_dir: root))
      expect(rows.first).to have_attributes(status: :up_to_date, merged: [])
      expect(File.read(File.join(project, "note.md"))).to eq(note(intro: "my intro"))
    end

    it "doesn't crash the plan on a marked file it can't read, and says so" do
      skip "root reads anything" if Process.uid.zero?
      File.write(live, note(intro: "my intro"))
      File.chmod(0o000, live)
      begin
        row = described_class.plan(shipped_dir: root).first
        expect(row.status).to eq(:up_to_date)
        expect(row.behind.first.line).to start_with("note.md stays behind 2.0.0: left as it is (").and include("Permission denied")
      ensure
        File.chmod(0o644, live)
      end
    end
  end

  it "fails only that row, in the plan and through apply, on an edited file it can't read at a newer version" do
    skip "root reads anything" if Process.uid.zero?
    install(old_copy("known-names", md: "old words\n"), "known-names")
    install(old_copy("btw", md: "old words\n"), "btw")
    live = File.join(system_dir, "known_names.md")
    File.write(live, "mine\n")
    File.chmod(0o000, live)
    begin
      rows = described_class.plan
      row = rows.find { |candidate| candidate.name == "known-names" }
      expect(row.status).to eq(:failed)
      expect(row.note).to include("Permission denied", "nothing was lost")
      applied = described_class.apply(rows)
      expect(applied.find { |candidate| candidate.name == "known-names" }.status).to eq(:failed)
      expect(applied.find { |candidate| candidate.name == "btw" }.status).to eq(:updated)
    ensure
      File.chmod(0o644, live)
    end
  end

  it "says on a failed row what that run did, not what the plan expected, and notes a merge it made" do
    install(old_copy("known-names", md: "# T\n\nold words\n\nmore\n"), "known-names")
    File.write(File.join(system_dir, "known_names.md"), "# T\n\nmy words\n\nmore\n")
    rows = described_class.plan
    allow_any_instance_of(Samagotchi::MemoryBundle::Provenance).to receive(:write).and_raise("the disk is full")
    allow_any_instance_of(Samagotchi::MemoryBundle::Installer).to receive(:merged_files).and_return(["known_names.md"])
    allow_any_instance_of(Samagotchi::MemoryBundle::Provenance).to receive(:note_merged)
    rows.first.behind = [Samagotchi::MemoryBundle::FileStanding::Behind.new(file: "planned.md")]

    row = described_class.apply(rows).first
    expect(row).to have_attributes(status: :failed, note: "the disk is full", merged: ["known_names.md"], kept: ["known_names.md"])
  end

  it "keeps a skipped row's files that stay behind in the plan, and any merge note" do
    source = old_copy("known-names", md: "old words\n")
    install(source, "known-names")
    File.write(File.join(system_dir, "known_names.md"), "mine\n")
    provenance = Samagotchi::MemoryBundle::Provenance.new(name: "known-names")
    manifest = File.join(provenance.bundle_dir, "manifest.json")
    raw = JSON.parse(File.read(manifest))
    raw["source"] = "/not/chi/known-names"
    raw["files"]["known_names.md"].merge!("conflict" => true, "incoming_sha" => "other", "merged_version" => "1", "merged_at" => "2026-11-05T10:00:00Z")
    File.write(manifest, JSON.generate(raw))

    row = described_class.plan.first
    expect(row).to have_attributes(status: :skipped, kept: ["known_names.md"])
    expect(row.earlier.map(&:file)).to eq(["known_names.md"])
  end

  # The plan asks about every shipped *.md, the Installer about
  # MemoryFiles.select, so the two can disagree. Pinned, not endorsed: a plan
  # that unifies them changes what these say (Merger::Upgrade#forecast).
  describe "a plan that names a file the upgrade doesn't merge" do
    let(:root) { File.join(tmp, "gem", "lib", "samagotchi", "bundles") }
    let(:dir) { File.join(root, "listed") }

    def ship_listed(version, listed)
      FileUtils.mkdir_p(dir)
      listed.each { |name, text| File.write(File.join(dir, name), text) }
      File.write(File.join(dir, "manifest.yml"),
                 YAML.dump({ "name" => "listed", "version" => version, "scope" => "system",
                             "files" => listed.transform_values { |text| "sha256:#{Digest::SHA256.hexdigest(text)}" } }))
    end

    before do
      ship_listed("1.0.0", "a.md" => "a1\n", "b.md" => "b1\n")
      Samagotchi::MemoryBundle::Installer.new(source: dir, name: "listed", scope: "system", strict: true, shipped_dir: root).run
      File.write(File.join(system_dir, "b.md"), "edited\n")
    end

    def plan_then_apply
      rows = described_class.plan(shipped_dir: root)
      [rows.first.kept, described_class.apply(rows).first.kept]
    end

    it "one dropped from files: but still shipped" do
      ship_listed("2.0.0", "a.md" => "a2\n")
      File.write(File.join(dir, "b.md"), "b2\n")

      expect(plan_then_apply).to eq([%w[b.md], []])
    end

    it "one that is now a symlink" do
      ship_listed("2.0.0", "a.md" => "a2\n")
      File.write(File.join(dir, "elsewhere"), "b2\n")
      FileUtils.rm_f(File.join(dir, "b.md"))
      File.symlink("elsewhere", File.join(dir, "b.md"))

      expect(plan_then_apply).to eq([%w[b.md], []])
    end
  end

  it "doesn't plan a user's own same-name memory as kept: the bundle never installed it" do
    FileUtils.mkdir_p(system_dir)
    File.write(File.join(system_dir, "known_names.md"), "my own\n")
    install(old_copy("known-names", md: "old words\n"), "known-names")

    rows = described_class.plan
    expect(rows.first).to have_attributes(status: :would_update, kept: [])
    described_class.apply(rows)
    expect(File.read(File.join(system_dir, "known_names.md"))).to eq("my own\n")
  end

  it "reports an edited hook it replaces" do
    install(old_copy("known-names"), "known-names")
    File.write(File.join(Samagotchi::MemoryBundle::Provenance.new(name: "known-names").hooks_dir, "known_names.rb"), "# mine\n")

    row = described_class.apply(described_class.plan).first
    expect(row).to have_attributes(status: :updated, replaced: ["hooks/known_names.rb"])
    expect(row.trash_copy).to match(%r{\ACopied to the trash first: hooks/known_names\.rb \(.*/\.trash/known-names-\d{8}-\d{6}\)\z})
    expect(File.read(File.join(row.trash_copy[/\((.*)\)/, 1], "hooks", "known_names.rb"))).to eq("# mine\n")
    expect(File.read(File.join(shipped, "known-names", "hooks", "known_names.rb")))
      .to eq(File.read(File.join(Samagotchi::MemoryBundle::Provenance.new(name: "known-names").hooks_dir, "known_names.rb")))
  end

  it "reports an edited plugin as replaced" do
    install(old_copy("btw"), "btw")
    File.write(Samagotchi::MemoryBundle::Provenance.new(name: "btw").plugin_path, "# mine\n")
    expect(described_class.plan.first.replaced).to eq(["plugin/plugin.rb"])
  end

  it "skips a same-named bundle that wasn't installed from chi" do
    zipped = File.join(tmp, "unpacked-btw")
    FileUtils.cp_r(old_copy("btw"), zipped)
    install(zipped, "btw", force: true) # a shipped name from elsewhere takes --force
    expect(described_class.plan.first).to have_attributes(status: :skipped, note: "not from chi", to: nil)
  end

  it "skips a user bundle chi doesn't ship" do
    install(old_copy("btw", manifest: { "name" => "mine" }), "mine")
    expect(described_class.plan.first).to have_attributes(name: "mine", status: :skipped, note: "not from chi")
  end

  it "leaves an installed version newer than the shipped one" do
    install(old_copy("btw", version: "99.0.0"), "btw")
    expect(described_class.plan.first).to have_attributes(status: :skipped, note: "newer than shipped: left")
  end

  it "skips a shipped bundle this chi can't load" do
    install(old_copy("btw"), "btw")
    newer = File.join(tmp, "new")
    root = File.join(newer, "lib", "samagotchi", "bundles")
    FileUtils.mkdir_p(root)
    FileUtils.cp_r(File.join(shipped, "btw"), root)
    data = YAML.load_file(File.join(root, "btw", "manifest.yml")).merge("version" => "0.9.0", "requires_chi" => ">= 99.0")
    File.write(File.join(root, "btw", "manifest.yml"), YAML.dump(data))

    row = described_class.plan(shipped_dir: root).first
    expect(row).to have_attributes(status: :skipped, note: "needs chi >= 99.0", to: "0.9.0")
    expect(described_class.apply([row]).first.status).to eq(:skipped)
    expect(version_of("btw")).to eq("0.0.1")
  end

  it "skips a bundle whose provenance names a scope this chi doesn't know" do
    install(old_copy("btw"), "btw")
    mjson = File.join(system_dir, ".bundles", "btw", "manifest.json")
    File.write(mjson, JSON.generate(JSON.parse(File.read(mjson)).merge("scope" => "team")))

    row = described_class.plan.first
    expect(row).to have_attributes(status: :skipped, note: "unknown scope team: upgrade chi or reinstall", to: nil)
    expect(described_class.apply([row]).first.status).to eq(:skipped)
    expect(version_of("btw")).to eq("0.0.1")
  end

  it "skips a bundle whose provenance manifest.json doesn't parse" do
    dir = File.join(system_dir, ".bundles", "broken")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "manifest.json"), "{bad")
    FileUtils.mkdir_p(File.join(system_dir, ".bundles", "list"))
    File.write(File.join(system_dir, ".bundles", "list", "manifest.json"), "[]")
    FileUtils.mkdir_p(File.join(system_dir, ".bundles", "no-manifest"))
    expect(described_class.plan.map { |r| [r.name, r.status, r.note] })
      .to eq([["broken", :skipped, "manifest.json unreadable"], ["list", :skipped, "manifest.json unreadable"]])
  end

  it "leaves the system bundle to SystemBundle and lists shipped bundles that aren't installed, grouped under their profile" do
    install(old_copy("system"), "samagotchi-system")
    install(old_copy("btw"), "btw")
    expect(described_class.plan.map(&:name)).to eq(["btw"])
    expect(described_class.not_installed.map(&:name)).not_to include("btw", "samagotchi-system")
    expect(described_class.not_installed.map(&:name)).to eq(%w[core dev])
    expect(described_class.not_installed.find { |s| s.name == "dev" }.includes).to eq(%w[known-names mcp skills source-links github-pr coordinator claude-peer codex-peer ruby model-notes decision-card])
  end

  it "fails one row without stopping the rest" do
    install(old_copy("btw"), "btw")
    install(old_copy("known-names"), "known-names")
    rows = described_class.plan
    rows.first.source_dir = File.join(tmp, "gone")

    applied = described_class.apply(rows)
    expect(applied.map(&:status)).to eq(%i[failed updated])
    expect(applied.first.note).to include("does not exist")
  end

  describe "a profile (meta bundle)" do
    let(:root) { File.join(tmp, "new", "lib", "samagotchi", "bundles") }

    # A shipped dir with copies of some real bundles and a core at +version+.
    def ship_core(version, includes, members: %w[loop-guard check-in guardrails btw])
      FileUtils.mkdir_p(root)
      members.each { |m| FileUtils.cp_r(File.join(shipped, m), root) unless File.exist?(File.join(root, m)) }
      FileUtils.mkdir_p(File.join(root, "core"))
      File.write(File.join(root, "core", "manifest.yml"),
                 YAML.dump("name" => "core", "version" => version, "scope" => "system", "includes" => includes))
      File.join(root, "core")
    end

    def core_row = described_class.plan(shipped_dir: root).find { |r| r.name == "core" }
    def installed = Samagotchi::MemoryBundle::Provenance.each_installed.map { |name, _| name }

    it "installs only a bundle new to the profile, never one the user uninstalled" do
      core = ship_core("0.1.0", %w[loop-guard check-in guardrails])
      Samagotchi::MemoryBundle::Profile.install(core, shipped_dir: root)
      Samagotchi::MemoryBundle::Uninstaller.new(name: "check-in").run
      expect(core_row).to have_attributes(status: :up_to_date, to: nil)

      ship_core("0.2.0", %w[loop-guard check-in guardrails btw])
      expect(core_row).to have_attributes(from: "0.1.0", to: "0.2.0", status: :would_update, adds: %w[btw])

      applied = described_class.apply(described_class.plan(shipped_dir: root))
      expect(applied.find { |r| r.name == "core" }).to have_attributes(status: :updated, adds: %w[btw])
      expect(installed).to eq(%w[btw core guardrails loop-guard])
      expect(version_of("core")).to eq("0.2.0")
      expect(core_row.status).to eq(:up_to_date)
    end

    # chi update's path (UpdateCommand#bundle_row adds the lines to the row's note).
    it "names a new member's memory file the user already had, left as theirs" do
      core = ship_core("0.1.0", %w[loop-guard], members: %w[loop-guard guardrails])
      Samagotchi::MemoryBundle::Profile.install(core, shipped_dir: root)
      File.write(File.join(system_dir, "guardrails.md"), "mine\n")
      ship_core("0.2.0", %w[loop-guard guardrails], members: %w[loop-guard guardrails])

      row = described_class.apply([core_row]).first
      expect(row).to have_attributes(status: :updated, adds: %w[guardrails],
                                     kept_own: [Samagotchi::MemoryBundle::Profile.kept_own_line("guardrails", "guardrails.md")])
      expect(File.read(File.join(system_dir, "guardrails.md"))).to eq("mine\n")
    end

    it "retries a member that isn't recorded at the same version" do
      core = ship_core("0.1.0", %w[loop-guard guardrails])
      Samagotchi::MemoryBundle::Provenance.new(name: "core")
        .write(files: {}, scope: "system", version: "0.1.0", source_path: core, includes: %w[loop-guard])

      expect(core_row).to have_attributes(from: "0.1.0", to: nil, status: :would_update, adds: %w[guardrails])
      expect(described_class.apply([core_row]).first).to have_attributes(status: :updated, adds: %w[guardrails])
      expect(Samagotchi::MemoryBundle::Provenance.new(name: "core").read[:includes]).to eq(%w[loop-guard guardrails])
    end

    it "plans a member chi doesn't ship as one to install, and apply fails the row" do
      core = ship_core("0.1.0", %w[loop-guard])
      Samagotchi::MemoryBundle::Profile.install(core, shipped_dir: root)
      ship_core("0.1.0", %w[loop-guard gone])

      expect(core_row).to have_attributes(status: :would_update, adds: %w[gone])
      expect(described_class.apply([core_row]).first).to have_attributes(status: :failed, adds: [])
    end

    it "doesn't count a member this chi can't load, and fails the row when a member fails" do
      core = ship_core("0.1.0", %w[loop-guard btw])
      Samagotchi::MemoryBundle::Provenance.new(name: "core")
        .write(files: {}, scope: "system", version: "0.1.0", source_path: core, includes: [])
      btw = File.join(root, "btw", "manifest.yml")
      File.write(btw, YAML.dump(YAML.load_file(btw).merge("requires_chi" => ">= 99.0")))
      expect(described_class.plan(shipped_dir: root, chi_version: "1.0.0").first).to have_attributes(adds: %w[loop-guard])

      File.write(btw, YAML.dump(YAML.load_file(btw).merge("requires_chi" => nil, "plugin" => { "file" => "gone.rb" })))
      row = described_class.apply([core_row]).first
      expect(row).to have_attributes(status: :failed, adds: %w[loop-guard])
      expect(row.note).to include("btw", "gone.rb")
      expect(installed).to eq(%w[core loop-guard])
    end
  end
end
