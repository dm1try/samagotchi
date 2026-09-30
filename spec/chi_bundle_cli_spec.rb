# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"
require "digest"
require "fileutils"
require "spec_helper"

# `chi bundle` through bin/chi, as a user runs it: the text on each stream
# and the exit codes, pinned before the command moved out of bin/chi. Each
# run gets its own config and state folders and a cwd in no git repo.
RSpec.describe "chi bundle (CLI)" do
  CHI_BUNDLE_BIN = File.expand_path("../bin/chi", __dir__)
  BUNDLE_FIXTURES = File.expand_path("fixtures", __dir__)

  TOP_USAGE = <<~TEXT
    Usage: chi bundle <install|upgrade|uninstall|status|diff|list|build> [options]

      install <source> [--scope system|project] [--force]
        Install a memory bundle from a directory, zip, tar archive, or git URL.
        Source is the path/URL to the bundle (dir/zip/tar.gz/git).
        --force overwrites existing entries; default skips them.

      upgrade <source> [--scope system|project] [--force] [--dry-run] [--agent|--no-agent]
        Upgrade a bundle (3-way merge: auto-merge if not edited, conflict otherwise).
        --dry-run shows what would change. --agent launches interactive session on conflict.

      uninstall <bundle> [--scope system|project] [--force]
        Remove a bundle and its index entries (--force if locally edited).

      status [<bundle>]
        Show provenance + modification status for bundles.

      diff <bundle> [file]
        Show diffs between base/current/incoming for a bundle.

      list
        List installed bundles and the ones shipped with chi that aren't installed.

      build [--scope system|project] [--name NAME] [--version VER] [--description DESC] [--out PATH] [FILES...]
        Build local memories and installed hooks (and plugin) into a shareable bundle (dir or zip).
        --scope selects source dir (default: system). --out inferred from extension; default <name>.zip.
        FILES... optional allowlist of *.md basenames to include (default: all).
  TEXT

  INSTALL_USAGE = <<~TEXT
    Usage: chi bundle install <source> [--scope system|project] [--force]

      install <source> [--scope system|project] [--force]
        Install a memory bundle from a directory, zip, tar archive, or git URL,
        or a bundle shipped with chi by name (see: chi bundle list).
        --force overwrites existing entries; default skips them.
  TEXT

  BUILD_USAGE = <<~TEXT
    Usage: chi bundle build [--scope system|project] [--name NAME] [--version VER] [--description DESC] [--out PATH] [FILES...]

      build [--scope system|project] [--name NAME] [--version VER] [--description DESC] [--out PATH] [FILES...]
        Build local memories and installed hooks into a shareable bundle (dir or zip).
        --scope selects source dir (default: system). --out inferred from extension; default <name>.zip.
        FILES... optional allowlist of *.md basenames to include (default: all).

      Examples:
        chi bundle build --scope system
        chi bundle build --scope project --name my-bundle --version 1.0.0 --out bundle.zip
        chi bundle build --scope system --out ./my-bundle/ identity.md work.md
  TEXT

  # One sandbox: config (memories, bundles), state and a cwd outside any repo.
  def self.sandbox
    root = Dir.mktmpdir("chi-bundle-cli")
    %w[cfg state cwd].each { |dir| FileUtils.mkdir_p(File.join(root, dir)) }
    root
  end

  def self.run_in(root, *args, stdin_data: "")
    env = { "XDG_CONFIG_HOME" => File.join(root, "cfg"), "XDG_STATE_HOME" => File.join(root, "state"),
            "CI" => nil, "RACK_ENV" => nil, "SAMAGOTCHI_ENV" => nil }
    out, err, status = Open3.capture3(env, RbConfig.ruby, CHI_BUNDLE_BIN, "bundle", *args,
                                      stdin_data: stdin_data, chdir: File.join(root, "cwd"))
    [out, err, status.exitstatus]
  end

  # A bundle dir with one memory file, a.md (the shape of
  # spec/fixtures/sample_hooks_bundle/manifest.yml).
  def self.make_bundle(dir, name:, version:, content:)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "a.md"), content)
    File.write(File.join(dir, "manifest.yml"), <<~YAML)
      name: #{name}
      version: #{version}
      scope: system
      description: "Demo"
      files:
        a.md: sha256:#{Digest::SHA256.hexdigest(content)}
    YAML
    dir
  end

  def chi(*args, **opts) = self.class.run_in(@root, *args, **opts)
  def memories = File.join(@root, "cfg", "samagotchi", "memories")
  def provenance_line(name) = "Provenance written to: #{memories}/.bundles/#{name}/\n"

  context "with a fresh sandbox per example" do
    before { @root = self.class.sandbox }
    after { FileUtils.rm_rf(@root) }

    it "prints the usage on stdout for no argument, --help, -h and help" do
      [[], ["--help"], ["-h"], ["help"]].each do |args|
        expect(chi(*args)).to eq([TOP_USAGE, "", 0]), args.inspect
      end
    end

    it "prints each subcommand's own --help" do
      expect(chi("install", "--help")).to eq([INSTALL_USAGE, "", 0])
      expect(chi("upgrade", "--help")).to eq(["Usage: chi bundle upgrade <source> [--scope system|project] [--force] [--dry-run] [--agent|--no-agent]\n", "", 0])
      expect(chi("uninstall", "--help")).to eq(["Usage: chi bundle uninstall <bundle> [--scope system|project] [--force]\n", "", 0])
      expect(chi("build", "--help")).to eq([BUILD_USAGE, "", 0])
    end

    it "refuses install without a source, an unknown flag and a trailing --scope" do
      expect(chi("install")).to eq(["", "Usage: chi bundle install <source> [--scope system|project] [--force]\n", 1])
      expect(chi("install", "--bogus")).to eq(["", "Unknown bundle install flag: --bogus\n", 1])
      # quirk: a --scope with no value after it reads as an unknown flag
      expect(chi("install", "--scope")).to eq(["", "Unknown bundle install flag: --scope\n", 1])
    end

    # An unknown source fails like any other install ("Install failed: …",
    # exit 1), no backtrace; install's help is --help only, so -h is taken
    # as the source.
    it "says the source doesn't exist, -h included" do
      [["install", "bogus", "Install"], ["install", "-h", "Install"], ["upgrade", "bogus", "Upgrade"],
       ["upgrade", "bogus", "Upgrade", "--dry-run"]].each do |sub, source, word, *flags|
        expect(chi(sub, source, *flags))
          .to eq(["", "#{word} failed: source does not exist: #{File.realpath(File.join(@root, "cwd"))}/#{source}\n", 1]), [sub, source].inspect
      end
    end

    it "installs a hooks bundle and a plugin bundle" do
      expect(chi("install", File.join(BUNDLE_FIXTURES, "sample_hooks_bundle")))
        .to eq(["Installed: identity.md, guardrails.rb\nHooks: 1 hook(s) (guardrails.rb)\n#{provenance_line("sample-hooks-bundle")}", "", 0])
      expect(chi("install", File.join(BUNDLE_FIXTURES, "sample_plugin_bundle")))
        .to eq(["Installed: plugin.rb\nPlugin: plugin.rb (loads at the next chi start)\n#{provenance_line("sample-plugin")}", "", 0])
    end

    it "upgrades: falls back to install, then a dry run, then the upgrade" do
      v1 = self.class.make_bundle(File.join(@root, "b1"), name: "demo", version: "1.0.0", content: "one\n")
      v2 = self.class.make_bundle(File.join(@root, "b2"), name: "demo", version: "2.0.0", content: "two\n")

      expect(chi("upgrade", v1))
        .to eq(["Installed: a.md\n#{provenance_line("demo")}", "Bundle 'demo' not installed — falling back to install\n", 0])
      expect(chi("upgrade", v2, "--dry-run")).to eq(["Fast-forward: a.md\n(dry-run: no changes written)\n", "", 0])
      expect(chi("upgrade", v2)).to eq(["Updated: a.md\n#{provenance_line("demo")}", "", 0])
      expect(File.read(File.join(memories, "a.md"))).to eq("two\n")
    end

    it "writes nothing on a dry-run upgrade of a bundle that isn't installed" do
      v1 = self.class.make_bundle(File.join(@root, "b1"), name: "demo", version: "1.0.0", content: "one\n")

      expect(chi("upgrade", v1, "--dry-run"))
        .to eq(["Would install: a.md\n(dry-run: no changes written)\n", "Bundle 'demo' not installed — falling back to install\n", 0])
      expect(Dir.glob(File.join(memories, "**", "*"), File::FNM_DOTMATCH).select { |f| File.file?(f) }).to eq([])
    end

    it "refuses upgrade and uninstall without a source or name, and an unknown bundle" do
      expect(chi("upgrade")).to eq(["", "Usage: chi bundle upgrade <source> [--scope system|project] [--force] [--dry-run]\n", 1])
      expect(chi("upgrade", "--bogus")).to eq(["", "Unknown bundle upgrade flag: --bogus\n", 1])
      expect(chi("uninstall")).to eq(["", "Usage: chi bundle uninstall <bundle> [--scope system|project] [--force]\n", 1])
      expect(chi("uninstall", "--bogus")).to eq(["", "Unknown bundle uninstall flag: --bogus\n", 1])
      expect(chi("uninstall", "nope")).to eq(["", "Uninstall failed: Bundle 'nope' is not installed\n", 1])
    end

    it "uninstalls a hooks bundle" do
      chi("install", File.join(BUNDLE_FIXTURES, "sample_hooks_bundle"))

      expect(chi("uninstall", "sample-hooks-bundle"))
        .to eq(["Uninstalled bundle 'sample-hooks-bundle'\nRemoved: identity.md, hooks/guardrails.rb\nHooks removed: 1\n", "", 0])
    end

    it "lists nothing installed, then a shipped bundle installed by name" do
      out, err, code = chi("list")
      expect([err, code]).to eq(["", 0])
      expect(out).to start_with("No installed bundles.\n\nAvailable (shipped with chi, install with: chi bundle install <name>):\n")
      expect(out.lines.drop(3)).to all(match(/\A  [a-z-]+ +v\S+  \S/))
      expect(out).to match(/^  btw +v/)

      out, err, code = chi("install", "btw")
      expect([err, code]).to eq(["", 0])
      expect(out).to end_with(provenance_line("btw"))

      out, err, code = chi("list")
      expect([err, code]).to eq(["", 0])
      expect(out).to match(/\AInstalled:\n  btw +v\S+ +scope=system  files=\d+  installed=\S+\n\nAvailable/)
      expect(out).not_to match(/^  btw +v\S+  \//)
    end

    it "refuses a bad build scope and a value flag followed by a flag" do
      expect(chi("build", "--scope", "bogus")).to eq(["", "Invalid scope 'bogus', expected system or project\n", 1])
      expect(chi("build", "--name", "--out", "x")).to eq(["", "Unknown bundle build flag: --name\n", 1])
    end

    it "builds the listed local memories into a dir" do
      FileUtils.mkdir_p(memories)
      File.write(File.join(memories, "identity.md"), "# Identity\nme\n")
      File.write(File.join(memories, "work.md"), "# Work\nstuff\n")
      out_dir = File.join(@root, "b") + "/"

      out, err, code = chi("build", "--scope", "system", "--name", "mine", "--version", "1.2.3", "--out", out_dir, "identity.md")

      expect([err, code]).to eq(["", 0])
      expect(out).to eq("Built 1 file(s) to #{out_dir.chomp("/")}\nBundle: mine v1.2.3 scope=system\nFiles: identity.md\n")
    end

    it "refuses an unknown subcommand" do
      expect(chi("nope")).to eq(["", "Unknown bundle subcommand: nope. Use: install, upgrade, uninstall, status, diff, list, build\n", 1])
    end

    it "status and diff with nothing installed" do
      expect(chi("status")).to eq(["No installed bundles.\n", "", 0])
      # A named bundle that isn't installed: stdout, exit 0.
      expect(chi("status", "nope")).to eq(["Bundle 'nope' not installed.\n", "", 0])
      # quirk: status and diff only drop --args, so -h is a bundle name
      expect(chi("status", "-h")).to eq(["Bundle '-h' not installed.\n", "", 0])
      expect(chi("diff")).to eq(["", "Usage: chi bundle diff <bundle> [file]\n", 1])
      expect(chi("diff", "nope")).to eq(["", "Bundle 'nope' not installed\n", 1])
      expect(chi("diff", "-h")).to eq(["", "Bundle '-h' not installed\n", 1])
    end
  end

  context "with a conflicting local edit" do
    before do
      @root = self.class.sandbox
      v1 = self.class.make_bundle(File.join(@root, "b1"), name: "demo", version: "1.0.0", content: "one\n")
      @v3 = self.class.make_bundle(File.join(@root, "b3"), name: "demo", version: "3.0.0", content: "three\n")
      chi("install", v1)
      File.write(File.join(memories, "a.md"), "edited\n")
    end

    after { FileUtils.rm_rf(@root) }

    let(:conflict_head) do
      "Conflicts: a.md\nConflict in a.md: local edits conflict with bundle update (use --force to overwrite or resolve interactively)\n" \
        "\n1 conflict(s) need resolution.\n  conflict: a.md\n"
    end

    it "keeps the edit and exits 2 on a non-tty stdin" do
      expect(chi("upgrade", @v3)).to eq([
        "#{conflict_head}Non-interactive terminal: kept your edits in the file(s) above; the rest is upgraded. " \
        "Re-run with --force to take the bundle's version, or --agent in a TTY to merge.\n", "", 2
      ])
      expect(File.read(File.join(memories, "a.md"))).to eq("edited\n")
    end

    it "keeps the edit and exits 2 with --no-agent" do
      expect(chi("upgrade", @v3, "--no-agent")).to eq([
        "#{conflict_head}Kept your edits in the file(s) above; the rest is upgraded. chi bundle diff demo FILE shows the base; " \
        "re-run with --force to take the bundle's version.\n", "", 2
      ])
    end

    it "takes the bundle's version with --force" do
      out, err, code = chi("upgrade", @v3, "--force")

      expect([out, err, code]).to eq(["Installed: a.md\n#{provenance_line("demo")}", "", 0])
      expect(File.read(File.join(memories, "a.md"))).to eq("three\n")
    end
  end

  context "with a hooks bundle and a plugin bundle installed" do
    before(:context) do
      @root = sandbox_root = self.class.sandbox
      self.class.run_in(sandbox_root, "install", File.join(BUNDLE_FIXTURES, "sample_hooks_bundle"))
      self.class.run_in(sandbox_root, "install", File.join(BUNDLE_FIXTURES, "sample_plugin_bundle"))
    end

    after(:context) { FileUtils.rm_rf(@root) }

    it "status lists both" do
      expect(chi("status")).to eq([
        "  sample-hooks-bundle v1.0.0 scope=system files=1 hooks=1 issues=0\n" \
        "  sample-plugin v1.0.0 scope=system files=0 plugin=plugin.rb issues=0\n", "", 0
      ])
    end

    it "status NAME shows files, trust and hooks" do
      out, err, code = chi("status", "sample-hooks-bundle")

      expect([err, code]).to eq(["", 0])
      expect(out).to match(/\ABundle: sample-hooks-bundle v1\.0\.0 scope=system installed=\S+\n/)
      expect(out.lines.drop(1).join).to eq(<<~TEXT)
        Target: #{memories}
          identity.md: ok
          trust_level: reviewed
          Hooks (1):
            guardrails.rb: event=before_tool_call on_error=fail_closed priority=10 [ok]
      TEXT
    end

    it "status NAME shows a plugin" do
      out, err, code = chi("status", "sample-plugin")

      expect([err, code]).to eq(["", 0])
      expect(out.lines.drop(1).join).to eq("Target: #{memories}\n  trust_level: reviewed\n  Plugin: plugin.rb [ok]\n    requires_chi: >= 0.1.28\n")
    end

    # quirk: status takes the first non --arg as the name, a flag's value too
    it "status --scope project NAME takes 'project' as the name" do
      expect(chi("status", "--scope", "project", "sample-plugin")).to eq(["Bundle 'project' not installed.\n", "", 0])
    end

    it "diff shows every file and hook, one file, one hook, and an unknown file" do
      identity = File.read(File.join(BUNDLE_FIXTURES, "sample_hooks_bundle", "identity.md"))
      guardrails = File.read(File.join(BUNDLE_FIXTURES, "sample_hooks_bundle", "hooks", "guardrails.rb"))
      identity_block = "=== identity.md ===\n--- base (provenance) ---\n#{identity}--- current (on-disk) ---\n#{identity}\n"
      hook_block = "=== hooks/guardrails.rb ===\n--- base (provenance) ---\n#{guardrails}--- current (on-disk) ---\n#{guardrails}" \
                   "--- metadata: event=before_tool_call on_error=fail_closed priority=10 " \
                   "sha256=sha256:c85b4847cafaf3f4011833a87b455abcfb57b2bb5715056f779a1aadf820b504\n\n"

      expect(chi("diff", "sample-hooks-bundle")).to eq([identity_block + hook_block, "", 0])
      expect(chi("diff", "sample-hooks-bundle", "identity.md")).to eq([identity_block, "", 0])
      expect(chi("diff", "sample-hooks-bundle", "guardrails.rb")).to eq([hook_block, "", 0])
      expect(chi("diff", "sample-hooks-bundle", "nope.md")).to eq(["=== nope.md ===\n(not found in bundle)\n\n", "", 0])
    end

    it "diff shows a plugin" do
      plugin = File.read(File.join(BUNDLE_FIXTURES, "sample_plugin_bundle", "plugin.rb"))
      out, err, code = chi("diff", "sample-plugin")

      expect([err, code]).to eq(["", 0])
      expect(out).to match(/\A=== plugin\/plugin\.rb ===\n--- base \(provenance\) ---\n#{Regexp.escape(plugin)}--- current \(on-disk\) ---\n#{Regexp.escape(plugin)}--- metadata: sha256=\S+ requires_chi=>= 0\.1\.28\n\n\z/)
    end
  end
end
