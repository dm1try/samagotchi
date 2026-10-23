# frozen_string_literal: true

require "spec_helper"
require "digest"
require "fileutils"
require "stringio"
require "tmpdir"
require "samagotchi/bundle_command"
require "samagotchi/bundle_command/check"
require "samagotchi/testing"

# `chi bundle check`: one finding per line, the exit status, --fix, and a
# sandboxed install (nothing of the user's read for writing, nothing written).
RSpec.describe Samagotchi::BundleCommand::Check do
  FIXTURE = File.expand_path("../../fixtures/bundles/check/clean", __dir__)

  let(:tmp) { File.realpath(Dir.mktmpdir("check-spec-")) }
  let(:dir) { File.join(tmp, "check-clean") }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  before do
    FileUtils.cp_r(FIXTURE, dir)
    refresh!
  end

  after { FileUtils.rm_rf(tmp) }

  def refresh! = File.write(manifest, Samagotchi::MemoryBundle::Shas.refresh(dir).first)
  def manifest = File.join(dir, "manifest.yml")
  def edit(rel) = File.write(File.join(dir, rel), yield(File.read(File.join(dir, rel))))

  def check(*args, path: dir)
    @status = Samagotchi::BundleCommand.new(["check", *args, path].compact, stdout: out, stderr: err).run
    out.string.lines.map(&:chomp)
  end

  def findings(level = nil) = check.select { |l| level ? l.start_with?("#{level} ") : l.match?(/\A(error|warn|info) /) }

  it "passes the base fixture: registered and tests info lines, exit 0" do
    expect(check).to eq([
      "info registered plugin.rb: command /greet",
      "info registered plugin.rb: hook after_tool_call (priority 100)",
      "info registered hooks/watch.rb: hook after_turn (priority 100)",
      "info tests #{dir}: no tests (fix: chi bundle new NAME writes one to copy)",
      "ok: 0 errors, 0 warnings (#{dir})"
    ])
    expect(@status).to eq(0)
  end

  it "manifest: a parse error, verbatim, and the run stops (exit 1)" do
    File.write(manifest, "name: [\n")
    lines = check
    expect(lines.first).to start_with("error manifest manifest.yml: manifest.yml is not valid YAML in #{dir}: line")
    expect(lines.size).to eq(2)
    expect(@status).to eq(1)
  end

  it "missing-file: a listed file that isn't there, at its manifest line" do
    FileUtils.rm(File.join(dir, "hooks", "watch.rb"))
    expect(findings(:error)).to eq(["error missing-file manifest.yml:14: lists hooks/watch.rb, which isn't in the bundle " \
                                    "(fix: add the file or drop the entry)"])
  end

  it "unlisted: a memory, plugin, hook or script an install leaves out; a README isn't one" do
    File.write(File.join(dir, "extra.md"), "x")
    File.write(File.join(dir, "hooks", "loose.rb"), "x")
    FileUtils.mkdir_p(File.join(dir, "scripts"))
    File.write(File.join(dir, "scripts", "run.sh"), "x")
    expect(findings(:warn)).to eq([
      "warn unlisted extra.md: manifest.yml's files: doesn't list it, so an install leaves it out " \
      "(fix: list it under files:, then chi bundle check --fix)",
      "warn unlisted hooks/loose.rb: manifest.yml's hooks: doesn't list it, so an install leaves it out " \
      "(fix: list it under hooks:, then chi bundle check --fix)",
      "warn unlisted scripts/run.sh: manifest.yml's scripts: doesn't list it, so an install leaves it out " \
      "(fix: list it under scripts:, then chi bundle check --fix)"
    ])
  end

  it "sha: a placeholder and a stale sha are errors; --fix rewrites them, then it's clean, and --fix again is a no-op" do
    File.write(manifest, File.read(FIXTURE + "/manifest.yml"))
    edit("plugin.rb") { |text| "#{text}# edited\n" }

    expect(findings(:error)).to include(
      "error sha manifest.yml:9: a placeholder sha256 for check_note.md (fix: chi bundle check --fix)",
      "error sha manifest.yml:11: a placeholder sha256 for plugin.rb (fix: chi bundle check --fix)"
    )
    expect(findings(:info)).to include("info install manifest.yml: skipped until the placeholder shas are filled " \
                                       "(fix: chi bundle check --fix)")

    out.truncate(0)
    out.rewind
    lines = check("--fix")
    expect(lines).to include(a_string_matching(/\Afixed sha plugin.rb → sha256:\h{12}…\z/))
    expect(lines.grep(/\Aerror/)).to eq([])
    expect(@status).to eq(0)
    fixed = File.read(manifest)

    out.truncate(0)
    out.rewind
    expect(check("--fix").grep(/\Afixed/)).to eq([])
    expect(File.read(manifest)).to eq(fixed)
    expect(fixed).to start_with("# The base bundle") # the layout is kept
  end

  it "sha: a plugin with no sha line installs unchecked, an error --fix can't clear" do
    edit("manifest.yml") { |text| text.sub(/^plugin:\n  file: plugin.rb\n  sha256: sha256:\h+\n/, "plugin:\n  file: plugin.rb\n") }
    expect(findings(:error)).to eq(["error sha manifest.yml:11: plugin.rb has no sha256 line, so it installs unchecked " \
                                    "(fix: add `sha256: sha256:` under its entry, then chi bundle check --fix)"])
  end

  it "requires-chi: one this chi doesn't meet (error, the Installer's same warning left out), none for code (warn)" do
    edit("manifest.yml") { |text| text.sub('">= 0.80.0"', '">= 99.0.0"') }
    expect(findings(:error)).to eq(["error requires-chi manifest.yml:7: this chi can't load it: it requires chi >= 99.0.0 " \
                                    "(this is chi #{Samagotchi::VERSION}) (fix: chi update, or lower requires_chi)"])

    out.truncate(0)
    out.rewind
    edit("manifest.yml") { |text| text.sub(/^requires_chi: .*\n/, "") }
    expect(findings(:warn)).to eq(["warn requires-chi manifest.yml: no requires_chi for a bundle with code " \
                                   "(fix: add requires_chi: \">= #{Samagotchi::VERSION}\")"])
  end

  it "requires-chi-floor: the plugin calls an API newer than requires_chi admits" do
    edit("plugin.rb") { |text| text.sub("ctx.notify(@word)", "ctx.notify(ctx.cost.total.to_s)") }
    refresh!
    expect(findings(:warn)).to eq(["warn requires-chi-floor manifest.yml:7: requires_chi \">= 0.80.0\" admits chi 0.80.0, " \
                                   "but plugin.rb uses ctx.cost, which needs chi 0.83.0 (fix: requires_chi: \">= 0.83.0\")"])
  end

  it "requires-chi-floor: a member of a ctx object newer than the object itself" do
    edit("manifest.yml") { |text| text.sub('requires_chi: ">= 0.80.0"', 'requires_chi: ">= 0.30.0"') }
    edit("plugin.rb") { |text| text.sub("ctx.notify(@word)", "ctx.notify(ctx.sessions.children.size.to_s)") }
    refresh!
    expect(findings(:warn)).to eq(["warn requires-chi-floor manifest.yml:7: requires_chi \">= 0.30.0\" admits chi 0.30.0, " \
                                   "but plugin.rb uses ctx.sessions.children, which needs chi 0.34.0 " \
                                   "(fix: requires_chi: \">= 0.34.0\")"])
  end

  it "requires-chi-floor: ctx.turn_author (0.106.0) and ctx.sessions.stop (0.34.0) have floors" do
    edit("plugin.rb") { |text| text.sub("ctx.notify(@word)", "ctx.notify(ctx.turn_author.to_s)") }
    refresh!
    expect(findings(:warn)).to eq(["warn requires-chi-floor manifest.yml:7: requires_chi \">= 0.80.0\" admits chi 0.80.0, " \
                                   "but plugin.rb uses ctx.turn_author, which needs chi 0.106.0 " \
                                   "(fix: requires_chi: \">= 0.106.0\")"])

    out.truncate(0)
    out.rewind
    edit("manifest.yml") { |text| text.sub('requires_chi: ">= 0.80.0"', 'requires_chi: ">= 0.30.0"') }
    edit("plugin.rb") { |text| text.sub("ctx.notify(ctx.turn_author.to_s)", "ctx.sessions.stop(@word)") }
    refresh!
    expect(findings(:warn)).to eq(["warn requires-chi-floor manifest.yml:7: requires_chi \">= 0.30.0\" admits chi 0.30.0, " \
                                   "but plugin.rb uses ctx.sessions.stop, which needs chi 0.34.0 " \
                                   "(fix: requires_chi: \">= 0.34.0\")"])
  end

  it "install: a plugin that raises at load names plugin.rb:line" do
    edit("plugin.rb") { |text| text.sub("chi.command(", "raise ArgumentError, \"no word\"\n    chi.command(") }
    refresh!
    expect(findings(:error)).to eq(["error install plugin.rb:7: plugin plugin.rb (bundle check-clean) failed to load: " \
                                    "ArgumentError: no word"])
    expect(@status).to eq(1)
  end

  it "install: a hook file that doesn't load names hooks/<file>:line" do
    edit("hooks/watch.rb") { |text| text.sub("def call", "def initialize = Missing\n\n  def call") }
    refresh!
    expect(findings(:error)).to match([a_string_starting_with("error install hooks/watch.rb:4: hook watch.rb (bundle check-clean) " \
                                                           "failed to load: NameError")])
  end

  it "install: --set gives the load a setting" do
    edit("plugin.rb") { |text| text.sub('chi.command("/greet"', 'chi.command("/#{@word}"') } # rubocop:disable Lint/InterpolationCheck
    refresh!
    expect(check("--set", "word=hi")).to include("info registered plugin.rb: command /hi")
  end

  it "boundary: a name internal to chi is a warning" do
    edit("plugin.rb") { |text| text.sub("ctx.notify(@word)", "Samagotchi::MemoryPaths.scope_dir(\"system\")") }
    refresh!
    expect(findings(:warn)).to eq(["warn boundary plugin.rb: Samagotchi::MemoryPaths.scope_dir is internal to chi and may break " \
                                   "on a chi upgrade (fix: use chi.* / ctx, or the names docs/plugins.md lists as stable)"])
  end

  it "registered: a manifest hook with events: is one line per event" do
    edit("manifest.yml") { |text| text.sub("    event: after_turn", "    events: [after_turn, before_turn]") }
    refresh!
    expect(findings(:info)).to include("info registered hooks/watch.rb: hook after_turn (priority 100)",
                                       "info registered hooks/watch.rb: hook before_turn (priority 100)")
    expect(@status).to eq(0)
  end

  it "hook-event: a chi.on event chi never fires" do
    edit("plugin.rb") { |text| text.sub("chi.on(:after_tool_call)", "chi.on(:after_tool)") }
    refresh!
    expect(findings(:warn)).to eq(["warn hook-event plugin.rb: hook on :after_tool, which chi never fires " \
                                   "(fix: one of #{Samagotchi::Hooks::EVENTS.join(", ")})"])
  end

  it "clash: a name chi ships (the install then forces)" do
    edit("manifest.yml") { |text| text.sub("name: check-clean", "name: btw") }
    expect(findings(:warn)).to eq(["warn clash manifest.yml:3: chi ships a bundle named btw; installing this one replaces chi's " \
                                   "(fix: rename the bundle)"])
    expect(@status).to eq(0)
  end

  it "clash: a session setting --set would read as chi's own is an error, in the install's words (exit 1)" do
    edit("manifest.yml") { |text| text.sub("name: check-clean", "name: recap") + "session_settings: [sentences]\n" }
    expect(findings(:error)).to eq(["error clash manifest.yml:#{File.read(manifest).lines.size}: " \
                                    "#{Samagotchi::SessionConfig.clash("recap", ["sentences"])}"])
    expect(@status).to eq(1)
  end

  it "clash: a same-named bundle installed whose record can't be read is a warning, not skipped" do
    with_env("XDG_CONFIG_HOME" => File.join(tmp, "user-config")) do
      record = File.join(Samagotchi::MemoryPaths.bundles_dir, "check-clean", "manifest.json")
      FileUtils.mkdir_p(File.dirname(record))
      File.write(record, "{broken")
      expect(findings(:warn)).to contain_exactly(
        a_string_matching(/\Awarn clash manifest\.yml:\d+: a bundle named check-clean is installed, but its record can't be read \(.+\) \(fix: rename the bundle/)
      )
    end
  end

  it "trust: a trust_level the author set" do
    edit("manifest.yml") { |text| "#{text}trust_level: reviewed\n" }
    expect(findings(:warn)).to eq(["warn trust manifest.yml:17: trust_level: reviewed is set by the bundle's author " \
                                   "(fix: leave it out unless someone reviewed the bundle)"])
  end

  it "tests: run chi bundle test, on which Ruby and lib" do
    FileUtils.mkdir_p(File.join(dir, "test"))
    File.write(File.join(dir, "test", "greet_test.rb"), "")
    File.write(File.join(dir, "test", "more_test.rb"), "")
    expect(findings(:info).last).to eq("info tests test/: 2 files: run chi bundle test (Minitest on #{RbConfig.ruby}, " \
                                       "-I #{described_class::LIB_DIR})")
  end

  it "install: anything else the sandboxed install raises is one finding, not a trace" do
    allow(Samagotchi::Testing::Install).to receive(:run).and_raise(Errno::EACCES, "/x")
    expect(findings(:error)).to eq(["error install manifest.yml: the sandboxed install failed: Errno::EACCES: " \
                                    "Permission denied - /x"])
    expect(@status).to eq(1)
  end

  it "takes a symlinked path to a shipped bundle as chi's own (no clash or trust warning)" do
    link = File.join(tmp, "linked")
    File.symlink(File.join(Samagotchi::Testing::Bundle::SHIPPED_DIR, "guardrails"), link)
    expect(check(path: link).grep(/\Awarn (clash|trust) /)).to eq([])
  end

  it "reads nothing of the user's for writing: HOME and XDG dirs stay empty" do
    home = Dir.mktmpdir("check-home-")
    saved = ENV.to_h
    ENV.update("HOME" => home, "XDG_CONFIG_HOME" => File.join(home, ".config"), "XDG_STATE_HOME" => File.join(home, ".local/state"),
               "XDG_DATA_HOME" => File.join(home, ".local/share"), "XDG_CACHE_HOME" => File.join(home, ".cache"))
    check
    expect(@status).to eq(0)
    expect(Dir.glob(File.join(home, "**", "*"), File::FNM_DOTMATCH).reject { |f| File.basename(f) == "." }).to eq([])
  ensure
    ENV.replace(saved)
    FileUtils.rm_rf(home)
  end

  it "usage: a PATH that isn't a folder, two PATHs, a bad --set (exit 2)" do
    expect(check(path: File.join(tmp, "nope"))).to eq([])
    expect([@status, err.string]).to eq([2, "chi bundle check: #{tmp}/nope isn't a folder\n"])
    expect(Samagotchi::BundleCommand.new(["check", dir, dir], stdout: out, stderr: err).run).to eq(2)
    expect(Samagotchi::BundleCommand.new(["check", "--set", "nokey", dir], stdout: out, stderr: err).run).to eq(2)
    expect(err.string).to end_with("chi bundle check: --set takes KEY=VALUE, not nokey\n")
  end

  describe "the shipped bundles" do
    Dir[File.join(Samagotchi::Testing::Bundle::SHIPPED_DIR, "*", "manifest.yml")].sort.each do |path|
      name = File.basename(File.dirname(path))
      it "checks #{name} with no errors" do
        lines = check(path: File.dirname(path))
        expect([lines.grep(/\Aerror/), @status]).to eq([[], 0])
      end
    end
  end
end
