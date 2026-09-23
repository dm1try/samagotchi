# frozen_string_literal: true

require "json"
require "tmpdir"
require "spec_helper"
require "samagotchi/desktop"

RSpec.describe Samagotchi::Desktop::MacOS do
  # Records every command; answers from a table keyed by the program name.
  class DesktopFakeRunner
    attr_reader :calls

    def initialize(answers = {}, &on_call)
      @answers = answers
      @calls = []
      @on_call = on_call
    end

    # The compile goes through xcrun; call it "swiftc" here.
    def self.name_of(argv)
      argv[0] == "xcrun" && argv.include?("swiftc") && !argv.include?("--find") ? "swiftc" : File.basename(argv[0])
    end

    def run(argv)
      @calls << argv
      @on_call&.call(argv)
      answer = @answers[self.class.name_of(argv)] || @answers[argv[0]]
      answer = answer.call(argv) if answer.respond_to?(:call)
      answer || ["", true]
    end

    def programs = @calls.map { |argv| self.class.name_of(argv) }
  end

  let(:tmp) { Dir.mktmpdir("desktop-macos") }
  let(:app_dir) { File.join(tmp, "Applications") }
  let(:support_dir) { File.join(tmp, "Support", "Chi Helper") }
  let(:sources_dir) { File.join(tmp, "src").tap { |d| FileUtils.mkdir_p(d) } }
  let(:source_dir) { File.join(tmp, "chi").tap { |d| FileUtils.mkdir_p(File.join(d, ".git")) } }
  let(:env) { { "HOME" => tmp } }
  # swiftc "compiles" by writing the -o file, so the build looks real.
  let(:runner) do
    DesktopFakeRunner.new("xcrun" => ["/usr/bin/swiftc\n", true]) do |argv|
      if DesktopFakeRunner.name_of(argv) == "swiftc"
        out = argv[argv.index("-o") + 1]
        FileUtils.mkdir_p(File.dirname(out))
        File.write(out, "binary")
      end
    end
  end
  let(:register) { true }

  subject(:macos) do
    described_class.new(app_dir: app_dir, support_dir: support_dir, env: env, runner: runner,
                        source_dir: source_dir, ruby: "/opt/ruby/bin/ruby", version: "9.9.9",
                        arch: "arm64", sources_dir: sources_dir, register: register)
  end

  before do
    File.write(File.join(sources_dir, "App.swift"), "// app")
    File.write(File.join(sources_dir, "Panel.swift"), "// panel")
  end

  after { FileUtils.remove_entry(tmp) }

  let(:app) { File.join(app_dir, "Chi Helper.app") }
  let(:launch_file) { File.join(support_dir, "launch.json") }

  describe "#launch_config" do
    it "runs this chi's bin/chi with the absolute ruby and the version" do
      config = macos.launch_config
      expect(config["argv"]).to eq(["/opt/ruby/bin/ruby", File.join(source_dir, "bin", "chi")])
      expect(config["version"]).to eq("9.9.9")
    end

    it "copies only the allowlisted variables that are set, and always LANG" do
      env.merge!("XDG_STATE_HOME" => "/s", "GEM_HOME" => "/g", "GITHUB_TOKEN" => "secret",
                 "SAMAGOTCHI_ENV" => "test", "OPENROUTER_API_KEY" => "k", "LANG" => "C",
                 "BUNDLE_GEMFILE" => "/x/Gemfile", "XDG_DATA_HOME" => "/d")
      expect(macos.launch_config["env"]).to eq("LANG" => "en_US.UTF-8", "XDG_STATE_HOME" => "/s", "GEM_HOME" => "/g")
    end

    it "leaves out allowlisted variables set to an empty string" do
      env["GEM_PATH"] = ""
      expect(macos.launch_config["env"]).to eq("LANG" => "en_US.UTF-8")
    end
  end

  describe "#warnings" do
    it "says nothing for a main checkout" do
      expect(macos.warnings).to eq([])
    end

    it "warns when chi runs from a linked git worktree, which goes stale when removed" do
      FileUtils.rm_rf(File.join(source_dir, ".git"))
      File.write(File.join(source_dir, ".git"), "gitdir: /repo/.git/worktrees/x\n")
      expect(macos.warnings.join).to include("linked git worktree", source_dir)
    end
  end

  describe "#info_plist" do
    it "names the app, the version and the Service" do
      plist = macos.info_plist
      expect(plist).to include("<string>dev.samagotchi.chi-helper</string>", "<string>ChiHelper</string>",
                               "<string>9.9.9</string>", "<string>sendToChi</string>",
                               "<string>public.utf8-plain-text</string>", "<string>Send to chi</string>")
      expect(plist).to match(%r{<key>LSUIElement</key>\s*<true/>})
      expect(plist).to match(%r{<key>NSRequiredContext</key>\s*<dict/>})
    end
  end

  describe "#install" do
    it "checks the toolchain, compiles the sources, signs, writes the launch file and registers" do
      lines = []
      macos.install { |line| lines << line }

      # Through xcrun: a bare swiftc path finds no SDK ("unable to load standard library").
      swiftc = runner.calls.find { |argv| DesktopFakeRunner.name_of(argv) == "swiftc" }
      expect(swiftc).to start_with("xcrun", "--sdk", "macosx", "swiftc", "-O", "-swift-version", "5", "-target", "arm64-apple-macos13", "-parse-as-library")
      expect(swiftc).to include(File.join(sources_dir, "App.swift"), File.join(sources_dir, "Panel.swift"))
      expect(swiftc.last).to end_with(".chi-helper-build/Contents/MacOS/ChiHelper")
      expect(runner.calls).to include(["codesign", "--force", "--sign", "-", File.join(app_dir, ".chi-helper-build")])
      expect(runner.calls).to include([described_class::PBS, "-update"], [described_class::LSREGISTER, "-f", app],
                                      ["open", "-g", app])
      expect(runner.programs.first).to eq("xcrun")

      expect(File.read(File.join(app, "Contents", "MacOS", "ChiHelper"))).to eq("binary")
      expect(File.read(File.join(app, "Contents", "Info.plist"))).to include("9.9.9")
      expect(Dir.children(app_dir)).to eq(["Chi Helper.app"])
      expect(JSON.parse(File.read(launch_file))["argv"]).to eq(["/opt/ruby/bin/ruby", File.join(source_dir, "bin", "chi")])
      expect(lines.join("\n")).to include("building", "installed")
    end

    it "refuses an existing copy without --force, touching nothing" do
      macos.install
      runner.calls.clear
      expect { macos.install }.to raise_error(described_class::Error, /already installed \(9\.9\.9\); use chi desktop upgrade/)
      expect(runner.calls).to be_empty
    end

    it "with no Command Line Tools says how to get them and writes nothing" do
      runner = DesktopFakeRunner.new("xcrun" => ["xcrun: error: unable to find utility", false])
      macos = described_class.new(app_dir: app_dir, support_dir: support_dir, env: env, runner: runner,
                                  source_dir: source_dir, sources_dir: sources_dir, arch: "arm64")
      expect { macos.install }.to raise_error(described_class::Error, /xcode-select --install/)
      expect(runner.programs).to eq(["xcrun"])
      expect(File.exist?(app_dir)).to be(false)
      expect(File.exist?(support_dir)).to be(false)
    end

    it "keeps the old app and launch file when the build fails, and cleans up the build dir" do
      macos.install
      old_launch = File.read(launch_file)
      failing = DesktopFakeRunner.new("xcrun" => ["/usr/bin/swiftc\n", true], "swiftc" => ["App.swift:1: error: nope", false])
      macos2 = described_class.new(app_dir: app_dir, support_dir: support_dir, env: env.merge("XDG_STATE_HOME" => "/new"),
                                   runner: failing, source_dir: source_dir, version: "10.0.0", arch: "arm64",
                                   sources_dir: sources_dir)
      expect { macos2.install(force: true) }.to raise_error(described_class::Error, /App.swift:1: error: nope/)
      expect(File.read(File.join(app, "Contents", "Info.plist"))).to include("9.9.9")
      expect(File.read(launch_file)).to eq(old_launch)
      expect(Dir.children(app_dir)).to eq(["Chi Helper.app"])
    end

    it "with --no-register runs no pbs, lsregister, open or pkill" do
      no_reg = described_class.new(app_dir: app_dir, support_dir: support_dir, env: env, runner: runner,
                                   source_dir: source_dir, arch: "arm64", sources_dir: sources_dir, register: false)
      no_reg.install
      expect(runner.programs).to eq(%w[xcrun swiftc codesign])
    end
  end

  describe "#swap_in" do
    it "puts the new build in place and removes the old copy" do
      FileUtils.mkdir_p(File.join(app, "Contents"))
      File.write(File.join(app, "Contents", "old"), "")
      build = File.join(app_dir, ".chi-helper-build")
      FileUtils.mkdir_p(File.join(build, "Contents"))
      File.write(File.join(build, "Contents", "new"), "")
      macos.swap_in(build)
      expect(Dir.children(File.join(app, "Contents"))).to eq(["new"])
      expect(Dir.children(app_dir)).to eq(["Chi Helper.app"])
    end

    it "rolls back to the old copy when the second rename fails" do
      FileUtils.mkdir_p(File.join(app, "Contents"))
      File.write(File.join(app, "Contents", "old"), "")
      build = File.join(app_dir, ".chi-helper-build")
      FileUtils.mkdir_p(build)
      allow(File).to receive(:rename).and_call_original
      allow(File).to receive(:rename).with(build, app).and_raise(Errno::EACCES)
      expect { macos.swap_in(build) }.to raise_error(Errno::EACCES)
      expect(Dir.children(File.join(app, "Contents"))).to eq(["old"])
    end
  end

  describe "#upgrade" do
    it "quits the running helper, installs over it and starts it again" do
      macos.install
      runner.calls.clear
      macos.upgrade
      expect(runner.calls.first).to eq(%w[pkill -x ChiHelper])
      expect(runner.calls.last).to eq(["open", "-g", app])
    end

    it "installs when nothing is there yet" do
      macos.upgrade
      expect(File.directory?(app)).to be(true)
    end
  end

  describe "#uninstall" do
    it "quits the app, removes it, its support dir and defaults, and refreshes Services" do
      macos.install
      runner.calls.clear
      expect(macos.uninstall).to be(true)
      expect(File.exist?(app)).to be(false)
      expect(File.exist?(support_dir)).to be(false)
      expect(runner.calls).to eq([%w[pkill -x ChiHelper], %w[defaults delete dev.samagotchi.chi-helper],
                                  [described_class::PBS, "-update"]])
    end

    it "says so when nothing is installed" do
      expect(macos.uninstall).to be(false)
    end
  end

  describe "#status" do
    it "reports not installed" do
      expect(macos.status).to include(installed: false, chi_version: "9.9.9")
    end

    it "reports the app version, launch file, baked dirs, Service and running state" do
      env["XDG_STATE_HOME"] = "/state"
      macos.install
      dump = "{ NSBundleIdentifier = \"dev.samagotchi.chi-helper\"; }"
      status_runner = DesktopFakeRunner.new(described_class::PBS => [dump, true], "pgrep" => ["123\n", true])
      status = described_class.new(app_dir: app_dir, support_dir: support_dir, env: env, runner: status_runner,
                                   source_dir: source_dir, version: "9.9.10", sources_dir: sources_dir).status
      expect(status).to include(installed: true, app_version: "9.9.9", chi_version: "9.9.10",
                                launch_argv: ["/opt/ruby/bin/ruby", File.join(source_dir, "bin", "chi")],
                                launch_ok: false, baked_dirs: { "XDG_STATE_HOME" => "/state" },
                                service: true, running: true)
    end

    it "says the launch file still works when its ruby and bin/chi exist" do
      ruby = File.join(tmp, "ruby")
      File.write(ruby, "")
      FileUtils.mkdir_p(File.join(source_dir, "bin"))
      File.write(File.join(source_dir, "bin", "chi"), "")
      described_class.new(app_dir: app_dir, support_dir: support_dir, env: env, runner: runner, source_dir: source_dir,
                          ruby: ruby, arch: "arm64", sources_dir: sources_dir).install
      expect(macos.status[:launch_ok]).to be(true)
    end
  end
end
