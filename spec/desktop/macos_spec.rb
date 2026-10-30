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

  subject(:macos) do
    described_class.new(app_dir: app_dir, support_dir: support_dir, env: env, runner: runner,
                        source_dir: source_dir, ruby: "/opt/ruby/bin/ruby", version: "9.9.9",
                        arch: "arm64", sources_dir: sources_dir, register: register)
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
  let(:app) { File.join(app_dir, "Chi Helper.app") }
  let(:launch_file) { File.join(support_dir, "launch.json") }
  # open hands its env to the app: started through env -i, the app gets
  # launchd's bare one, as at login, not the install shell's.
  let(:open_app) { ["/usr/bin/env", "-i", "HOME=#{tmp}", "/usr/bin/open", "-g", app] }

  before do
    File.write(File.join(sources_dir, "App.swift"), "// app")
    File.write(File.join(sources_dir, "Panel.swift"), "// panel")
  end

  after { FileUtils.remove_entry(tmp) }

  describe ".path_dirs / .baked_path" do
    it "keeps only unique absolute PATH entries, in order" do
      path = "/a/bin::bin:./x:.:~/bin:/b/bin:/a/bin"
      expect(described_class.path_dirs("PATH" => path)).to eq(%w[/a/bin /b/bin])
      expect(described_class.baked_path("PATH" => path)).to eq("/a/bin:/b/bin")
    end

    it "has no baked PATH when no absolute entries are set" do
      expect(described_class.baked_path({})).to be_nil
      expect(described_class.baked_path("PATH" => "")).to be_nil
      expect(described_class.baked_path("PATH" => "rel:.:")).to be_nil
    end
  end

  describe "#launch_config" do
    it "runs this chi's bin/chi with the absolute ruby and the version" do
      config = macos.launch_config
      expect(config["argv"]).to eq(["/opt/ruby/bin/ruby", File.join(source_dir, "bin", "chi")])
      expect(config["version"]).to eq("9.9.9")
    end

    it "runs an installed gem's RubyGems wrapper, not the versioned bin/chi inside the gem" do
      base = File.join(tmp, "gems")
      FileUtils.mkdir_p(File.join(base, "bin"))
      File.write(File.join(base, "bin", "chi"), "")
      spec = Gem::Specification.new { |s| s.name = "samagotchi"; s.version = "9.9.9" }
      spec.loaded_from = File.join(base, "specifications", "samagotchi-9.9.9.gemspec")
      allow(spec).to receive(:full_gem_path).and_return(source_dir)
      allow(Gem).to receive(:loaded_specs).and_return("samagotchi" => spec)

      expect(macos.launch_config["argv"]).to eq(["/opt/ruby/bin/ruby", File.join(base, "bin", "chi")])
    end

    # Never RUBYLIB; GEM_HOME/GEM_PATH only for a [ruby, chi] argv (its wrapper may need them).
    it "copies only the allowlisted variables that are set, and always LANG" do
      env.merge!("XDG_STATE_HOME" => "/s", "XDG_CONFIG_HOME" => "/c", "GEM_HOME" => "/g", "GEM_PATH" => "/g:/h",
                 "RUBYLIB" => "/l", "GITHUB_TOKEN" => "secret", "SAMAGOTCHI_ENV" => "test", "OPENROUTER_API_KEY" => "k",
                 "LANG" => "C", "BUNDLE_GEMFILE" => "/x/Gemfile", "XDG_DATA_HOME" => "/d")
      expect(macos.launch_config["env"]).to eq("LANG" => "en_US.UTF-8", "XDG_STATE_HOME" => "/s", "XDG_CONFIG_HOME" => "/c",
                                               "GEM_HOME" => "/g", "GEM_PATH" => "/g:/h")
    end

    it "bakes a filtered PATH without adding tokens or runtime settings" do
      env.merge!("PATH" => "/a/bin::rel:/b/bin:/a/bin", "GITHUB_TOKEN" => "secret", "SAMAGOTCHI_ENV" => "test")
      baked = macos.launch_config["env"]
      expect(baked).to include("PATH" => "/a/bin:/b/bin")
      expect(baked.keys).not_to include("GITHUB_TOKEN", "SAMAGOTCHI_ENV")
    end

    it "leaves PATH out when it has no absolute entries" do
      env["PATH"] = "rel:."
      expect(macos.launch_config["env"]).not_to have_key("PATH")
    end

    # launchd starts the helper in /, where a relative dir means /rel.
    it "bakes a relative XDG_CONFIG_HOME / XDG_STATE_HOME made absolute from the install's cwd" do
      env.merge!("XDG_CONFIG_HOME" => "rel/config", "XDG_STATE_HOME" => "rel/state")
      Dir.chdir(tmp) do
        cwd = Dir.pwd
        expect(macos.launch_config["env"]).to include("XDG_CONFIG_HOME" => File.join(cwd, "rel/config"),
                                                      "XDG_STATE_HOME" => File.join(cwd, "rel/state"))
      end
    end

    it "leaves out allowlisted variables set to an empty string" do
      env["XDG_STATE_HOME"] = ""
      expect(macos.launch_config["env"]).to eq("LANG" => "en_US.UTF-8")
    end

    it "boots the chi home when there is one: its ruby, its gem path in the -e string, then --" do
      home = Samagotchi::ChiHome::Record.new(ruby: "/home/ruby", gem_home: "/home/gems", gem_path: "/home/gems",
                                             mise: nil, set_at: "t", set_by_version: "9.9.9")
      helper = described_class.new(app_dir: app_dir, support_dir: support_dir,
                                   env: env.merge("GEM_HOME" => "/g", "GEM_PATH" => "/g", "RUBYLIB" => "/l"),
                                   runner: runner, source_dir: source_dir, ruby: "/opt/ruby/bin/ruby", version: "9.9.9",
                                   arch: "arm64", sources_dir: sources_dir, chi_home: home)
      config = helper.launch_config
      expect(config["argv"]).to eq(["/home/ruby", "-e",
                                    "Gem.paths = {'GEM_HOME' => \"/home/gems\", 'GEM_PATH' => \"/home/gems\"}; " \
                                    "gem 'samagotchi', '>= 0.a'; load Gem.bin_path('samagotchi', 'chi')", "--"])
      expect(config["env"]).to eq("LANG" => "en_US.UTF-8")
    end
  end

  describe "#home_problem" do
    let(:home) do
      Samagotchi::ChiHome::Record.new(ruby: "/home/ruby", gem_home: "/home/gems", gem_path: "/home/gems",
                                      mise: nil, set_at: "t", set_by_version: "9.9.9")
    end

    def launch(argv, env = {})
      FileUtils.mkdir_p(support_dir)
      File.write(launch_file, JSON.generate("version" => "9.9.9", "argv" => argv, "env" => env))
    end

    it "is nil without a launch file and for one that boots the home as it is" do
      expect(macos.home_problem(home)).to be_nil
      launch(home.boot_argv(run: Samagotchi::ChiHome::CHI_BOOT) + ["--"], "LANG" => "en_US.UTF-8")
      expect(macos.home_problem(home)).to be_nil
    end

    it "says chi desktop upgrade for a [ruby, chi] argv, another home's boot, or baked GEM_*" do
      launch(["/opt/ruby/bin/ruby", "/opt/ruby/bin/chi"], "GEM_HOME" => "/g")
      expect(macos.home_problem(home))
        .to eq("the desktop helper runs /opt/ruby/bin/ruby /opt/ruby/bin/chi, not the chi home's boot: chi desktop upgrade")

      launch(home.with(gem_path: "/old/gems").boot_argv(run: Samagotchi::ChiHome::CHI_BOOT) + ["--"])
      expect(macos.home_problem(home)).to eq("the desktop helper boots the chi home as it was (/home/ruby), " \
                                             "not as it is now: chi desktop upgrade")

      launch(home.boot_argv(run: Samagotchi::ChiHome::CHI_BOOT) + ["--"], "GEM_HOME" => "/g", "GEM_PATH" => "/g")
      expect(macos.home_problem(home)).to eq("the desktop helper's launch file sets GEM_HOME, GEM_PATH for its " \
                                             "sessions' tools: chi desktop upgrade")
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

  describe "#host_keys" do
    let(:keychain) { Struct.new(:items) { def read(name) = items[name] }.new({ "FW_KEY" => "sk-keychain-1" }) }
    let(:config_home) { File.join(tmp, "helper-config") }

    before do
      Samagotchi::HostKeys.keychain = keychain
      FileUtils.mkdir_p(File.join(config_home, "samagotchi"))
      File.write(File.join(config_home, "samagotchi", "config.yml"), <<~YAML)
        hosts:
          fw: { url: "https://fw.test/v1", api: openai, api_key_env: FW_KEY }
          work: { url: "https://work.test/v1", api: openai, api_key_env: WORK_KEY }
          work2: { url: "https://work2.test/v1", api: openai, api_key_env: WORK_KEY }
          lab: { url: "https://lab.test/v1", api: openai, api_key_env: LAB_KEY }
          off: { url: "https://off.test/v1", api: openai, api_key_env: OFF_KEY, enabled: false }
          box: { host: 127.0.0.1, port: 8080 }
      YAML
      FileUtils.mkdir_p(support_dir)
      File.write(launch_file, JSON.generate("env" => { "XDG_CONFIG_HOME" => config_home }))
      env["WORK_KEY"] = "sk-shell-2"
    end

    it "reads the launch file's config: Keychain keys, keys only this shell has, unset ones; no disabled host" do
      expect(macos.host_keys).to eq([{ name: "FW_KEY", hosts: ["fw"], state: :keychain },
                                     { name: "WORK_KEY", hosts: %w[work work2], state: :shell_only },
                                     { name: "LAB_KEY", hosts: ["lab"], state: :unset }])
    end

    it "warns after an install about each key the helper won't get, never showing a key" do
      warnings = macos.warnings
      expect(warnings.size).to eq(2)
      expect(warnings[0]).to eq("WORK_KEY is set in this shell only: the helper's new sessions and model list won't reach " \
                                "host work, work2 until it is in the Keychain (security add-generic-password -s chi -a WORK_KEY -w)")
      expect(warnings[1]).to start_with("LAB_KEY is unset: ")
      expect(warnings.join).not_to include("sk-")
    end

    it "ignores the terminal's XDG_CONFIG_HOME when the launch file bakes none" do
      File.write(launch_file, JSON.generate("env" => {}))
      env["XDG_CONFIG_HOME"] = config_home
      expect(macos.host_keys).to eq([])
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

    it "offers the one Service for text, image data and image files (the user's shortcut is keyed by its name)" do
      plist = macos.info_plist
      expect(plist.scan("<key>NSMessage</key>").size).to eq(1)
      expect(plist).to match(%r{<key>NSSendTypes</key>\s*<array>\s*<string>public.utf8-plain-text</string>\s*
                                <string>public.png</string>\s*<string>public.tiff</string>\s*</array>}x)
      expect(plist).to match(%r{<key>NSSendFileTypes</key>\s*<array>\s*<string>public.image</string>\s*</array>})
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
                                      open_app)
      expect(runner.programs.first).to eq("xcrun")
      # The app registered first, so pbs reads the Service types it has now.
      expect(runner.calls.index([described_class::LSREGISTER, "-f", app]))
        .to be < runner.calls.index([described_class::PBS, "-update"])

      expect(File.read(File.join(app, "Contents", "MacOS", "ChiHelper"))).to eq("binary")
      expect(File.read(File.join(app, "Contents", "Info.plist"))).to include("9.9.9")
      expect(Dir.children(app_dir)).to eq(["Chi Helper.app"])
      expect(JSON.parse(File.read(launch_file))["argv"]).to eq(["/opt/ruby/bin/ruby", File.join(source_dir, "bin", "chi")])
      expect(lines.join("\n")).to include("building", "installed")
    end

    it "with --force over an existing copy quits the running helper before swapping" do
      macos.install
      runner.calls.clear
      macos.install(force: true)
      expect(runner.programs.index("pkill")).to be < runner.programs.index("codesign")
      expect(runner.calls.last).to eq(open_app)
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

  describe "login item" do
    let(:exe) { File.join(app, "Contents", "MacOS", "ChiHelper") }

    it "install --login asks the app to register itself at login" do
      macos.install(login: true)
      expect(runner.calls).to include([exe, "--login", "on"])
    end

    it "install without --login leaves the login item alone" do
      macos.install
      expect(runner.calls.map(&:first)).not_to include(exe)
    end

    it "upgrade keeps a login item that was on" do
      macos.install
      runner = DesktopFakeRunner.new("xcrun" => ["", true], "ChiHelper" => ->(argv) { argv.last == "status" ? ["enabled\n", true] : nil }) do |argv|
        if DesktopFakeRunner.name_of(argv) == "swiftc"
          out = argv[argv.index("-o") + 1]
          FileUtils.mkdir_p(File.dirname(out))
          File.write(out, "binary")
        end
      end
      described_class.new(app_dir: app_dir, support_dir: support_dir, env: env, runner: runner, source_dir: source_dir,
                          arch: "arm64", sources_dir: sources_dir).upgrade
      expect(runner.calls.first).to eq([exe, "--login", "status"])
      expect(runner.calls).to include([exe, "--login", "on"])
    end

    it "uninstall turns the login item off before removing the app" do
      macos.install
      runner.calls.clear
      macos.uninstall
      expect(runner.calls.first(2)).to eq([[exe, "--login", "off"], %w[pkill -x ChiHelper]])
    end

    it "--no-register never touches the login item" do
      no_reg = described_class.new(app_dir: app_dir, support_dir: support_dir, env: env, runner: runner,
                                   source_dir: source_dir, arch: "arm64", sources_dir: sources_dir, register: false)
      no_reg.install(login: true)
      no_reg.uninstall
      expect(runner.calls.map(&:first)).not_to include(exe)
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
      expect(runner.calls.first).to eq([File.join(app, "Contents", "MacOS", "ChiHelper"), "--login", "status"])
      expect(runner.programs.index("pkill")).to be < runner.programs.index("codesign")
      expect(runner.calls.last).to eq(open_app)
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
      expect(runner.calls).to eq([[File.join(app, "Contents", "MacOS", "ChiHelper"), "--login", "off"],
                                  %w[pkill -x ChiHelper], %w[defaults delete dev.samagotchi.chi-helper],
                                  [described_class::PBS, "-update"]])
    end

    it "says so when nothing is installed" do
      expect(macos.uninstall).to be(false)
    end
  end

  describe "#stale? and the launch file refresh" do
    before do
      File.write(File.join(tmp, "ruby"), "")
      FileUtils.mkdir_p(File.join(source_dir, "bin"))
      File.write(File.join(source_dir, "bin", "chi"), "")
    end

    def helper(version: "9.9.9", env: self.env, ruby: File.join(tmp, "ruby"))
      described_class.new(app_dir: app_dir, support_dir: support_dir, env: env, runner: runner, source_dir: source_dir,
                          ruby: ruby, version: version, arch: "arm64", sources_dir: sources_dir)
    end

    def launch_json = JSON.parse(File.read(launch_file))
    def edit_launch(&) = File.write(launch_file, JSON.generate(launch_json.tap(&)))

    it "records the sources' digest; a new version with the same sources isn't stale, only its launch file is outdated" do
      helper.install
      expect(JSON.parse(File.read(launch_file))["sources_sha"]).to eq(helper.sources_sha)
      expect(helper.stale?).to be(false)
      expect(helper.launch_outdated?).to be(false)

      newer = helper(version: "9.9.10", env: env.merge("XDG_STATE_HOME" => "/elsewhere"))
      expect(newer.stale?).to be(false)
      expect(newer.launch_outdated?).to be(true)

      runner.calls.clear
      newer.refresh_launch_file
      expect(runner.calls).to be_empty
      launch = JSON.parse(File.read(launch_file))
      expect(launch["version"]).to eq("9.9.10")
      expect(launch["env"]).not_to include("XDG_STATE_HOME")
      expect(newer.launch_outdated?).to be(false)
      expect(newer.status).to include(stale: false, app_version: "9.9.9")
    end

    it "knows when the launch file names a newer chi than this one" do
      helper.install
      expect(helper.launch_version).to eq("9.9.9")
      expect(helper.launch_newer?).to be(false)
      expect(helper(version: "9.9.8").launch_newer?).to be(true)
      expect(helper(version: "9.9.10").launch_newer?).to be(false)
      edit_launch { |l| l.delete("version") }
      expect(helper(version: "9.9.8").launch_newer?).to be(false)
    end

    it "fills a missing PATH on refresh, keeping the installed env without rebuilding" do
      installed = helper(env: env.merge("PATH" => "/a", "XDG_STATE_HOME" => "/installed/state"))
      installed.install
      launch = JSON.parse(File.read(launch_file))
      launch["env"].delete("PATH")
      File.write(launch_file, JSON.generate(launch))
      refresher = helper(env: env.merge("PATH" => "/a"))
      expect(refresher.launch_outdated?).to be(true)

      runner.calls.clear
      refresher.refresh_launch_file

      expect(JSON.parse(File.read(launch_file))["env"]).to include("PATH" => "/a", "XDG_STATE_HOME" => "/installed/state")
      expect(refresher.launch_outdated?).to be(false)
      expect(runner.calls).to be_empty
    end

    it "keeps an existing PATH on refresh, even when this shell's PATH differs" do
      helper(env: env.merge("PATH" => "/a")).install
      different = helper(env: env.merge("PATH" => "/b"))
      expect(different.launch_outdated?).to be(false)

      newer = helper(version: "9.9.10", env: env.merge("PATH" => "/b"))
      newer.refresh_launch_file
      expect(JSON.parse(File.read(launch_file))["env"]["PATH"]).to eq("/a")

      without_path = helper(version: "9.9.10", env: env)
      expect(without_path.launch_outdated?).to be(false)
      without_path.refresh_launch_file
      expect(JSON.parse(File.read(launch_file))["env"]["PATH"]).to eq("/a")
    end

    it "does not mark a PATH-less shell outdated, including when the file has no PATH" do
      helper(env: env.merge("PATH" => "/a")).install
      expect(helper(env: env).launch_outdated?).to be(false)

      launch = JSON.parse(File.read(launch_file))
      launch["env"].delete("PATH")
      File.write(launch_file, JSON.generate(launch))
      expect(helper(env: env).launch_outdated?).to be(false)
    end

    it "lets install --force and a regular upgrade bake this shell's PATH" do
      helper(env: env.merge("PATH" => "/a")).install
      helper(env: env.merge("PATH" => "/b")).install(force: true)
      expect(JSON.parse(File.read(launch_file))["env"]["PATH"]).to eq("/b")

      helper(env: env.merge("PATH" => "/a")).install(force: true)
      helper(env: env.merge("PATH" => "/b")).upgrade
      expect(JSON.parse(File.read(launch_file))["env"]["PATH"]).to eq("/b")
    end

    it "can keep the old PATH on upgrade, or fill it when the old file has none" do
      helper(env: env.merge("PATH" => "/a")).install
      helper(env: env.merge("PATH" => "/b")).upgrade(keep_launch: true)
      expect(JSON.parse(File.read(launch_file))["env"]["PATH"]).to eq("/a")

      helper(env: env).install(force: true)
      helper(env: env.merge("PATH" => "/b")).upgrade(keep_launch: true)
      expect(JSON.parse(File.read(launch_file))["env"]["PATH"]).to eq("/b")
    end

    describe "the ruby and chi the helper runs" do
      let(:other_ruby) { File.join(tmp, "other-ruby").tap { |f| File.write(f, "") } }
      let(:argv) { [File.join(tmp, "ruby"), File.join(source_dir, "bin", "chi")] }

      before { helper.install }

      it "isn't outdated for another ruby, and a refresh keeps the file's argv" do
        other = helper(ruby: other_ruby)
        expect(other.launch_outdated?).to be(false)
        edit_launch { |l| l["broadcast_timeout"] = 1.0 }
        other.refresh_launch_file
        expect(launch_json["argv"]).to eq(argv)
      end

      it "leaves a file written by a newer chi alone, and refreshes one that names an older chi, keeping its argv" do
        edit_launch { |l| l["version"] = "9.9.10" }
        expect(helper.launch_outdated?).to be(false)

        edit_launch { |l| l["version"] = "9.9.8" }
        newer = helper(ruby: other_ruby)
        expect(newer.launch_outdated?).to be(true)
        newer.refresh_launch_file
        expect(launch_json).to include("version" => "9.9.9", "argv" => argv)
      end

      it "counts a missing or unreadable version as outdated" do
        edit_launch { |l| l.delete("version") }
        expect(helper.launch_outdated?).to be(true)
        edit_launch { |l| l["version"] = "not a version" }
        expect(helper.launch_outdated?).to be(true)
      end

      it "keeps a newer version when another setting makes a refresh from an older chi" do
        edit_launch { |l| l["version"] = "9.9.10" }
        older = described_class.new(app_dir: app_dir, support_dir: support_dir, env: env, runner: runner,
                                    source_dir: source_dir, ruby: other_ruby, version: "9.9.9", arch: "arm64",
                                    sources_dir: sources_dir, broadcast_timeout: 5.0)
        expect(older.launch_outdated?).to be(true)
        older.refresh_launch_file
        expect(launch_json).to include("version" => "9.9.10", "argv" => argv, "broadcast_timeout" => 5.0)
      end

      it "writes this chi's argv when the file has none" do
        edit_launch { |l| l.delete("argv") }
        helper(ruby: other_ruby).refresh_launch_file
        expect(launch_json["argv"]).to eq([other_ruby, File.join(source_dir, "bin", "chi")])
        edit_launch { |l| l["argv"] = [] }
        helper.refresh_launch_file
        expect(launch_json["argv"]).to eq(argv)
      end

      it "upgrade(keep_launch: true) keeps argv and PATH; install --force and upgrade bake this shell's" do
        edit_launch { |l| l["env"]["PATH"] = "/a" }
        kept = helper(ruby: other_ruby, env: env.merge("PATH" => "/b"))
        kept.upgrade(keep_launch: true)
        expect(launch_json).to include("argv" => argv)
        expect(launch_json["env"]["PATH"]).to eq("/a")

        kept.upgrade
        expect(launch_json["argv"]).to eq([other_ruby, File.join(source_dir, "bin", "chi")])
        expect(launch_json["env"]["PATH"]).to eq("/b")

        helper.install(force: true)
        expect(launch_json["argv"]).to eq(argv)
      end

      it "upgrade(keep_launch: true) writes this chi's argv when the file has none" do
        edit_launch { |l| l.delete("argv") }
        helper(ruby: other_ruby).upgrade(keep_launch: true)
        expect(launch_json["argv"]).to eq([other_ruby, File.join(source_dir, "bin", "chi")])
      end

      it "names a missing ruby or chi in launch_problem, and nothing otherwise" do
        expect(helper.launch_problem).to be_nil
        edit_launch { |l| l["argv"] = ["/gone/ruby", File.join(source_dir, "bin", "chi")] }
        expect(helper.launch_problem).to eq("chi not found at /gone/ruby: run chi desktop install --force " \
                                            "from the shell whose chi it should run")
        edit_launch { |l| l["argv"] = [] }
        expect(helper.launch_problem).to be_nil
      end

      it "needs an absolute ruby and strings only" do
        edit_launch { |l| l["argv"] = ["ruby", File.join(source_dir, "bin", "chi")] }
        expect(helper.launch_problem).to start_with("the launch file's ruby ruby isn't an absolute path")
        expect(helper.stale?).to be(true)
        edit_launch { |l| l["argv"] = [File.join(tmp, "ruby"), 3] }
        expect(helper.stale?).to be(true)
        expect(helper.launch_problem).to be_nil # a refresh writes this chi's argv
      end

      # home.json is the one the helper's chi reads: the launch file's
      # XDG_CONFIG_HOME, else the helper env's ~/.config.
      it "names the chi home's problem when the argv boots a home that can't run chi" do
        empty = File.join(tmp, "empty-gems").tap { |d| FileUtils.mkdir_p(d) }
        File.chmod(0o755, File.join(tmp, "ruby"))
        home = Samagotchi::ChiHome::Record.new(ruby: File.join(tmp, "ruby"), gem_home: empty, gem_path: empty, mise: nil,
                                               set_at: "t", set_by_version: "9.9.9")
        Samagotchi::ChiHome.write!(home, path: File.join(tmp, ".config", "samagotchi", "home.json"))
        edit_launch { |l| l["argv"] = [File.join(tmp, "ruby"), "-e", "Gem.paths = {}; gem 'samagotchi'", "--"] }
        expect(helper.launch_problem).to eq("the chi home it boots can't run chi (no samagotchi in the home's gems " \
                                            "(#{empty})): chi home doctor")
        expect(helper.stale?).to be(true)
      end

      it "reads the chi home from the config dir the launch file bakes, not this process's" do
        Dir.mktmpdir do |config|
          empty = File.join(tmp, "empty-gems").tap { |d| FileUtils.mkdir_p(d) }
          File.chmod(0o755, File.join(tmp, "ruby"))
          home = Samagotchi::ChiHome::Record.new(ruby: File.join(tmp, "ruby"), gem_home: empty, gem_path: empty, mise: nil,
                                                 set_at: "t", set_by_version: "9.9.9")
          Samagotchi::ChiHome.write!(home, path: File.join(config, "samagotchi", "home.json"))
          edit_launch { |l| l["argv"] = [File.join(tmp, "ruby"), "-e", "Gem.paths = {}; gem 'samagotchi'", "--"] }
          with_config_home(config) { expect(helper.launch_problem).to be_nil }

          edit_launch { |l| l["env"] = (l["env"] || {}).merge("XDG_CONFIG_HOME" => config) }
          expect(helper.launch_problem).to start_with("the chi home it boots can't run chi")
        end
      end

      # As ChiRunner.swift checks: "-e", the boot string and "--" are not paths.
      it "checks only the absolute paths of a chi home boot argv" do
        boot = [File.join(tmp, "ruby"), "-e", "Gem.paths = {}; gem 'samagotchi'", "--"]
        edit_launch { |l| l["argv"] = boot }
        expect(helper.launch_problem).to be_nil
        expect(helper.stale?).to be(false)

        edit_launch { |l| l["argv"] = ["/gone/ruby", *boot.drop(1)] }
        expect(helper.launch_problem).to start_with("chi not found at /gone/ruby:")
        expect(helper.stale?).to be(true)
      end

      it "drops GEM_* and RUBYLIB from the kept env on refresh once the argv boots the chi home" do
        boot = [File.join(tmp, "ruby"), "-e", "Gem.paths = {}; gem 'samagotchi'", "--"]
        edit_launch do |l|
          l["argv"] = boot
          l["version"] = "9.9.8"
          l["env"].merge!("GEM_HOME" => "/g", "GEM_PATH" => "/g", "RUBYLIB" => "/l", "XDG_STATE_HOME" => "/s")
        end
        helper.refresh_launch_file
        expect(launch_json["argv"]).to eq(boot)
        expect(launch_json["env"]).to include("XDG_STATE_HOME" => "/s")
        expect(launch_json["env"].keys).not_to include("GEM_HOME", "GEM_PATH", "RUBYLIB")
      end

      # The old wrapper finds its gem through them: chi desktop install --force or upgrade moves it to the boot.
      it "keeps GEM_HOME/GEM_PATH for an old [ruby, wrapper] argv, on refresh and on upgrade(keep_launch: true)" do
        edit_launch do |l|
          l["version"] = "9.9.8"
          l["env"].merge!("GEM_HOME" => "/g", "GEM_PATH" => "/g", "RUBYLIB" => "/l")
        end
        helper.refresh_launch_file
        expect(launch_json["argv"]).to eq(argv)
        expect(launch_json["env"]).to include("GEM_HOME" => "/g", "GEM_PATH" => "/g")
        expect(launch_json["env"]).not_to have_key("RUBYLIB")

        helper.upgrade(keep_launch: true)
        expect(launch_json["argv"]).to eq(argv)
        expect(launch_json["env"]).to include("GEM_HOME" => "/g", "GEM_PATH" => "/g")

        # Without a usable home the argv stays [ruby, chi], and so does its GEM_*: this shell's (none here).
        helper.upgrade
        expect(launch_json["argv"]).to eq(argv)
        expect(launch_json["env"].keys).not_to include("GEM_HOME", "GEM_PATH", "RUBYLIB")
        helper(env: env.merge("GEM_HOME" => "/shell")).upgrade
        expect(launch_json["env"]).to include("GEM_HOME" => "/shell")
      end

      it "moves to the home's boot on upgrade, without GEM_*; keep_launch over a home boot takes none either" do
        home = Samagotchi::ChiHome::Record.new(ruby: File.join(tmp, "ruby"), gem_home: "/hg", gem_path: "/hg", mise: nil,
                                               set_at: "t", set_by_version: "9.9.9")
        homed = described_class.new(app_dir: app_dir, support_dir: support_dir, env: env.merge("GEM_HOME" => "/shell"),
                                    runner: runner, source_dir: source_dir, ruby: File.join(tmp, "ruby"), version: "9.9.9",
                                    arch: "arm64", sources_dir: sources_dir, chi_home: home)
        homed.upgrade
        expect(launch_json["argv"][1]).to eq("-e")
        expect(launch_json["env"].keys).not_to include("GEM_HOME", "GEM_PATH")

        helper(env: env.merge("GEM_HOME" => "/shell")).upgrade(keep_launch: true)
        expect(launch_json["argv"][1]).to eq("-e")
        expect(launch_json["env"].keys).not_to include("GEM_HOME", "GEM_PATH")
      end
    end

    it "is stale when a Swift source changed, the launch file has no digest, or its ruby is gone" do
      helper.install
      File.write(File.join(sources_dir, "Panel.swift"), "// panel v2")
      expect(helper.stale?).to be(true)

      helper.install(force: true)
      expect(helper.stale?).to be(false)
      File.write(launch_file, JSON.generate(JSON.parse(File.read(launch_file)).except("sources_sha")))
      expect(helper.stale?).to be(true)

      helper.install(force: true)
      File.delete(File.join(tmp, "ruby"))
      expect(helper.stale?).to be(true)
    end

    it "is not stale when not installed" do
      expect(helper.stale?).to be(false)
    end
  end

  describe "kitty settings" do
    let(:kitty) { { "listen_on" => "unix:/tmp/kitty.${KITTY_PID}", "binary" => "/k/kitty", "agents" => %w[claude codex] } }

    before do
      File.write(File.join(tmp, "ruby"), "")
      FileUtils.mkdir_p(File.join(source_dir, "bin"))
      File.write(File.join(source_dir, "bin", "chi"), "")
    end

    def helper(kitty: nil)
      described_class.new(app_dir: app_dir, support_dir: support_dir, env: env, runner: runner, source_dir: source_dir,
                          ruby: File.join(tmp, "ruby"), version: "9.9.9", arch: "arm64", sources_dir: sources_dir,
                          terminals: { "kitty" => kitty }.compact)
    end

    it "leaves the launch file as it was without them, and writes a kitty section with them" do
      plain = described_class.new(app_dir: app_dir, support_dir: support_dir, env: env, runner: runner, source_dir: source_dir,
                                  ruby: File.join(tmp, "ruby"), version: "9.9.9", arch: "arm64", sources_dir: sources_dir)
      plain.install
      before = File.binread(launch_file)
      helper.install(force: true)
      expect(File.binread(launch_file)).to eq(before)
      expect(JSON.parse(before)).not_to have_key("kitty")

      helper(kitty: kitty).install(force: true)
      expect(JSON.parse(File.read(launch_file))["kitty"]).to eq(kitty)
    end

    it "writes the kitty section between sources_sha and broadcast_timeout, byte for byte" do
      made = described_class.new(app_dir: app_dir, support_dir: support_dir, env: env, runner: runner, source_dir: source_dir,
                                 ruby: File.join(tmp, "ruby"), version: "9.9.9", arch: "arm64", sources_dir: sources_dir,
                                 terminals: { "kitty" => kitty }, broadcast_timeout: 30.0)
      made.install
      expect(File.read(launch_file)).to eq(<<~JSON)
        {
          "version": "9.9.9",
          "argv": [
            "#{tmp}/ruby",
            "#{source_dir}/bin/chi"
          ],
          "env": {
            "LANG": "en_US.UTF-8"
          },
          "sources_sha": "#{made.sources_sha}",
          "kitty": {
            "listen_on": "unix:/tmp/kitty.${KITTY_PID}",
            "binary": "/k/kitty",
            "agents": [
              "claude",
              "codex"
            ]
          },
          "broadcast_timeout": 30.0
        }
      JSON
    end

    it "makes the launch file outdated when they change, and the refresh writes them without a rebuild" do
      helper.install
      expect(helper.launch_outdated?).to be(false)
      expect(helper(kitty: kitty).launch_outdated?).to be(true)

      helper(kitty: kitty).refresh_launch_file
      expect(helper(kitty: kitty).launch_outdated?).to be(false)
      changed = helper(kitty: kitty.merge("agents" => %w[claude]))
      expect(changed.launch_outdated?).to be(true)

      runner.calls.clear
      changed.refresh_launch_file
      expect(runner.calls).to be_empty
      expect(JSON.parse(File.read(launch_file))["kitty"]["agents"]).to eq(%w[claude])
      expect(helper.launch_outdated?).to be(true)
      helper.refresh_launch_file
      expect(JSON.parse(File.read(launch_file))).not_to have_key("kitty")
    end

    describe ".kitty_settings" do
      def settings(values)
        described_class.kitty_settings(->(key) { values.fetch(key) { Samagotchi::Config.find_by_key(key).default } })
      end

      it "is nil while kitty.listen_on is unset or blank" do
        expect(settings({})).to be_nil
        expect(settings("kitty.listen_on" => "  ")).to be_nil
      end

      it "takes listen_on, the binary and the agents, split on |" do
        expect(settings("kitty.listen_on" => "unix:/tmp/kitty.${KITTY_PID}")).to eq(
          "listen_on" => "unix:/tmp/kitty.${KITTY_PID}", "binary" => "/Applications/kitty.app/Contents/MacOS/kitty",
          "agents" => %w[claude codex gemini aider opencode cursor-agent amp goose]
        )
        expect(settings("kitty.listen_on" => "unix:/k", "kitty.agents" => "claude| codex |")["agents"]).to eq(%w[claude codex])
        expect(settings("kitty.listen_on" => "unix:/k", "kitty.agents" => "*")["agents"]).to eq(%w[*])
      end

      it "are the kitty entry of .terminal_settings, which leaves a terminal out while it is off" do
        get = ->(values) { ->(key) { values.fetch(key) { Samagotchi::Config.find_by_key(key).default } } }
        expect(described_class.terminal_settings(get.call({}))).to eq({})
        expect(described_class.terminal_settings(get.call("kitty.listen_on" => "unix:/k")))
          .to eq("kitty" => settings("kitty.listen_on" => "unix:/k"))
      end

      it "reach the helper from chi desktop and chi update (their default platforms)" do
        require "samagotchi/desktop_command"
        require "samagotchi/update_command"
        original = ENV["SAMAGOTCHI_KITTY_LISTEN_ON"]
        ENV["SAMAGOTCHI_KITTY_LISTEN_ON"] = "unix:/tmp/kitty.${KITTY_PID}"
        [Samagotchi::DesktopCommand.new([]), Samagotchi::UpdateCommand.new([], web: ["127.0.0.1", 1])].each do |command|
          made = command.instance_variable_get(:@platform).call(register: false)
          expect(made.launch_config["kitty"]).to include("listen_on" => "unix:/tmp/kitty.${KITTY_PID}")
        end
      ensure
        ENV["SAMAGOTCHI_KITTY_LISTEN_ON"] = original
      end

      it "reads a YAML list for agents from config.yml" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "samagotchi"))
          File.write(File.join(dir, "samagotchi", "config.yml"), "kitty:\n  listen_on: unix:/tmp/k\n  agents: [claude, codex]\n")
          original = ENV["XDG_CONFIG_HOME"]
          ENV["XDG_CONFIG_HOME"] = dir
          expect(described_class.kitty_settings).to include("listen_on" => "unix:/tmp/k", "agents" => %w[claude codex])
        ensure
          ENV["XDG_CONFIG_HOME"] = original
        end
      end
    end
  end

  describe "tmux settings" do
    let(:kitty) { { "listen_on" => "unix:/tmp/k", "binary" => "/k/kitty", "agents" => %w[claude] } }
    let(:tmux) { { "binary" => "/t/tmux", "socket_dir" => "/tmp/tmux-501", "agents" => %w[claude codex] } }

    before do
      File.write(File.join(tmp, "ruby"), "")
      FileUtils.mkdir_p(File.join(source_dir, "bin"))
      File.write(File.join(source_dir, "bin", "chi"), "")
    end

    def helper(terminals = {})
      described_class.new(app_dir: app_dir, support_dir: support_dir, env: env, runner: runner, source_dir: source_dir,
                          ruby: File.join(tmp, "ruby"), version: "9.9.9", arch: "arm64", sources_dir: sources_dir,
                          broadcast_timeout: 30.0, terminals: terminals)
    end

    it "writes a tmux section after kitty's, and before the broadcast timeout" do
      helper("tmux" => tmux, "kitty" => kitty).install
      launch = JSON.parse(File.read(launch_file))
      expect(launch.keys).to eq(%w[version argv env sources_sha kitty tmux broadcast_timeout])
      expect(launch["tmux"]).to eq(tmux)
    end

    it "makes the launch file outdated when they change, and the refresh writes them" do
      helper("kitty" => kitty).install
      expect(helper("kitty" => kitty, "tmux" => tmux).launch_outdated?).to be(true)
      helper("kitty" => kitty, "tmux" => tmux).refresh_launch_file
      expect(helper("kitty" => kitty, "tmux" => tmux).launch_outdated?).to be(false)
      expect(helper("kitty" => kitty, "tmux" => tmux.merge("agents" => %w[*])).launch_outdated?).to be(true)
      helper("kitty" => kitty).refresh_launch_file
      expect(JSON.parse(File.read(launch_file))).not_to have_key("tmux")
    end

    it "warns when no tmux binary was found, and only then" do
      expect(helper("tmux" => tmux).terminal_warnings).to eq([])
      expect(helper.terminal_warnings).to eq([])
      warning = "tmux.enabled but no tmux found on PATH: set tmux.binary"
      expect(helper("tmux" => tmux.merge("binary" => "")).terminal_warnings).to eq([warning])
      expect(helper("tmux" => tmux.merge("binary" => "")).warnings).to include(warning)
    end

    describe ".tmux_settings" do
      let(:bin) { File.join(tmp, "bin").tap { |d| FileUtils.mkdir_p(d) } }
      let(:path_env) { { "PATH" => "#{File.join(tmp, "nothing")}:#{bin}" } }

      def settings(values, env = path_env)
        described_class.tmux_settings(->(key) { values.fetch(key) { Samagotchi::Config.find_by_key(key).default } }, env: env)
      end

      def put_tmux
        File.join(bin, "tmux").tap { |p| File.write(p, "#!/bin/sh\n"); File.chmod(0o755, p) }
      end

      it "is nil while tmux.enabled is off (the default)" do
        expect(settings({})).to be_nil
        expect(settings("tmux.enabled" => false)).to be_nil
      end

      it "takes tmux.binary, else the tmux on PATH, else empty; a blank tmux.binary counts as unset" do
        File.write(File.join(bin, "tmux"), "not executable")
        expect(settings("tmux.enabled" => true)["binary"]).to eq("")
        found = put_tmux
        expect(settings("tmux.enabled" => true)["binary"]).to eq(found)
        expect(settings("tmux.enabled" => true, "tmux.binary" => "")["binary"]).to eq(found)
        expect(settings("tmux.enabled" => true, "tmux.binary" => "/opt/homebrew/bin/tmux")["binary"]).to eq("/opt/homebrew/bin/tmux")
      end

      it "skips relative PATH entries when resolving tmux" do
        relative = File.join(tmp, "relative")
        absolute = File.join(tmp, "absolute")
        [relative, absolute].each do |dir|
          FileUtils.mkdir_p(dir)
          tmux_path = File.join(dir, "tmux")
          File.write(tmux_path, "#!/bin/sh\n")
          File.chmod(0o755, tmux_path)
        end

        Dir.chdir(tmp) do
          expect(settings({ "tmux.enabled" => true }, "PATH" => "relative:#{absolute}")["binary"])
            .to eq(File.join(absolute, "tmux"))
        end
      end

      it "puts the socket dir in an existing TMUX_TMPDIR, else in /tmp, as tmux does" do
        uid = Process.uid
        expect(settings("tmux.enabled" => true)["socket_dir"]).to eq("/tmp/tmux-#{uid}")
        expect(settings({ "tmux.enabled" => true }, { "TMUX_TMPDIR" => tmp })["socket_dir"]).to eq("#{tmp}/tmux-#{uid}")
        missing = { "TMUX_TMPDIR" => File.join(tmp, "missing") }
        expect(settings({ "tmux.enabled" => true }, missing)["socket_dir"]).to eq("/tmp/tmux-#{uid}")
      end

      it "takes the agents, kitty.agents' default, split on |" do
        expect(settings("tmux.enabled" => true)["agents"]).to eq(%w[claude codex gemini aider opencode cursor-agent amp goose])
        expect(settings("tmux.enabled" => true, "tmux.agents" => "claude| * |")["agents"]).to eq(%w[claude *])
      end

      it "reaches the helper from chi desktop and chi update with SAMAGOTCHI_TMUX_ENABLED" do
        require "samagotchi/desktop_command"
        require "samagotchi/update_command"
        original = ENV["SAMAGOTCHI_TMUX_ENABLED"]
        ENV["SAMAGOTCHI_TMUX_ENABLED"] = "true"
        [Samagotchi::DesktopCommand.new([]), Samagotchi::UpdateCommand.new([], web: ["127.0.0.1", 1])].each do |command|
          made = command.instance_variable_get(:@platform).call(register: false)
          # Not the binary: CI hosts may or may not have a tmux.
          expect(made.launch_config["tmux"]).to include("agents" => %w[claude codex gemini aider opencode cursor-agent amp goose])
        end
      ensure
        ENV["SAMAGOTCHI_TMUX_ENABLED"] = original
      end

      it "reads tmux: from config.yml" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "samagotchi"))
          File.write(File.join(dir, "samagotchi", "config.yml"), "tmux:\n  enabled: true\n  binary: /x/tmux\n  agents: [claude]\n")
          original = ENV["XDG_CONFIG_HOME"]
          ENV["XDG_CONFIG_HOME"] = dir
          expect(described_class.tmux_settings).to include("binary" => "/x/tmux", "agents" => %w[claude])
        ensure
          ENV["XDG_CONFIG_HOME"] = original
        end
      end
    end
  end

  describe "the broadcast timeout" do
    before do
      File.write(File.join(tmp, "ruby"), "")
      FileUtils.mkdir_p(File.join(source_dir, "bin"))
      File.write(File.join(source_dir, "bin", "chi"), "")
    end

    def helper(broadcast_timeout: nil)
      described_class.new(app_dir: app_dir, support_dir: support_dir, env: env, runner: runner, source_dir: source_dir,
                          ruby: File.join(tmp, "ruby"), version: "9.9.9", arch: "arm64", sources_dir: sources_dir,
                          broadcast_timeout: broadcast_timeout)
    end

    it "is left out without one, written with one, and a changed one outdates the launch file (no rebuild)" do
      helper.install
      expect(JSON.parse(File.read(launch_file))).not_to have_key("broadcast_timeout")
      expect(helper(broadcast_timeout: 30.0).launch_outdated?).to be(true)

      runner.calls.clear
      helper(broadcast_timeout: 30.0).refresh_launch_file
      expect(runner.calls).to be_empty
      expect(JSON.parse(File.read(launch_file))["broadcast_timeout"]).to eq(30.0)
      expect(helper(broadcast_timeout: 30.0).launch_outdated?).to be(false)
      expect(helper(broadcast_timeout: 40.0).launch_outdated?).to be(true)
    end

    describe ".broadcast_timeout" do
      it "is broadcast.triage_deadline plus 10 s: triage, then the deliveries and chi's start" do
        expect(described_class.broadcast_timeout(->(_key) { 45 })).to eq(55.0)
        expect(described_class.broadcast_timeout(->(key) { Samagotchi::Config.find_by_key(key).default })).to eq(30.0)
      end

      it "reaches the helper from chi desktop and chi update (their default platforms)" do
        require "samagotchi/desktop_command"
        require "samagotchi/update_command"
        original = ENV["SAMAGOTCHI_BROADCAST_TRIAGE_DEADLINE"]
        ENV["SAMAGOTCHI_BROADCAST_TRIAGE_DEADLINE"] = "50"
        [Samagotchi::DesktopCommand.new([]), Samagotchi::UpdateCommand.new([], web: ["127.0.0.1", 1])].each do |command|
          made = command.instance_variable_get(:@platform).call(register: false)
          expect(made.launch_config["broadcast_timeout"]).to eq(60.0)
        end
      ensure
        ENV["SAMAGOTCHI_BROADCAST_TRIAGE_DEADLINE"] = original
      end
    end
  end

  describe "#status" do
    it "reports not installed" do
      expect(macos.status).to include(installed: false, chi_version: "9.9.9")
    end

    it "reports the app version, launch file, baked dirs, Service and running state" do
      env["XDG_STATE_HOME"] = "/state"
      macos.install
      File.write(File.join(support_dir, "hotkey.json"), JSON.generate("keys" => "⌃⌥⌘N", "registered" => true))
      dump = "{ NSBundleIdentifier = \"dev.samagotchi.chi-helper\"; }"
      status_runner = DesktopFakeRunner.new(described_class::PBS => [dump, true], "pgrep" => ["123\n", true],
                                            "ChiHelper" => ["enabled\n", true])
      status = described_class.new(app_dir: app_dir, support_dir: support_dir, env: env, runner: status_runner,
                                   source_dir: source_dir, version: "9.9.10", sources_dir: sources_dir).status
      expect(status).to include(installed: true, app_version: "9.9.9", chi_version: "9.9.10",
                                launch_argv: ["/opt/ruby/bin/ruby", File.join(source_dir, "bin", "chi")],
                                launch_ok: false, baked_dirs: { "XDG_STATE_HOME" => "/state" },
                                baked_path: nil,
                                service: true, running: true, login: "enabled",
                                hotkey: { "keys" => "⌃⌥⌘N", "registered" => true })
    end

    it "reports the launch file's baked PATH" do
      env["PATH"] = "/a:/b"
      macos.install
      expect(macos.status[:baked_path]).to eq("/a:/b")
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
