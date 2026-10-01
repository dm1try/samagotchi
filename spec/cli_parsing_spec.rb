# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "spec_helper"
require "samagotchi/send_command"
require "samagotchi/note_command"
require "samagotchi/bootstrap_command"
require "samagotchi/update_command"
require "samagotchi/desktop_command"
require "samagotchi/session_delete_command"
require "samagotchi/bundle_command"

# The subcommands' own flag parsing, pinned as users meet it: which forms
# each flag takes, what a flag value may look like, and the exact text and
# exit status of each usage error.
RSpec.describe "chi subcommand argument parsing" do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:tmpdir) { Dir.mktmpdir("cli-parsing") }

  after { FileUtils.rm_rf(tmpdir) }

  describe "chi send" do
    def command(*argv) = Samagotchi::SendCommand.new(argv, stdin: StringIO.new(""), stdout: out, stderr: err, state_dir: tmpdir)
    def parse(*argv) = command(*argv).send(:parse)
    def usage(message) = "chi send: #{message}\n#{Samagotchi::SendCommand::USAGE}"

    it "takes each flag as --flag VALUE and --flag=VALUE, a value that starts with a dash too" do
      expect(parse("-m", "hi", "a")).to eq(ids: ["a"], images: [], message: "hi")
      expect(parse("--message", "hi", "a", "b")).to eq(ids: %w[a b], images: [], message: "hi")
      expect(parse("--message=hi\nthere", "a")).to eq(ids: ["a"], images: [], message: "hi\nthere")
      expect(parse("-m", "--new", "a")).to eq(ids: ["a"], images: [], message: "--new")
      expect(parse("--image", "x.png", "--image=y.png", "-m", "t", "a")).to eq(ids: ["a"], images: %w[x.png y.png], message: "t")
      expect(parse("--wait", "--timeout", "5", "a")).to eq(ids: ["a"], images: [], wait: true, timeout: 5.0)
      expect(parse("--wait", "--timeout=2.5", "a")).to eq(ids: ["a"], images: [], wait: true, timeout: 2.5)
      expect(parse("--new", "--dir", tmpdir, "--model", "m")).to eq(ids: [], images: [], new: true, dir: tmpdir, model: "m")
      expect(parse("--new", "--dir=#{tmpdir}", "--model=m")).to eq(ids: [], images: [], new: true, dir: tmpdir, model: "m")
    end

    it "prints its usage for -h, --help and help, wherever they come" do
      [["-h"], ["--help"], ["help"], %w[a help], %w[-m x --help --bogus]].each do |argv|
        out.truncate(0)
        out.rewind
        expect(command(*argv).run).to eq(0), argv.inspect
        expect(out.string).to eq(Samagotchi::SendCommand::USAGE)
      end
      expect(parse("-m", "help", "a")).to eq(ids: ["a"], images: [], message: "help")
    end

    it "refuses each usage error with its line and the usage, exit 2" do
      too_many = (Samagotchi::SendCommand::MAX_IMAGES + 1).times.flat_map { |i| ["--image", "#{i}.png"] }
      {
        %w[--bogus] => "unknown option --bogus", %w[-x] => "unknown option -x", %w[-] => "unknown option -",
        %w[--new=1] => "unknown option --new=1", %w[--wait=1] => "unknown option --wait=1",
        %w[-m] => "-m needs a value", %w[--message] => "--message needs a value", %w[--dir] => "--dir needs a value",
        %w[--model] => "--model needs a value", %w[--image] => "--image needs a value",
        %w[--timeout] => "--timeout needs a value",
        %w[--all] => "there is no --all: name the sessions", %w[--all --bogus] => "there is no --all: name the sessions",
        %w[--bogus --all] => "unknown option --bogus",
        %w[--timeout 5 a] => "--timeout needs --wait", %w[--wait --timeout x a] => "--timeout takes seconds",
        %w[--wait --timeout 0 a] => "--timeout takes seconds", %w[--wait a b] => "--wait takes one session",
        [*too_many, "a"] => "at most #{Samagotchi::SendCommand::MAX_IMAGES} images",
        %w[--dir d a] => "--dir needs --new", %w[--model m a] => "--model needs --new",
        %w[--new a] => "--new takes no session ids: it starts one session",
        %w[--new --dir /no/such/folder-xyz] => "no folder /no/such/folder-xyz", %w[-m x] => "give session ids"
      }.each do |argv, message|
        err.truncate(0)
        err.rewind
        expect(command(*argv).run).to eq(2), argv.inspect
        expect(err.string).to eq(usage(message)), argv.inspect
      end
    end
  end

  describe "chi note" do
    def command(*argv) = Samagotchi::NoteCommand.new(argv, stdin: StringIO.new(""), stdout: out, stderr: err, state_dir: tmpdir)
    def parse(*argv) = command(*argv).send(:parse)

    it "takes each flag as --flag VALUE and --flag=VALUE, a value that starts with a dash too" do
      expect(parse("--source", "s", "a")).to eq(source: "s", ids: ["a"])
      expect(parse("--source=s", "a")).to eq(source: "s", ids: ["a"])
      expect(parse("-m", "t", "a")).to eq(source: "cli", ids: ["a"], text: "t")
      expect(parse("--message", "t", "a")).to eq(source: "cli", ids: ["a"], text: "t")
      expect(parse("--message=t\nu", "a", "b")).to eq(source: "cli", ids: %w[a b], text: "t\nu")
      expect(parse("--all")).to eq(source: "cli", ids: [], all: true)
      expect(parse("-m", "--all", "a")).to eq(source: "cli", ids: ["a"], text: "--all")
    end

    it "prints its usage for -h, --help and help, wherever they come" do
      [["-h"], ["--help"], ["help"], %w[a help]].each do |argv|
        out.truncate(0)
        out.rewind
        expect(command(*argv).run).to eq(0), argv.inspect
        expect(out.string).to eq(Samagotchi::NoteCommand::USAGE)
      end
    end

    it "refuses each usage error with its line and the usage, exit 2" do
      {
        %w[--bogus] => "unknown option --bogus", %w[-x] => "unknown option -x", %w[--all=1] => "unknown option --all=1",
        %w[--source] => "--source needs a value", %w[-m] => "-m needs a value", %w[--message] => "--message needs a value",
        [] => "give session ids or --all", %w[--all a] => "--all takes no ids"
      }.each do |argv, message|
        err.truncate(0)
        err.rewind
        expect(command(*argv).run).to eq(2), argv.inspect
        expect(err.string).to eq("chi note: #{message}\n#{Samagotchi::NoteCommand::USAGE}"), argv.inspect
      end
    end
  end

  describe "chi bootstrap" do
    def command(*argv)
      Samagotchi::BootstrapCommand.new(argv, stdin: StringIO.new(""), stdout: out, stderr: err, env: {},
                                             probe: instance_double(Samagotchi::Bootstrap::Probe),
                                             config_path: File.join(tmpdir, "config.yml"),
                                             bundles: instance_double(Samagotchi::Bootstrap::Bundles))
    end

    def parse(*argv) = command(*argv).send(:parse)

    it "takes each flag as --flag VALUE and --flag=VALUE, a value that starts with a dash too" do
      expect(parse("h:1", "--name", "n", "--model", "m", "--key-env", "K", "--no-test", "--dry-run"))
        .to eq(target: "h:1", name: "n", model: "m", key_env: "K", no_test: true, dry_run: true)
      expect(parse("--name=n", "--model=m", "--key-env=K")).to eq(name: "n", model: "m", key_env: "K")
      expect(parse("--name", "--dry-run")).to eq(name: "--dry-run")
    end

    it "prints its usage for -h, --help and help" do
      [["-h"], ["--help"], ["help"], %w[h:1 help]].each do |argv|
        out.truncate(0)
        out.rewind
        expect(command(*argv).run).to eq(0), argv.inspect
        expect(out.string).to eq(Samagotchi::BootstrapCommand::USAGE)
      end
    end

    it "refuses each usage error with its line and a --help hint, exit 2" do
      {
        %w[--bogus] => "unknown option --bogus", %w[-x] => "unknown option -x", %w[--no-test=1] => "unknown option --no-test=1",
        %w[--name] => "--name needs a value", %w[--model] => "--model needs a value", %w[--key-env] => "--key-env needs a value",
        %w[a b] => "one TARGET only (got a and b)",
        %w[--key-env sk-123] => "--key-env takes the variable's name (e.g. OPENROUTER_API_KEY), not the key"
      }.each do |argv, message|
        err.truncate(0)
        err.rewind
        expect(command(*argv).run).to eq(2), argv.inspect
        expect(err.string).to eq("chi bootstrap: #{message} (see chi bootstrap --help)\n"), argv.inspect
      end
    end
  end

  describe "chi update" do
    def command(*argv) = Samagotchi::UpdateCommand.new(argv, stdout: out, stderr: err, gem_spec: nil, web: ["127.0.0.1", 1])
    def parse(*argv) = command(*argv).send(:parse)

    it "takes its switches, the hidden --gem-from VERSION, and help anywhere without stopping" do
      expect(parse("--dry-run", "--no-gem", "--no-bundles", "--no-desktop", "--no-register"))
        .to eq(dry_run: true, no_gem: true, no_bundles: true, no_desktop: true, no_register: true)
      expect(parse("--gem-from", "0.1.0")).to eq(gem_from: "0.1.0")
      expect(parse("--gem-from", "--dry-run")).to eq(gem_from: "--dry-run")
      expect(parse("--help", "--dry-run")).to eq(help: true, dry_run: true)
      expect(parse("-h")).to eq(help: true)
      expect(parse("help")).to eq(help: true)
    end

    it "refuses anything else as an unknown option with the usage, exit 2" do
      [%w[--frob], %w[foo], %w[--gem-from], %w[--dry-run=1], %w[--help --frob], %w[-x]].each do |argv|
        err.truncate(0)
        err.rewind
        expect(command(*argv).run).to eq(2), argv.inspect
        expect(err.string).to eq("chi update: unknown option #{(argv - ["--help"]).first}\n#{Samagotchi::UpdateCommand::USAGE}"), argv.inspect
      end
    end
  end

  describe "chi desktop" do
    def command(*argv) = Samagotchi::DesktopCommand.new(argv, stdout: out, stderr: err, platform: ->(register:) { raise "not here" }, supported: true)

    it "takes --force and --login on install only, and the hidden --no-register" do
      expect(Samagotchi::DesktopCommand.new(%w[--force --login --no-register], stdout: out, stderr: err).send(:parse, "install"))
        .to eq(force: true, login: true, no_register: true)
      expect(Samagotchi::DesktopCommand.new(%w[--no-register], stdout: out, stderr: err).send(:parse, "status"))
        .to eq(no_register: true)
    end

    it "refuses anything else as an unknown option with the usage, exit 2" do
      [%w[install --bogus], %w[upgrade --force], %w[install foo], %w[install --help], %w[install --force=1]].each do |argv|
        err.truncate(0)
        err.rewind
        expect(command(*argv).run).to eq(2), argv.inspect
        expect(err.string).to eq("chi desktop: unknown option #{argv[1]}\n#{Samagotchi::DesktopCommand::USAGE}"), argv.inspect
      end
    end
  end

  describe "chi sessions delete" do
    def command(*argv) = Samagotchi::SessionDeleteCommand.new(argv, stdout: out, stderr: err, state_dir: tmpdir)
    def parse(*argv) = command(*argv).send(:parse)

    it "takes -f and --force" do
      expect(parse("-f", "a")).to eq(ids: ["a"], force: true)
      expect(parse("a", "--force", "b")).to eq(ids: %w[a b], force: true)
      expect(parse("a")).to eq(ids: ["a"], force: false)
    end

    it "prints its usage for -h, --help and help, wherever they come" do
      [["-h"], ["--help"], ["help"], %w[a help]].each do |argv|
        out.truncate(0)
        out.rewind
        expect(command(*argv).run).to eq(0), argv.inspect
        expect(out.string).to eq(Samagotchi::SessionDeleteCommand::USAGE)
      end
    end

    it "refuses each usage error with its line and the usage, exit 2" do
      { %w[--bogus] => "unknown option --bogus", %w[-x] => "unknown option -x", %w[--force=1] => "unknown option --force=1",
        [] => "give session ids" }.each do |argv, message|
        err.truncate(0)
        err.rewind
        expect(command(*argv).run).to eq(2), argv.inspect
        expect(err.string).to eq("chi sessions delete: #{message}\n#{Samagotchi::SessionDeleteCommand::USAGE}"), argv.inspect
      end
    end
  end

  describe "chi bundle" do
    let(:source) { File.expand_path("fixtures/sample_hooks_bundle", __dir__) }
    let(:installers) { [] }
    let(:builders) { [] }

    before do
      allow(Samagotchi::MemoryBundle::Installer).to receive(:new) do |**kwargs|
        installers << kwargs
        instance_double(Samagotchi::MemoryBundle::Installer, run: [nil, nil], summary: "S", conflicts: {})
      end
      allow(Samagotchi::MemoryBundle::Builder).to receive(:new) do |**kwargs|
        builders << kwargs
        instance_double(Samagotchi::MemoryBundle::Builder,
                        run: { files: [], out_path: "o", name: "n", version: "v", scope: "system", placeholder_warnings: [] })
      end
    end

    def run(*argv) = Samagotchi::BundleCommand.new(argv, stdin: StringIO.new(""), stdout: out, stderr: err).run

    it "install/upgrade take --scope V (V may start with --), --scope=V and their switches; the last positional is the source" do
      allow_any_instance_of(Samagotchi::MemoryBundle::Provenance).to receive(:installed?).and_return(true)

      expect(run("install", source, "--scope", "project", "--force")).to eq(0)
      expect(run("install", "--scope=project", "nope", source)).to eq(0)
      expect(run("install", "--scope", "--force", source)).to eq(0)
      expect(run("upgrade", source, "--force", "--dry-run", "--agent")).to eq(0)
      expect(run("upgrade", source, "--no-agent", "--dry-run")).to eq(0)
      expect(installers.map { |k| k.values_at(:source, :scope, :force, :dry_run) })
        .to eq([[source, "project", true, nil], [source, "project", false, nil], [source, "--force", false, nil],
                [source, nil, true, true], [source, nil, false, true]])
    end

    it "install/upgrade/uninstall: --help only, first one wins; an unknown --flag or a --flag=V switch exits 2" do
      expect(run("install", source, "--help", "--bogus")).to eq(0)
      expect(out.string).to eq(Samagotchi::BundleCommand::INSTALL_HELP)
      { %w[install --force=1] => "Unknown bundle install flag: --force=1", %w[install --bogus --help] => "Unknown bundle install flag: --bogus",
        %w[upgrade --agent=1] => "Unknown bundle upgrade flag: --agent=1", %w[upgrade --scope] => "Unknown bundle upgrade flag: --scope",
        %w[uninstall --dry-run] => "Unknown bundle uninstall flag: --dry-run" }.each do |argv, line|
        err.truncate(0)
        err.rewind
        expect(run(*argv)).to eq(2), argv.inspect
        expect(err.string).to eq("#{line}\n"), argv.inspect
      end
      expect(installers).to be_empty
    end

    it "build takes --flag V (V not starting with --) and --flag=V; other words are the files" do
      expect(run("build", "--scope", "project", "--name", "n", "--version", "1", "--description", "d", "--out", "o", "a.md", "-x", "help")).to eq(0)
      expect(run("build", "--scope=system", "--name=n", "--version=1", "--description=d e", "--out=o=1")).to eq(0)
      expect(run("build", "--name", "-x", "--description=")).to eq(0)
      expect(run("build")).to eq(0)
      expect(builders).to eq([
        { scope: "project", name: "n", version: "1", description: "d", out: "o", files: %w[a.md -x help] },
        { scope: "system", name: "n", version: "1", description: "d e", out: "o=1", files: nil },
        { scope: nil, name: "-x", version: nil, description: "", out: nil, files: nil },
        { scope: nil, name: nil, version: nil, description: "", out: nil, files: nil }
      ])
    end

    it "build: --help first wins; an unknown flag, a value flag without its value and a bad scope exit 2" do
      expect(run("build", "--help", "--bogus")).to eq(0)
      expect(out.string).to start_with("Usage: chi bundle build [--scope system|project]")
      { %w[build --bogus] => "Unknown bundle build flag: --bogus", %w[build --name --out x] => "Unknown bundle build flag: --name",
        %w[build --out] => "Unknown bundle build flag: --out", %w[build --scope bogus] => "Invalid scope 'bogus', expected system or project",
        %w[build --scope=] => "Invalid scope '', expected system or project" }.each do |argv, line|
        err.truncate(0)
        err.rewind
        expect(run(*argv)).to eq(2), argv.inspect
        expect(err.string).to eq("#{line}\n"), argv.inspect
      end
      expect(builders).to be_empty
    end
  end
end
