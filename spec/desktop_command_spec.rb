# frozen_string_literal: true

require "open3"
require "rbconfig"
require "stringio"
require "spec_helper"
require "samagotchi/desktop_command"

RSpec.describe Samagotchi::DesktopCommand do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:macos) { instance_double(Samagotchi::Desktop::MacOS, warnings: []) }
  let(:made_with) { [] }
  let(:supported) { true }

  def run(*argv)
    factory = lambda do |register:|
      made_with << register
      macos
    end
    described_class.new(argv, stdout: out, stderr: err, platform: factory, supported: supported).run
  end

  it "prints usage for no subcommand or help" do
    expect(run).to eq(0)
    expect(out.string).to include("Usage: chi desktop <install|upgrade|uninstall|status>")
    expect(run("--help")).to eq(0)
  end

  it "refuses an unknown subcommand" do
    expect(run("frob")).to eq(2)
    expect(err.string).to include("unknown subcommand frob")
  end

  context "off macOS" do
    let(:supported) { false }

    it "says macOS only and exits 1" do
      expect(run("install")).to eq(1)
      expect(err.string).to eq("chi desktop supports macOS only for now\n")
    end
  end

  describe "install" do
    it "prints warnings and progress, and registers by default" do
      allow(macos).to receive(:warnings).and_return(["from a linked git worktree"])
      expect(macos).to receive(:install).with(force: false) { |**, &blk| blk.call("building…") }
      expect(run("install")).to eq(0)
      expect(err.string).to include("warning: from a linked git worktree")
      expect(out.string).to include("building…")
      expect(made_with).to eq([true])
    end

    it "passes --force, and --no-register skips the system registration" do
      expect(macos).to receive(:install).with(force: true)
      expect(run("install", "--force", "--no-register")).to eq(0)
      expect(made_with).to eq([false])
    end

    it "prints an install error on one line and exits 1" do
      allow(macos).to receive(:install).and_raise(Samagotchi::Desktop::MacOS::Error, "already installed (0.1.1); use chi desktop upgrade")
      expect(run("install")).to eq(1)
      expect(err.string).to eq("chi desktop: already installed (0.1.1); use chi desktop upgrade\n")
    end

    it "refuses an unknown flag" do
      expect(run("install", "--bogus")).to eq(2)
      expect(err.string).to include("unknown option --bogus")
    end

    it "takes --force only on install" do
      expect(run("status", "--force")).to eq(2)
      expect(err.string).to include("unknown option --force")
    end
  end

  it "upgrade upgrades" do
    expect(macos).to receive(:upgrade) { |&blk| blk.call("installed X") }
    expect(run("upgrade")).to eq(0)
    expect(out.string).to include("installed X")
  end

  describe "uninstall" do
    it "says what it removed" do
      allow(macos).to receive(:uninstall).and_return(true)
      expect(run("uninstall")).to eq(0)
      expect(out.string).to include("removed Chi Helper")
    end

    it "says when nothing was installed" do
      allow(macos).to receive(:uninstall).and_return(false)
      expect(run("uninstall")).to eq(0)
      expect(out.string).to include("Chi Helper is not installed")
    end
  end

  describe "status" do
    it "says not installed and how to install" do
      allow(macos).to receive(:status).and_return(installed: false, app_path: "/A/Chi Helper.app", chi_version: "0.1.19")
      expect(run("status")).to eq(0)
      expect(out.string).to include("not installed (chi desktop install)")
    end

    it "shows matching versions, the launch file, baked dirs, Service and running" do
      allow(macos).to receive(:status).and_return(
        installed: true, app_path: "/A/Chi Helper.app", chi_version: "0.1.19", app_version: "0.1.19",
        launch_argv: ["/r/ruby", "/c/bin/chi"], launch_ok: true, baked_dirs: { "XDG_STATE_HOME" => "/s" },
        service: true, running: true
      )
      run("status")
      expect(out.string).to include("0.1.19 (matches chi)", "/r/ruby /c/bin/chi (ok)", "XDG_STATE_HOME=/s",
                                    "registered", "running")
    end

    it "says to upgrade on a version mismatch or a stale launch file, and what's missing" do
      allow(macos).to receive(:status).and_return(
        installed: true, app_path: "/A/Chi Helper.app", chi_version: "0.1.20", app_version: "0.1.19",
        launch_argv: ["/r/ruby", "/c/bin/chi"], launch_ok: false, baked_dirs: {},
        service: false, running: false
      )
      run("status")
      expect(out.string).to include("0.1.19 (chi is 0.1.20: chi desktop upgrade)",
                                    "(missing: chi desktop upgrade)", "(defaults)",
                                    "not registered", "not running")
    end
  end

  it "is reachable from bin/chi" do
    chi = File.expand_path("../bin/chi", __dir__)
    out, _err, status = Open3.capture3(RbConfig.ruby, chi, "desktop", "--help", stdin_data: "")
    expect(status.exitstatus).to eq(0)
    expect(out).to include("Usage: chi desktop")
  end
end
