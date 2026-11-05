# frozen_string_literal: true

require "spec_helper"
require_relative "support/worker_fixtures"
require_relative "support/fake_provider_server"
require "socket"
require "stringio"
require "tmpdir"
require "yaml"
require "digest"
require "samagotchi/memory_bundle/shas"
require "samagotchi/update_command"
require "samagotchi/web/running"
# Loaded here: the stub_const below would otherwise invent the constant, and the
# file's require, once used up, never brings the real one back for later examples.
require "samagotchi/bundle_command/installed_check"

RSpec.describe Samagotchi::UpdateCommand do
  include WorkerFixtures

  # Real localhost HTTP (the chi web probe): other suites may enable WebMock.
  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:tmp) { Dir.mktmpdir("update-command") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
  let(:state_dir) { File.join(tmp, "sessions").tap { |d| FileUtils.mkdir_p(d) } }
  let(:shipped) { Samagotchi::MemoryBundle::SourceNormalizer::SHIPPED_DIR }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:gem_spec) { Gem::Specification.new { |s| s.name = "samagotchi"; s.version = Samagotchi::VERSION } }
  let(:servers) { [] }
  # A port nothing listens on: never the user's real chi web.
  let(:closed_port) { TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } } }
  let(:web) { ["127.0.0.1", closed_port] }
  let(:helper) { nil }
  let(:supported) { false }
  # rubygems says this chi is the newest; never the network.
  let(:fetcher) { -> { JSON.generate(version: Samagotchi::VERSION) } }
  let(:gem_runner) { double("runner", run: ["Successfully installed samagotchi\n", true]) }
  let(:gem_update) { Samagotchi::GemUpdate.new(env: {}, fetcher: fetcher, runner: gem_runner, gem_bin: "/rb/bin/gem") }
  let(:execs) { [] }
  let(:bundler) { false }
  # No chi home unless a spec gives one; never a first record from the suite's Ruby.
  let(:chi_home) { double("ChiHome", current: nil, record_first!: nil) }

  around { |example| with_config_home(File.join(tmp, "config")) { example.run } }

  after do
    servers.each(&:close)
    FileUtils.remove_entry(tmp)
  end

  def run(*argv, gem_spec: self.gem_spec)
    out.truncate(0)
    out.rewind
    described_class.new(argv, stdout: out, stderr: err, gem_spec: gem_spec, platform: ->(register:) { helper },
                              supported: supported, state_dir: state_dir, web: web, gem_update: gem_update,
                              exec: ->(argv) { execs << argv }, bundler: bundler, home: chi_home).run
  end

  # btw as an older gem shipped it, installed from there.
  def install_old_btw(version: "0.0.1")
    dest = File.join(tmp, "gems", "samagotchi-0.0.1", "lib", "samagotchi", "bundles", "btw")
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp_r(File.join(shipped, "btw"), dest)
    data = YAML.load_file(File.join(dest, "manifest.yml")).merge("version" => version)
    File.write(File.join(dest, "manifest.yml"), YAML.dump(data))
    # The older chi installed it from its own shipped dir.
    Samagotchi::MemoryBundle::Installer.new(source: dest, name: "btw", scope: "system", strict: true,
                                            shipped_dir: File.dirname(dest)).run
  end

  def btw_version = Samagotchi::MemoryBundle::Provenance.new(name: "btw").read[:version]
  def line(component) = out.string.lines.find { |l| l.start_with?("#{component} ") }.to_s.rstrip

  it "refuses from a checkout, without touching anything" do
    expect(run(gem_spec: nil)).to eq(1)
    expect(err.string).to include("running from a checkout", "git pull, or chi bundle upgrade NAME")
    expect(Dir.exist?(system_dir)).to be(false)
  end

  it "refuses an unknown option with usage" do
    expect(run("--frob")).to eq(2)
    expect(err.string).to include("unknown option --frob", "Usage: chi update")
  end

  it "refuses a target that isn't newer than the running chi" do
    expect(gem_runner).not_to receive(:run)
    expect(run("--to", Samagotchi::VERSION)).to eq(1)
    expect(err.string).to include("chi update: #{Samagotchi::VERSION} is not newer than the running chi")
  end

  it "installs exactly the requested gem version" do
    target = Gem::Version.new(Samagotchi::VERSION).bump.to_s + ".1"
    expect(gem_runner).to receive(:run).with(["/rb/bin/gem", "install", "samagotchi", "--no-document", "-v", target])
                                       .and_return(["Successfully installed\n", true])
    expect(run("--to", target, "--no-bundles", "--no-desktop")).to eq(0)
    expect(execs.last).to include("update", "--no-gem", "--gem-from", Samagotchi::VERSION)
  end

  it "fails a --to whose gem install is off: an exact version that wasn't installed is no success" do
    target = Gem::Version.new(Samagotchi::VERSION).bump.to_s + ".1"
    expect(gem_runner).not_to receive(:run)
    expect(run("--to", target, "--json", "--no-gem", "--no-bundles", "--no-desktop")).to eq(1)
    expect(JSON.parse(out.string).first).to include("component" => "chi (gem)", "failed" => true,
                                                    "status" => "failed (skipped: --no-gem)")
  end

  it "prints JSON rows with kept files and sends progress to stderr" do
    expect(run("--json", "--no-gem", "--no-bundles", "--no-desktop")).to eq(0)

    rows = JSON.parse(out.string)
    expect(rows).to be_an(Array)
    expect(rows).to all(include("component", "from", "to", "status", "failed", "kept"))
    expect(rows.map { |row| row["component"] }).to include("chi (gem)", "system bundle")
    expect(rows.find { |row| row["component"] == "system bundle" }["kept"]).to eq([])
    expect(out.string.lines.length).to eq(1)
    expect(err.string).to be_empty
  end

  it "dry-runs, updates, then says everything is up to date" do
    Samagotchi::MemoryBundle::SystemBundle.sync
    install_old_btw

    expect(run("--dry-run")).to eq(0)
    expect(out.string.lines.first).to match(/\Acomponent\s+from\s+to\s+status/)
    expect(line("btw")).to match(/\Abtw\s+0\.0\.1\s+#{Regexp.escape(YAML.load_file(File.join(shipped, "btw", "manifest.yml"))["version"])}\s+would update\z/)
    expect(line("system bundle")).to match(/up to date\z/)
    expect(out.string).to include("Also shipped, not installed: core (loop-guard, check-in, guardrails, slow-commands, agents-md, cost-cap, work-cap), dev (known-names, mcp, skills, source-links, github-pr, coordinator, claude-peer, codex-peer, ruby, model-notes, decision-card)",
                                  "(dry run: nothing was changed)")
    expect(btw_version).to eq("0.0.1")

    expect(run).to eq(0)
    expect(line("btw")).to match(/\s+updated\z/)
    expect(out.string).to end_with("done\n")
    expect(btw_version).not_to eq("0.0.1")

    expect(run).to eq(0)
    expect(line("btw")).to match(/\Abtw\s+\S+\s+up to date\z/)
    expect(out.string).to end_with("everything is up to date\n")
  end

  it "installs a bundle new to an installed profile and says so on its row" do
    root = File.join(tmp, "new", "lib", "samagotchi", "bundles")
    FileUtils.mkdir_p(root)
    %w[loop-guard btw guardrails].each { |m| FileUtils.cp_r(File.join(shipped, m), root) }
    core = File.join(root, "core")
    FileUtils.mkdir_p(core)
    write_core = lambda do |version, includes|
      File.write(File.join(core, "manifest.yml"), YAML.dump("name" => "core", "version" => version, "includes" => includes))
    end
    write_core.call("0.1.0", %w[loop-guard])
    Samagotchi::MemoryBundle::Profile.install(core, shipped_dir: root)
    write_core.call("0.2.0", %w[loop-guard btw guardrails])
    # A memory file of a new member the user already has: kept, and said so.
    FileUtils.mkdir_p(Samagotchi::MemoryPaths.system_dir)
    File.write(File.join(Samagotchi::MemoryPaths.system_dir, "guardrails.md"), "mine\n")

    command = lambda do |*argv|
      out.truncate(0)
      out.rewind
      described_class.new(argv, stdout: out, stderr: err, gem_spec: gem_spec, platform: ->(register:) { helper },
                                supported: supported, state_dir: state_dir, web: web, gem_update: gem_update,
                                exec: ->(a) { execs << a }, bundler: bundler, shipped_dir: root).run
    end
    expect(command.call("--dry-run", "--no-gem")).to eq(0)
    expect(line("core")).to match(/\Acore\s+0\.1\.0\s+0\.2\.0\s+would update \(\+ btw, guardrails\)\z/)
    expect(command.call("--no-gem")).to eq(0)
    kept = Samagotchi::MemoryBundle::Profile.kept_own_line("guardrails", "guardrails.md")
    expect(line("core")).to match(/\s+updated \(\+ btw, guardrails; #{Regexp.escape(kept)}\)\z/)
    expect(Samagotchi::MemoryBundle::Provenance.new(name: "btw").read[:source]).to eq(File.join(root, "btw"))
  end

  it "installs a missing system bundle" do
    expect(run).to eq(0)
    expect(line("system bundle")).to match(/\s+#{Regexp.escape(Samagotchi::VERSION)}\s+installed\z/)
  end

  it "keeps the edited files on the row as well as in its status" do
    source = File.join(tmp, "gems", "samagotchi-0.0.1", "lib", "samagotchi", "bundles", "known-names")
    FileUtils.mkdir_p(File.dirname(source))
    FileUtils.cp_r(File.join(shipped, "known-names"), source)
    manifest_path = File.join(source, "manifest.yml")
    manifest = YAML.load_file(manifest_path)
    manifest["version"] = "0.0.1"
    manifest["files"].each_key do |file|
      content = "old words\n"
      File.write(File.join(source, file), content)
      manifest["files"][file] = "sha256:#{Digest::SHA256.hexdigest(content)}"
    end
    File.write(manifest_path, YAML.dump(manifest))
    Samagotchi::MemoryBundle::Installer.new(source: source, name: "known-names", scope: "system", strict: true,
                                            shipped_dir: File.dirname(source)).run
    edited = File.join(system_dir, "known_names.md")
    File.write(edited, "old words\nmy note\n")

    command = described_class.new(["--no-gem"], stdout: out, stderr: err, gem_spec: gem_spec,
                                  platform: ->(register:) { helper }, supported: supported, state_dir: state_dir,
                                  web: web, gem_update: gem_update, exec: ->(argv) { execs << argv }, bundler: bundler)
    rows = nil
    printer = command.method(:print_table)
    allow(command).to receive(:print_table) { |printed| rows = printed; printer.call(printed) }

    expect(command.run).to eq(0)
    row = rows.find { |candidate| candidate.component == "known-names" }
    expect(row.kept).to eq(["known_names.md"])
    expect(row.status).to include("known_names.md stays behind").and include("chi bundle diff known-names known_names.md")
  end

  it "names merged files in the system bundle's row" do
    result = Samagotchi::MemoryBundle::SystemBundle::Result.new(
      from: "1", to: "2", status: :updated, merged: ["identity.md"], behind: [], warnings: [],
      trash_copy: "Copied to the trash first: identity.md (/t)"
    )
    allow(Samagotchi::MemoryBundle::SystemBundle).to receive(:sync).and_return(result)
    row = described_class.new(["--no-gem"], stdout: out, stderr: err).send(:system_bundle_row)

    expect(row).to have_attributes(status: "updated (merged 2 into your identity.md; old copies: chi bundle trash)", merged: ["identity.md"],
                                   trash_copy: "Copied to the trash first: identity.md (/t)")
  end

  it "reads as merged for a file merged at the same version, with no to" do
    update = Samagotchi::MemoryBundle::ShippedUpdate::Row.new(
      name: "coordinator", from: "0.8.0", status: :merged, merged: ["skill.md"], behind: [], replaced: [],
      trash_copy: "Copied to the trash first: skill.md (/t)"
    )
    row = described_class.new(["--no-gem"], stdout: out, stderr: err).send(:bundle_row, update)
    expect(row).to have_attributes(from: "0.8.0", to: nil, status: "merged 0.8.0 into your skill.md; old copies: chi bundle trash")

    result = Samagotchi::MemoryBundle::SystemBundle::Result.new(from: "0.8.0", to: "0.8.0", status: :merged, merged: ["identity.md"], behind: [], warnings: [])
    allow(Samagotchi::MemoryBundle::SystemBundle).to receive(:sync).and_return(result)
    command = described_class.new(["--no-gem"], stdout: out, stderr: err)
    expect(command.send(:system_bundle_row)).to have_attributes(from: "0.8.0", to: nil, status: "merged 0.8.0 into your identity.md")
    command.instance_variable_set(:@dry_run, true)
    expect(command.send(:system_bundle_row).status).to eq("would merge 0.8.0 into your identity.md")
  end

  it "reads 'up to date' only when nothing stays behind, a warning in its note" do
    update = Samagotchi::MemoryBundle::ShippedUpdate::Row.new(name: "x", from: "1", status: :would_merge, merged: [], behind: [], replaced: [])
    command = described_class.new(["--no-gem"], stdout: out, stderr: err)
    expect(command.send(:bundle_row, update).status).to eq("up to date")

    update = Samagotchi::MemoryBundle::ShippedUpdate::Row.new(name: "x", from: "1", status: :up_to_date, note: "index.md: not updated")
    expect(command.send(:bundle_row, update).status).to eq("up to date (index.md: not updated)")

    update = Samagotchi::MemoryBundle::ShippedUpdate::Row.new(name: "x", from: "1", status: :up_to_date, behind: [Samagotchi::MemoryBundle::FileStanding::Behind.new(file: "a.md", version: "1", missed: ["## Steps"])])
    expect(command.send(:bundle_row, update)).to have_attributes(status: "a.md stays behind 1: missed ## Steps (chi bundle diff x a.md)", kept: ["a.md"], to: nil)
  end

  it "shows an earlier merge in the row and clears it, this run's own merged list apart" do
    note = Samagotchi::MemoryBundle::FileStanding::MergeNote.new(file: "identity.md", version: "1", at: "2026-11-05T10:00:00Z", trash: "/long/trash")
    stamp = Samagotchi::MemoryBundle::FileStanding.local_time(note.at)
    allow(Samagotchi::MemoryBundle::SystemBundle).to receive(:merge_notes).and_return([note])
    cleared = []
    allow(Samagotchi::MemoryBundle::SystemBundle).to receive(:clear_merge_notes) { |notes, **| cleared << notes }
    result = Samagotchi::MemoryBundle::SystemBundle::Result.new(from: "1", to: "1", status: :up_to_date, merged: [], behind: [], warnings: [])
    allow(Samagotchi::MemoryBundle::SystemBundle).to receive(:sync).and_return(result)
    command = described_class.new(["--no-gem"], stdout: out, stderr: err)

    expect(command.send(:system_bundle_row)).to have_attributes(status: "up to date (merged 1 into your identity.md on #{stamp}; old copies: chi bundle trash)",
                                                                merged: [], earlier: ["identity.md"], to: nil)
    expect(cleared).to eq([[note]])
    expect(Samagotchi::MemoryBundle::SystemBundle).to have_received(:clear_merge_notes).with([note], files: [])
  end

  context "with an earlier merge's note" do
    let(:note) { Samagotchi::MemoryBundle::FileStanding::MergeNote.new(file: "identity.md", version: "1", at: "2026-11-05T10:00:00Z", trash: nil) }
    let(:system) { Samagotchi::MemoryBundle::SystemBundle }

    before do
      allow(system).to receive(:merge_notes).and_return([note])
      allow(system).to receive(:clear_merge_notes)
    end

    def row_for(status, env: {}, dry_run: false, error: nil)
      allow(system).to receive(:sync).and_return(system::Result.new(from: "1", to: "1", status: status, merged: [], behind: [], warnings: [], error: error))
      command = described_class.new(["--no-gem"], stdout: out, stderr: err, env: env)
      command.instance_variable_set(:@dry_run, dry_run)
      command.send(:system_bundle_row)
    end

    it "keeps it when the row has no place for it: skipped, failed" do
      expect(row_for(:skipped, error: "off").status).not_to include("merged")
      expect(row_for(:failed, error: "boom").status).not_to include("merged")
      expect(system).to have_received(:clear_merge_notes).with([], files: []).twice
    end

    it "shows it and keeps it in a dry run" do
      expect(row_for(:up_to_date, dry_run: true).status).to include("merged 1 into your identity.md")
      expect(system).not_to have_received(:clear_merge_notes)
    end

    it "takes only the marker's own value as unattended" do
      row_for(:up_to_date, env: { Samagotchi::ChildEnv::UNATTENDED_UPDATE => "0" })
      expect(system).to have_received(:clear_merge_notes).with([note], files: [])
    end

    it "shows it and keeps it in an automatic run, which no one may read" do
      expect(row_for(:up_to_date, env: { Samagotchi::ChildEnv::UNATTENDED_UPDATE => "1" }).status).to include("merged 1 into your identity.md")
      expect(system).not_to have_received(:clear_merge_notes)
    end

    it "clears it through a row that names it, newer installed and restored too" do
      expect(row_for(:newer_installed).status).to include("merged 1 into your identity.md")
      expect(row_for(:restored).status).to include("merged 1 into your identity.md")
      expect(system).to have_received(:clear_merge_notes).with([note], files: []).twice
    end
  end

  it "keeps a shipped bundle's note on a failed row, and names what that run did merge" do
    note = Samagotchi::MemoryBundle::FileStanding::MergeNote.new(file: "a.md", version: "1", at: nil, trash: nil)
    update = Samagotchi::MemoryBundle::ShippedUpdate::Row.new(name: "x", from: "1", to: "2", status: :failed, note: "boom", merged: ["b.md"], behind: [], replaced: [], earlier: [note])
    expect_any_instance_of(Samagotchi::MemoryBundle::Provenance).not_to receive(:clear_merge_notes)

    row = described_class.new(["--no-gem"], stdout: out, stderr: err).send(:bundle_row, update)
    expect(row).to have_attributes(status: "failed (boom; merged 2 into your b.md)", merged: ["b.md"], earlier: [])
  end

  it "names a note on a skip row, and clears it" do
    note = Samagotchi::MemoryBundle::FileStanding::MergeNote.new(file: "a.md", version: "1", at: nil, trash: nil)
    behind = Samagotchi::MemoryBundle::FileStanding::Behind.new(file: "b.md", version: "1")
    update = Samagotchi::MemoryBundle::ShippedUpdate::Row.new(name: "x", from: "1", status: :skipped, note: "not from chi", merged: [], behind: [behind], replaced: [], earlier: [note])
    expect_any_instance_of(Samagotchi::MemoryBundle::Provenance).to receive(:clear_merge_notes).with([note], files: [])

    row = described_class.new(["--no-gem"], stdout: out, stderr: err).send(:bundle_row, update)
    expect(row.status).to eq("skipped (not from chi; b.md stays behind 1 (chi bundle diff x b.md); merged 1 into your a.md)")
  end

  it "reads a same-version conflict as behind in the system row and the summary, with why" do
    gone = Samagotchi::MemoryBundle::FileStanding::Behind.new(file: "identity.md", version: "1", why: Samagotchi::MemoryBundle::FileStanding.no_merge("git not found"))
    result = Samagotchi::MemoryBundle::SystemBundle::Result.new(from: "1", to: "1", status: :up_to_date, merged: [], behind: [gone], warnings: [])
    allow(Samagotchi::MemoryBundle::SystemBundle).to receive(:sync).and_return(result)
    command = described_class.new(["--no-gem"], stdout: out, stderr: err)

    row = command.send(:system_bundle_row)
    expect(row.status).to eq("identity.md stays behind 1: no merge possible (git not found) (chi bundle diff samagotchi-system identity.md)")
    expect(command.send(:summary, [row])).to eq("1 file stays behind (see above)")

    result.behind = [Samagotchi::MemoryBundle::FileStanding::Behind.new(file: "identity.md", version: "1", unsure: true)]
    expect(command.send(:summary, [command.send(:system_bundle_row)])).to eq("1 file may be behind (see above)")
  end

  it "names merged files in a bundle's row, and what a dry run would merge" do
    update = Samagotchi::MemoryBundle::ShippedUpdate::Row.new(
      name: "known-names", from: "1", to: "2", status: :updated, merged: ["a.md"], behind: [Samagotchi::MemoryBundle::FileStanding::Behind.new(file: "b.md", version: "2", missed: ["## Steps"])], replaced: [],
      trash_copy: "Copied to the trash first: a.md (/t)"
    )
    row = described_class.new(["--no-gem"], stdout: out, stderr: err).send(:bundle_row, update)
    expect(row.status).to eq("updated (merged 2 into your a.md; b.md stays behind 2: missed ## Steps (chi bundle diff known-names b.md); old copies: chi bundle trash)")

    command = described_class.new(["--no-gem"], stdout: out, stderr: err)
    command.instance_variable_set(:@dry_run, true)
    update.trash_copy = nil
    expect(command.send(:bundle_row, update).status).to eq("would update (would merge 2 into your a.md; b.md would stay behind 2: missed ## Steps (chi bundle diff known-names b.md))")
    update.behind = []
    expect(command.send(:bundle_row, update).status).to eq("would update (would merge 2 into your a.md)")
  end

  it "names the trash copy of an edited hook it replaced" do
    update = Samagotchi::MemoryBundle::ShippedUpdate::Row.new(
      name: "known-names", from: "1", to: "2", status: :updated, behind: [], replaced: ["hooks/x.rb"],
      trash_copy: "Copied to the trash first: hooks/x.rb (/t)"
    )
    row = described_class.new(["--no-gem"], stdout: out, stderr: err).send(:bundle_row, update)

    expect(row.status).to include("replaced edited hooks/x.rb (it wasn't loading)").and include("old copies: chi bundle trash")
  end

  it "leaves the bundles alone with --no-bundles or update.bundles: false" do
    install_old_btw
    expect(run("--no-bundles")).to eq(0)
    expect(line("bundles")).to end_with("skipped (--no-bundles)")
    expect(out.string).not_to include("Also shipped")

    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("update.bundles").and_return(false)
    run
    expect(line("bundles")).to end_with("skipped (update.bundles: false)")
    expect(btw_version).to eq("0.0.1")
  end

  describe "the external bundles' re-check" do
    let(:fixture) { File.expand_path("fixtures/bundles/check/clean", __dir__) }

    # The check spec's clean bundle as +name+, with this plugin source and
    # manifest keys, installed from a folder of its own (not a shipped one).
    def install_external(name, plugin: nil, manifest: {}, dev: false)
      dir = File.join(tmp, "external", name)
      FileUtils.mkdir_p(File.dirname(dir))
      FileUtils.cp_r(fixture, dir)
      File.write(File.join(dir, "plugin.rb"), plugin) if plugin
      path = File.join(dir, "manifest.yml")
      File.write(path, Samagotchi::MemoryBundle::Shas.refresh(dir).first)
      File.write(path, YAML.dump(YAML.load_file(path).merge("name" => name).merge(manifest)))
      Samagotchi::MemoryBundle::Installer.new(source: dir, name: name, scope: "system", strict: true, dev: dev).run
      dir
    end

    def stale_plugin
      <<~RUBY
        class Plugin
          def register(chi)
            chi.on(:after_tool_call) { |_event, ctx| ctx.gone_api }
          end
        end
      RUBY
    end

    def json_rows(*argv)
      status = run("--json", "--no-gem", "--no-desktop", *argv)
      [status, JSON.parse(out.string)]
    end

    def finding_rows(rows, name) = rows.select { |row| row["component"] == name && row["level"] }

    def installed_bytes
      Dir.glob(File.join(Samagotchi::MemoryBundle::Provenance.bundles_dir, "**", "*")).select { |f| File.file?(f) }.to_h { |f| [f, File.binread(f)] }
    end

    it "warns about a stale name, says nothing of a clean bundle, and changes neither" do
      install_external("clean-one")
      install_external("stale-one", plugin: stale_plugin)
      Samagotchi::MemoryBundle::SystemBundle.sync
      before = installed_bytes

      status, rows = json_rows
      expect(status).to eq(0)
      expect(finding_rows(rows, "clean-one")).to be_empty
      expect(rows.find { |r| r["component"] == "clean-one" }["status"]).to eq("skipped (not from chi)")
      stale = finding_rows(rows, "stale-one")
      expect(stale.size).to eq(1)
      expect(stale.first).to include("level" => "warn", "failed" => false, "kept" => [])
      expect(stale.first["status"]).to start_with("warn api plugin.rb:3:").and include("gone_api")
      expect(installed_bytes).to eq(before)
    end

    it "warns on an internal name only when this chi no longer has it, and says so" do
      install_external("still-there", plugin: <<~RUBY)
        class Plugin
          def register(chi) = nil
          def logged = Samagotchi::Log
        end
      RUBY
      install_external("no-longer", plugin: <<~RUBY)
        class Plugin
          def register(chi) = nil
          def thing = Samagotchi::OldInternal::Thing
        end
      RUBY

      _, rows = json_rows
      expect(finding_rows(rows, "still-there")).to be_empty
      gone = finding_rows(rows, "no-longer")
      expect(gone.size).to eq(1)
      expect(gone.first).to include("level" => "warn", "failed" => false)
      expect(gone.first["status"]).to eq("warn boundary plugin.rb: Samagotchi::OldInternal::Thing is gone from this chi, " \
                                         "so this bundle may fail (fix: use chi.* / ctx, or the names docs/plugins.md lists as stable)")
    end

    it "keeps saying a second run is up to date, the warning row repeating" do
      Samagotchi::MemoryBundle::SystemBundle.sync
      install_external("stale-one", plugin: stale_plugin)

      2.times do
        expect(run("--no-gem", "--no-desktop")).to eq(0)
        expect(line("stale-one")).to match(/\Astale-one\s+\S+\s+skipped \(not from chi\)\z/)
        expect(out.string).to include("warn api plugin.rb:3:", "Bundles not from chi are left as they are")
        expect(out.string).to end_with("everything is up to date\n")
      end
    end

    it "reports a requires_chi the new chi fails as an error row, without failing the update" do
      install_external("too-old", manifest: { "requires_chi" => "< 0.1" })
      status, rows = json_rows
      row = finding_rows(rows, "too-old").first
      expect(status).to eq(0)
      expect(row).to include("level" => "error", "failed" => false)
      expect(row["status"]).to start_with("error requires-chi manifest.yml").and include("this chi can't load it")
    end

    it "reports a plugin that no longer loads" do
      install_external("broken", plugin: "class Plugin\n  def register(chi) = chi.no_such_registration\nend\n")
      status, rows = json_rows
      expect(status).to eq(0)
      expect(finding_rows(rows, "broken").map { |r| r["status"] }).to include(a_string_including("no_such_registration"))
    end

    it "skips what only an author's source tree can act on" do
      dir = install_external("plain", plugin: "class Plugin\n  def register(chi) = nil\nend\n",
                                      manifest: { "trust_level" => "reviewed", "requires_chi" => nil, "needs" => ["no-such-command-here"] })
      FileUtils.mkdir_p(File.join(dir, "spec"))
      _, rows = json_rows
      expect(finding_rows(rows, "plain")).to be_empty
    end

    it "says an installed plugin edited since doesn't load, and leaves it" do
      install_external("edited")
      plugin = File.join(Samagotchi::MemoryBundle::Provenance.new(name: "edited").plugin_dir, "plugin.rb")
      File.write(plugin, "#{File.read(plugin)}\n# mine\n")
      _, rows = json_rows
      expect(finding_rows(rows, "edited").map { |r| r["status"] }).to include(a_string_starting_with("warn edited plugin/plugin.rb:"))
      expect(File.read(plugin)).to end_with("# mine\n")
    end

    it "checks a dev install's linked files" do
      install_external("linked", plugin: stale_plugin, dev: true)
      _, rows = json_rows
      expect(finding_rows(rows, "linked").map { |r| r["status"] }).to contain_exactly(a_string_starting_with("warn api plugin.rb:3:"))
    end

    it "loads it with the user's config.yml settings" do
      install_external("configured", plugin: <<~RUBY)
        class Plugin
          def initialize(settings) = settings.fetch("needed")
          def register(chi) = nil
        end
      RUBY
      _, rows = json_rows
      expect(finding_rows(rows, "configured").size).to eq(1)

      File.write(Samagotchi::ConfigFile.global_path, YAML.dump("bundles" => { "configured" => { "needed" => 1 } }))
      _, rows = json_rows
      expect(finding_rows(rows, "configured")).to be_empty
    end

    it "leaves the shipped bundles out" do
      install_old_btw
      _, rows = json_rows
      expect(rows.select { |r| r["level"] }).to be_empty
    end

    it "makes a bundle whose check dies a row of its own, and goes on" do
      install_external("exits", plugin: "exit 7\n")
      install_external("exits-hard", plugin: "Process.exit!(7)\n")
      install_external("stale-one", plugin: stale_plugin)
      status, rows = json_rows
      expect(status).to eq(0)
      expect(finding_rows(rows, "exits").map { |r| r["status"] }.join).to include("SystemExit")
      expect(finding_rows(rows, "exits-hard").first).to include("level" => "error", "failed" => false)
      expect(finding_rows(rows, "exits-hard").first["status"]).to start_with("error check manifest.json: the check died")
      expect(finding_rows(rows, "stale-one").size).to eq(1)
    end

    it "takes half an answer as that bundle's own row (a child that died mid-write)" do
      install_external("half", plugin: "")
      allow(File).to receive(:read).and_wrap_original do |read, path, *rest, **opts|
        path.to_s.end_with?("answer.json") ? '[{"level' : read.call(path, *rest, **opts)
      end
      status, rows = json_rows
      expect(status).to eq(0)
      expect(finding_rows(rows, "half").first).to include("level" => "error", "failed" => false)
      expect(finding_rows(rows, "half").first["status"]).to include("the check died: JSON::ParserError")
    end

    it "gives up on a bundle whose load hangs" do
      install_external("hangs", plugin: "sleep\n")
      stub_const("Samagotchi::BundleCommand::InstalledCheck::TIMEOUT", 2)
      status, rows = json_rows
      expect(status).to eq(0)
      expect(finding_rows(rows, "hangs").first["status"]).to start_with("error check manifest.json: no answer in 2 s")
    end

    it "keeps a plugin's own printing out of --json" do
      install_external("noisy", plugin: "$stdout.puts 'hi'\nSTDOUT.puts 'hi'\nsystem('echo hi')\nclass Plugin\n  def register(chi) = nil\nend\n")
      expect(run("--json", "--no-gem", "--no-desktop")).to eq(0)
      expect { JSON.parse(out.string) }.not_to raise_error
    end

    it "leaves it out with --no-bundles or update.bundles: false" do
      install_external("stale-one", plugin: stale_plugin)
      expect(run("--no-bundles", "--no-gem", "--no-desktop")).to eq(0)
      expect(out.string).not_to include("gone_api", "external bundles")

      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("update.bundles").and_return(false)
      run("--no-gem", "--no-desktop")
      expect(out.string).not_to include("gone_api", "external bundles")
    end

    it "checks in a dry run when no newer gem is coming" do
      install_external("stale-one", plugin: stale_plugin)
      expect(run("--dry-run", "--no-desktop")).to eq(0)
      expect(out.string).to include("warn api plugin.rb:3:", "(dry run: nothing was changed)")
    end

    it "checks in the run handed over to: the new chi's" do
      install_external("stale-one", plugin: stale_plugin)
      expect(run("--no-gem", "--gem-from", "0.2.0", "--no-desktop")).to eq(0)
      expect(out.string).to include("warn api plugin.rb:3:")
    end

    context "with a newer gem" do
      let(:newer) { Gem::Version.new(Samagotchi::VERSION).bump.to_s + ".0" }
      let(:fetcher) { -> { JSON.generate(version: newer) } }
      let(:no_wrapper) do
        Gem::Specification.new { |s| s.name = "samagotchi"; s.version = Samagotchi::VERSION }
                          .tap { |s| s.loaded_from = File.join(tmp, "no-wrapper", "specifications", "samagotchi.gemspec") }
      end

      it "doesn't check against this chi in a dry run: the newer one would" do
        install_external("stale-one", plugin: stale_plugin)
        expect(run("--dry-run", "--no-desktop")).to eq(0)
        expect(line("external bundles")).to end_with("not checked (chi #{newer} checks them once installed)")
        expect(out.string).not_to include("gone_api")
      end

      it "says nothing of it with no external bundle" do
        run("--dry-run", "--no-desktop")
        expect(out.string).not_to include("external bundles")
      end

      it "doesn't check against this chi when nothing can hand over to the new gem" do
        install_external("stale-one", plugin: stale_plugin)
        expect(run("--no-desktop", gem_spec: no_wrapper)).to eq(0)
        expect(execs).to be_empty
        expect(line("chi (gem)")).to include("run chi update again")
        expect(line("external bundles")).to end_with("not checked (chi #{newer} checks them: run chi update again)")
        expect(out.string).not_to include("gone_api")
      end

      it "checks against this chi when the install failed: it is what stays" do
        allow(gem_runner).to receive(:run).and_return(["no\n", false])
        install_external("stale-one", plugin: stale_plugin)
        expect(run("--no-desktop")).to eq(1)
        expect(out.string).to include("warn api plugin.rb:3:")
      end
    end
  end

  describe "the gem" do
    let(:newer) { Gem::Version.new(Samagotchi::VERSION).bump.to_s + ".0" }
    let(:fetcher) { -> { JSON.generate(version: newer) } }
    let(:wrapper_dir) { File.join(tmp, "gemhome") }
    let(:gem_spec) do
      FileUtils.mkdir_p(File.join(wrapper_dir, "bin"))
      File.write(File.join(wrapper_dir, "bin", "chi"), "")
      Gem::Specification.new { |s| s.name = "samagotchi"; s.version = Samagotchi::VERSION }
                        .tap { |s| s.loaded_from = File.join(wrapper_dir, "specifications", "samagotchi.gemspec") }
    end

    it "installs a newer one with this Ruby's gem and hands over to the wrapper, passing the flags on" do
      expect(gem_runner).to receive(:run).with(["/rb/bin/gem", "install", "samagotchi", "--no-document", "-v", newer])
                                         .and_return(["Successfully installed\n", true])
      run("--no-desktop", "--to", newer, "--json")
      expect(err.string).to include("installing samagotchi #{newer}…")
      expect(execs).to eq([[RbConfig.ruby, File.join(wrapper_dir, "bin", "chi"), "update", "--no-gem", "--gem-from",
                            Samagotchi::VERSION, "--to", newer, "--no-desktop", "--json"]])
    end

    it "shows the handed-over update as the gem row" do
      run("--no-gem", "--gem-from", "0.2.0")
      expect(line("chi (gem)")).to match(/\Achi \(gem\)\s+0\.2\.0\s+#{Regexp.escape(Samagotchi::VERSION)}\s+updated\z/)
    end

    it "accepts the target handed over by the newly installed chi" do
      expect(run("--to", Samagotchi::VERSION, "--gem-from", "0.2.0", "--json")).to eq(0)
      expect(JSON.parse(out.string).first).to include("from" => "0.2.0", "to" => Samagotchi::VERSION)
    end

    it "says would update in a dry run, installing nothing" do
      expect(gem_runner).not_to receive(:run)
      run("--dry-run")
      expect(line("chi (gem)")).to match(/#{Regexp.escape(newer)}\s+would update\z/)
      expect(execs).to be_empty
    end

    it "installs nothing when this is the newest" do
      allow(gem_update).to receive(:latest).and_return(Samagotchi::GemUpdate::Latest.new(version: Samagotchi::VERSION, source: "samagotchi"))
      expect(gem_runner).not_to receive(:run)
      run
      expect(line("chi (gem)")).to end_with("up to date")
    end

    it "says couldn't check when offline, and still syncs" do
      allow(gem_update).to receive(:latest).and_raise(Samagotchi::GemUpdate::Error, "SocketError: getaddrinfo failed")
      expect(run).to eq(0)
      expect(line("chi (gem)")).to end_with("couldn't check (SocketError: getaddrinfo failed)")
      expect(line("system bundle")).to end_with("installed")
    end

    it "reports a failed install and syncs on this version" do
      allow(gem_runner).to receive(:run).and_return(["ERROR:  While executing gem ... (Gem::FilePermissionError)\n", false])
      expect(run).to eq(1)
      expect(line("chi (gem)")).to end_with("failed (ERROR:  While executing gem ... (Gem::FilePermissionError))")
      expect(line("system bundle")).to end_with("installed")
      expect(execs).to be_empty
    end

    it "is skipped with --no-gem or update.gem: false" do
      expect(gem_runner).not_to receive(:run)
      run("--no-gem")
      expect(line("chi (gem)")).to end_with("skipped (--no-gem)")
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("update.gem").and_return(false)
      run
      expect(line("chi (gem)")).to end_with("skipped (update.gem: false)")
    end

    context "under Bundler" do
      let(:bundler) { true }

      it "is skipped with the bundle hint" do
        expect(gem_runner).not_to receive(:run)
        run
        expect(line("chi (gem)")).to end_with("skipped (under Bundler: bundle update samagotchi)")
      end
    end

    context "with a chi home" do
      # This process's Ruby and gem dir: it runs on the home (Record#running_here?).
      let(:home) do
        Samagotchi::ChiHome::Record.new(ruby: RbConfig.ruby, gem_home: Gem.dir, gem_path: Gem.dir, mise: nil,
                                        set_at: "t", set_by_version: "1")
      end
      let(:chi_home) { double("ChiHome", current: home, record_first!: nil) }
      let(:boot) { home.boot_argv(run: Samagotchi::ChiHome::CHI_BOOT) }

      context "from another Ruby" do
        let(:home) do
          Samagotchi::ChiHome::Record.new(ruby: "/home/bin/ruby", gem_home: "/hg", gem_path: "/hg", mise: nil,
                                          set_at: "t", set_by_version: "1")
        end

        it "execs the home's chi update once, with this run's args, saying so" do
          expect(gem_runner).not_to receive(:run)
          expect(run("--to", newer, "--no-desktop")).to eq(0)
          expect(out.string).to eq("updating the chi home (/home/bin/ruby)\n")
          expect(execs).to eq([[{ described_class::IN_HOME_ENV => "1" }, *boot, "--", "update", "--to", newer,
                                "--no-desktop"]])
        end

        context "under Bundler" do
          let(:bundler) { true }

          # The home is a chi of its own: Bundler's RUBYOPT/BUNDLE_GEMFILE
          # would load this bundle into it (worker spawns and chi web's
          # restart unbundle the same way).
          it "execs the home's chi update outside the bundle" do
            allow(Samagotchi::ChildEnv).to receive(:unbundled).and_return({ "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil })
            expect(run("--no-desktop")).to eq(0)
            expect(execs).to eq([[{ "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, described_class::IN_HOME_ENV => "1" },
                                  *boot, "--", "update", "--no-desktop"]])
          end
        end

        # The home's chi decides --to's floor: it may be newer than this one.
        it "hands even a --to this chi wouldn't take to the home, and the notice to stderr with --json" do
          run("--to", Samagotchi::VERSION, "--json")
          expect(err.string).to eq("updating the chi home (/home/bin/ruby)\n")
          expect(execs.first.last(4)).to eq(["update", "--to", Samagotchi::VERSION, "--json"])
        end

        it "doesn't exec again in the run it exec'd, and takes the marker out of the env" do
          env = { described_class::IN_HOME_ENV => "1" }
          described_class.new(%w[--no-gem --no-desktop], stdout: out, stderr: err, gem_spec: gem_spec, supported: false,
                                                          state_dir: state_dir, web: web, exec: ->(argv) { execs << argv },
                                                          bundler: false, home: chi_home, env: env).run
          expect(execs).to be_empty
          expect(env).to be_empty
          expect(line("chi (gem)")).to end_with("skipped (--no-gem)")
        end
      end

      it "installs with the home's gem into the home's gems and hands over to the home's chi" do
        installer = double("runner")
        expect(installer).to receive(:run)
          .with([home.gem_bin, "install", "samagotchi", "--no-document", "-v", newer],
                env: { "GEM_HOME" => Gem.dir, "GEM_PATH" => Gem.dir })
          .and_return(["Successfully installed\n", true])
        allow(Samagotchi::GemUpdate::Runner).to receive(:new).and_return(installer)
        described_class.new(["--no-desktop", "--to", newer], stdout: out, stderr: err, gem_spec: gem_spec, supported: false,
                                                                state_dir: state_dir, web: web, exec: ->(argv) { execs << argv },
                                                                bundler: false, home: chi_home).run
        expect(execs).to eq([boot + ["--", "update", "--no-gem", "--gem-from", Samagotchi::VERSION, "--to", newer,
                                     "--no-desktop"]])
      end
    end

    context "without a chi home yet" do
      let(:recorded) do
        Samagotchi::ChiHome::Record.new(ruby: RbConfig.ruby, gem_home: Gem.dir, gem_path: Gem.dir, mise: nil,
                                        set_at: "t", set_by_version: "1")
      end
      let(:chi_home) { double("ChiHome", current: nil) }

      it "records the first one and says so (never in a dry run)" do
        expect(chi_home).to receive(:record_first!).with(gem_spec: gem_spec, launch_path: nil, bundler: false).once
                                                   .and_return(recorded)
        run("--no-gem", "--no-desktop", "--no-bundles")
        expect(out.string.lines.first).to eq("chi home set to #{RbConfig.ruby} (chi home set to change)\n")

        run("--dry-run", "--no-gem", "--no-desktop", "--no-bundles")
      end

      # Only once this chi's own checks passed: a refused run records nothing.
      it "records nothing for a --to this chi refuses, or under Bundler" do
        expect(chi_home).not_to receive(:record_first!)
        expect(run("--to", Samagotchi::VERSION)).to eq(1)
      end

      context "under Bundler" do
        let(:bundler) { true }

        it "records nothing" do
          expect(chi_home).not_to receive(:record_first!)
          run("--no-gem", "--no-desktop", "--no-bundles")
        end
      end

      it "execs the recorded home's chi when it is on another Ruby" do
        other = recorded.with(ruby: "/helper/bin/ruby", gem_home: "/hg", gem_path: "/hg")
        allow(chi_home).to receive(:record_first!).and_return(other)
        run("--no-desktop")
        expect(out.string.lines).to eq(["chi home set to /helper/bin/ruby (chi home set to change)\n",
                                        "updating the chi home (/helper/bin/ruby)\n"])
        expect(execs.size).to eq(1)
      end
    end
  end

  describe Samagotchi::GemUpdate do
    it "parses RubyGems releases with their creation time and prerelease flag" do
      created_at = "2026-10-26T12:00:00.000Z"
      update = described_class.new(env: {}, fetcher: lambda { |url|
        expect(url.to_s).to end_with("/api/v1/versions/samagotchi.json")
        JSON.generate([{ number: "9.0.0", prerelease: false, created_at: created_at, platform: "ruby" }])
      })

      expect(update.releases).to eq([described_class::Release.new(version: "9.0.0", created_at: Time.iso8601(created_at),
                                                                  prerelease: false)])
    end

    it "wraps a malformed releases response in an Error" do
      update = described_class.new(env: {}, fetcher: ->(_url) { "<html>" })

      expect { update.releases }.to raise_error(described_class::Error, /JSON::ParserError/)
    end

    it "treats SAMAGOTCHI_UPDATE_GEM_FILE's file as the newest and installs that file" do
      spec = Gem::Specification.new do |s|
        s.name = "samagotchi"
        s.version = "9.0.0.pre2"
        s.summary = "t"
        s.authors = ["t"]
        s.files = []
      end
      gem_file = File.join(tmp, "samagotchi-9.0.0.pre2.gem")
      Gem::Package.build(spec, false, false, gem_file)
      update = described_class.new(env: { "SAMAGOTCHI_UPDATE_GEM_FILE" => gem_file }, fetcher: -> { raise "no network" }, gem_bin: "gem")
      latest = update.latest
      expect(latest.version).to eq("9.0.0.pre2")
      expect(update.install_argv(latest)).to eq(["gem", "install", gem_file, "--no-document"])

      release = update.releases.fetch(0)
      expect(release.version).to eq("9.0.0.pre2")
      expect(release.prerelease).to be(true)
      expect(release.created_at).to eq(File.mtime(gem_file))
    end

    it "runs the install with the chi home's env on top of this process's" do
      runner = double("runner")
      latest = described_class::Latest.new(version: "9.0.0", source: "samagotchi")
      expect(runner).to receive(:run).with(["/h/bin/gem", "install", "samagotchi", "--no-document", "-v", "9.0.0"],
                                           env: { "GEM_HOME" => "/hg" }).and_return(["ok", true])
      described_class.new(env: {}, runner: runner, gem_bin: "/h/bin/gem", install_env: { "GEM_HOME" => "/hg" }).install(latest)

      output, ok = described_class::Runner.new.run([RbConfig.ruby, "-e", "print ENV['CHI_X'].inspect"], env: { "CHI_X" => "1" })
      expect([output, ok]).to eq(['"1"', true])
    end

    it "reads its file from a variable that isn't a config key's env form" do
      expect(Samagotchi::Config::ENTRIES.map(&:env_key)).not_to include(described_class::LOCAL_ENV)
    end

    it "wraps a bad answer in an Error" do
      expect { described_class.new(env: {}, fetcher: -> { "<html>" }).latest }.to raise_error(described_class::Error, /JSON::ParserError/)
      expect { described_class.new(env: {}, fetcher: -> { "{}" }).latest }.to raise_error(described_class::Error, /without a version/)
    end
  end

  context "with the desktop helper (macOS)" do
    let(:supported) { true }
    let(:helper) do
      instance_double(Samagotchi::Desktop::MacOS, installed?: true, app_version: "0.0.9", stale?: false,
                                                  launch_outdated?: false, launch_problem: nil, launch_newer?: false,
                                                  terminal_warnings: [])
    end

    it "adds the terminals' warnings to the row, rebuilt or not" do
      allow(helper).to receive(:terminal_warnings).and_return(["tmux.enabled but no tmux found on PATH: set tmux.binary"])
      run
      expect(line("Chi Helper")).to end_with("up to date; tmux.enabled but no tmux found on PATH: set tmux.binary")
      allow(helper).to receive(:stale?).and_return(true)
      allow(helper).to receive(:upgrade)
      run
      expect(line("Chi Helper")).to end_with("updated (restarted); tmux.enabled but no tmux found on PATH: set tmux.binary")
    end

    it "says not installed" do
      allow(helper).to receive(:installed?).and_return(false)
      run
      expect(line("Chi Helper")).to end_with("not installed")
    end

    it "rebuilds a stale helper, but not in a dry run" do
      allow(helper).to receive(:stale?).and_return(true)
      expect(helper).to receive(:upgrade).with(keep_launch: true).once
      run("--dry-run")
      expect(line("Chi Helper")).to match(/0\.0\.9\s+#{Regexp.escape(Samagotchi::VERSION)}\s+would update \(rebuilds and restarts it\)\z/)
      run
      expect(line("Chi Helper")).to end_with("updated (restarted)")
    end

    it "only refreshes the launch file when the sources are unchanged" do
      allow(helper).to receive(:launch_outdated?).and_return(true)
      expect(helper).not_to receive(:upgrade)
      expect(helper).to receive(:refresh_launch_file).once
      run("--dry-run")
      expect(line("Chi Helper")).to end_with("up to date (would refresh the launch file)")
      run
      expect(line("Chi Helper")).to end_with("up to date (launch file refreshed)")
    end

    it "fails the row, without a rebuild or refresh, when the helper's kept ruby or chi is gone" do
      msg = "chi not found at /gone/ruby: run chi desktop install --force from the shell whose chi it should run"
      allow(helper).to receive(:launch_problem).and_return(msg)
      allow(helper).to receive(:stale?).and_return(true)
      expect(helper).not_to receive(:upgrade)
      expect(helper).not_to receive(:refresh_launch_file)
      expect(run).to eq(1)
      expect(line("Chi Helper")).to end_with("failed (#{msg})")
    end

    it "keeps a helper a newer chi set up: an older chi neither rebuilds nor refreshes it" do
      allow(helper).to receive_messages(launch_newer?: true, launch_version: "9.9.9", stale?: true, launch_outdated?: true)
      expect(helper).not_to receive(:upgrade)
      expect(helper).not_to receive(:refresh_launch_file)
      expect(run).to eq(0)
      expect(line("Chi Helper")).to end_with("up to date (kept: chi 9.9.9 set it up; this chi is older)")
    end

    it "skips it with --no-desktop" do
      expect(run("--no-desktop")).to eq(0)
      expect(line("Chi Helper")).to end_with("skipped (--no-desktop)")
    end

    it "reports a failed rebuild, exits 1 and still updates the bundles" do
      install_old_btw
      allow(helper).to receive(:stale?).and_return(true)
      allow(helper).to receive(:upgrade).and_raise(Samagotchi::Desktop::MacOS::Error, "swiftc failed:\nerror: nope")
      expect(run).to eq(1)
      expect(line("Chi Helper")).to end_with("failed (swiftc failed:)")
      expect(line("btw")).to end_with("updated")
      expect(out.string).to end_with("some parts failed (see above)\n")
    end
  end

  describe "live processes" do
    def listener = TCPServer.new("127.0.0.1", 0).tap { |s| servers << s }

    it "reports live workers on another version, without stopping them" do
      %w[aaaaaaaa-1 bbbbbbbb-2].each_with_index do |id, i|
        FileUtils.mkdir_p(File.join(state_dir, id))
        fields = i.zero? ? { version: "0.2.0" } : {}
        live_sidecar_fixture(File.join(state_dir, id), port: listener.addr[1], **fields)
      end
      run
      expect(line("workers")).to include("2 live on 0.2.0, an older chi: they keep it until restarted " \
                                         "(chi sessions stop aaaaaaaa bbbbbbbb); or they idle out after 30 min " \
                                         "with nothing attached")
    end

    it "says chi sessions restart for workers that can, stop for older ones, and never for idle exit 0" do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("session.idle_exit_minutes").and_return(0)
      { "aaaaaaaa-1" => ["restart"], "bbbbbbbb-2" => [] }.each do |id, features|
        FileUtils.mkdir_p(File.join(state_dir, id))
        live_sidecar_fixture(File.join(state_dir, id), port: listener.addr[1], version: "0.2.0", features: features)
      end
      run
      expect(line("workers")).to include("2 live on 0.2.0: they keep it until restarted (chi sessions restart " \
                                         "aaaaaaaa; chi sessions stop bbbbbbbb); they never idle out")
    end

    it "probes chi web on 127.0.0.1 when web.host is lan or a LAN address" do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("web.host").and_return("lan")
      command = described_class.new([], stdout: out, stderr: err, state_dir: state_dir)

      expect(command.instance_variable_get(:@web).first).to eq("127.0.0.1")
    end

    it "reports a chi web on another version" do
      server = listener
      Thread.new do
        client = server.accept
        client.readpartial(4096)
        body = JSON.generate(app: "chi-web", version: "0.2.0")
        client.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
      rescue IOError
        nil
      end
      web[1] = server.addr[1]
      run
      expect(line("chi web :#{server.addr[1]}")).to include("0.2.0", "new sessions it starts run 0.2.0 too; restart it")
    end

    # A chi web started with --port: config's web.port (web) has nothing on it.
    def old_web_answering
      listener.tap do |server|
        Thread.new do
          client = server.accept
          client.readpartial(4096)
          body = JSON.generate(app: "chi-web", version: "0.2.0")
          client.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
          client.close
        rescue IOError
          nil
        end
      end
    end

    it "finds a chi web on the port it recorded, not config's" do
      server = old_web_answering
      Samagotchi::Web::Running.record(port: server.addr[1], path: Samagotchi::Web::Running.path(state_dir: state_dir))
      run
      expect(line("chi web :#{server.addr[1]}")).to include("0.2.0", "restart it")
    end

    it "falls back on config's port when the recorded one has gone (a chi web killed hard)" do
      server = old_web_answering
      Samagotchi::Web::Running.record(port: closed_port, path: Samagotchi::Web::Running.path(state_dir: state_dir))
      web[1] = server.addr[1]
      run
      expect(line("chi web :#{server.addr[1]}")).to include("0.2.0", "restart it")
    end

    it "says a chi web that starts newest workers only needs a restart" do
      server = listener
      Thread.new do
        client = server.accept
        client.readpartial(4096)
        body = JSON.generate(app: "chi-web", version: "0.2.0", features: %w[dir newest_workers])
        client.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
      rescue IOError
        nil
      end
      web[1] = server.addr[1]
      run
      expect(line("chi web :#{server.addr[1]}")).to end_with("running old code; restart it")
    end
  end
end
