# frozen_string_literal: true

require "spec_helper"
require_relative "support/fake_provider_server"
require "socket"
require "stringio"
require "tmpdir"
require "yaml"
require "samagotchi/update_command"

RSpec.describe Samagotchi::UpdateCommand do
  # Real localhost HTTP (the chi web probe): other suites may enable WebMock.
  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:tmp) { Dir.mktmpdir("update-command") }
  let(:system_dir) { File.join(tmp, "memories") }
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

  before do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = File.join(system_dir, ".bundles")
    Samagotchi::MemoryBundle::Installer.system_dir_override = system_dir
    Samagotchi::MemoryBundle::Installer.project_dir_base_override = File.join(tmp, "proj")
  end

  after do
    servers.each(&:close)
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = nil
    Samagotchi::MemoryBundle::Installer.system_dir_override = nil
    Samagotchi::MemoryBundle::Installer.project_dir_base_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.system_dir_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.project_dir_base_override = nil
    FileUtils.remove_entry(tmp)
  end

  # rubygems says this chi is the newest; never the network.
  let(:fetcher) { -> { JSON.generate(version: Samagotchi::VERSION) } }
  let(:gem_runner) { double("runner", run: ["Successfully installed samagotchi\n", true]) }
  let(:gem_update) { Samagotchi::GemUpdate.new(env: {}, fetcher: fetcher, runner: gem_runner, gem_bin: "/rb/bin/gem") }
  let(:execs) { [] }
  let(:bundler) { false }

  def run(*argv, gem_spec: self.gem_spec)
    out.truncate(0)
    out.rewind
    described_class.new(argv, stdout: out, stderr: err, gem_spec: gem_spec, platform: ->(register:) { helper },
                              supported: supported, state_dir: state_dir, web: web, gem_update: gem_update,
                              exec: ->(argv) { execs << argv }, bundler: bundler).run
  end

  # btw as an older gem shipped it, installed from there.
  def install_old_btw(version: "0.0.1")
    dest = File.join(tmp, "gems", "samagotchi-0.0.1", "lib", "samagotchi", "bundles", "btw")
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp_r(File.join(shipped, "btw"), dest)
    data = YAML.load_file(File.join(dest, "manifest.yml")).merge("version" => version)
    File.write(File.join(dest, "manifest.yml"), YAML.dump(data))
    Samagotchi::MemoryBundle::Installer.new(source: dest, name: "btw", scope: "system", strict: true).run
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

  it "dry-runs, updates, then says everything is up to date" do
    Samagotchi::MemoryBundle::SystemBundle.sync
    install_old_btw

    expect(run("--dry-run")).to eq(0)
    expect(out.string.lines.first).to match(/\Acomponent\s+from\s+to\s+status/)
    expect(line("btw")).to match(/\Abtw\s+0\.0\.1\s+#{Regexp.escape(YAML.load_file(File.join(shipped, "btw", "manifest.yml"))["version"])}\s+would update\z/)
    expect(line("system bundle")).to match(/up to date\z/)
    expect(out.string).to include("Also shipped, not installed:", "known-names", "(dry run: nothing was changed)")
    expect(btw_version).to eq("0.0.1")

    expect(run).to eq(0)
    expect(line("btw")).to match(/\s+updated\z/)
    expect(out.string).to end_with("done\n")
    expect(btw_version).not_to eq("0.0.1")

    expect(run).to eq(0)
    expect(line("btw")).to match(/\Abtw\s+\S+\s+up to date\z/)
    expect(out.string).to end_with("everything is up to date\n")
  end

  it "installs a missing system bundle" do
    expect(run).to eq(0)
    expect(line("system bundle")).to match(/\s+#{Regexp.escape(Samagotchi::VERSION)}\s+installed\z/)
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
      run("--no-desktop")
      expect(out.string).to include("installing samagotchi #{newer}…")
      expect(execs).to eq([[RbConfig.ruby, File.join(wrapper_dir, "bin", "chi"), "update", "--no-gem", "--gem-from",
                            Samagotchi::VERSION, "--no-desktop"]])
    end

    it "shows the handed-over update as the gem row" do
      run("--no-gem", "--gem-from", "0.2.0")
      expect(line("chi (gem)")).to match(/\Achi \(gem\)\s+0\.2\.0\s+#{Regexp.escape(Samagotchi::VERSION)}\s+updated\z/)
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
  end

  describe Samagotchi::GemUpdate do
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
                                                  launch_outdated?: false)
    end

    it "says not installed" do
      allow(helper).to receive(:installed?).and_return(false)
      run
      expect(line("Chi Helper")).to end_with("not installed")
    end

    it "rebuilds a stale helper, but not in a dry run" do
      allow(helper).to receive(:stale?).and_return(true)
      expect(helper).to receive(:upgrade).once
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
        data = { "port" => listener.addr[1] }
        data["version"] = "0.2.0" if i.zero?
        File.write(File.join(state_dir, id, "bridge.json"), JSON.generate(data))
      end
      run
      expect(line("workers")).to include("2 live on 0.2.0, an older chi", "chi sessions stop aaaaaaaa bbbbbbbb")
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
      expect(line("chi web :#{server.addr[1]}")).to include("0.2.0", "restart it")
    end
  end
end
