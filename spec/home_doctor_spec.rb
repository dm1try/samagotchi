# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/home_doctor"

RSpec.describe Samagotchi::HomeDoctor do
  let(:tmp) { File.realpath(Dir.mktmpdir("home-doctor")) }
  let(:gems) do
    File.join(tmp, "gems").tap do |dir|
      FileUtils.mkdir_p(File.join(dir, "specifications"))
      File.write(File.join(dir, "specifications", "samagotchi-1.2.3.gemspec"), "")
    end
  end
  let(:ruby) do
    File.join(tmp, "rb", "bin", "ruby").tap do |file|
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, "")
      File.chmod(0o755, file)
    end
  end
  let(:home) do
    Samagotchi::ChiHome::Record.new(ruby: ruby, gem_home: gems, gem_path: gems, mise: nil,
                                    set_at: "2026-10-29T00:00:00Z", set_by_version: "1.2.3")
  end
  let(:project) { File.join(tmp, "project").tap { |dir| FileUtils.mkdir_p(File.join(dir, ".git")) } }
  let(:mise) { File.join(tmp, "no-mise") }
  let(:shim_dir) { File.join(tmp, "bin") }
  let(:log_path) { File.join(tmp, "samagotchi.log") }
  let(:helper) { nil }
  let(:sessions) { [] }
  let(:gem_spec) { instance_double(Gem::Specification) }

  before { allow(Samagotchi::Log).to receive(:warn) }

  after { FileUtils.remove_entry(tmp) }

  def doctor(record = home, ruby_now: ruby, gem_dir: gems, spec: gem_spec)
    described_class.new(home: record, env: { "SAMAGOTCHI_MISE_CLI" => mise }, cwd: project, gem_spec: spec,
                        helper: helper, sessions: -> { sessions }, shim_dir: shim_dir, log_path: log_path,
                        ruby: ruby_now, gem_dir: gem_dir)
  end

  def lines(record = home, **) = doctor(record, **).rows.map(&:to_s)

  def stub_version(version)
    stub_const("Samagotchi::VERSION", version)
  end

  it "is the home's row and the project env's without a home" do
    expect(lines(nil)).to eq([
      "ok    no chi home: each launch uses the Ruby that starts it (chi home set to record one)",
      "ok    #{Samagotchi::ProjectEnv::NO_MISE}"
    ])
  end

  it "fails a home that can't boot chi and checks nothing that follows it" do
    rows = doctor(home.with(ruby: "/gone/ruby")).rows
    expect(rows.first.status).to eq(:fail)
    expect(rows.first.text).to include("home ruby missing: /gone/ruby", "chi home set")
    expect(rows.size).to eq(2)
  end

  it "has only ok rows on the home, with nothing else to flag" do
    stub_version("1.2.3")
    expect(lines).to eq(["ok    chi home #{ruby} runs chi 1.2.3", "ok    #{Samagotchi::ProjectEnv::NO_MISE}"])
  end

  it "warns when this chi isn't the home's: another Ruby, or another version, with the notice's text" do
    stub_version("1.2.2")
    other = File.join(tmp, "other-ruby").tap { |f| File.write(f, "") }
    expect(lines(ruby_now: other)).to include(
      "warn  chi 1.2.2 on #{other}; the chi home is #{ruby} (chi 1.2.3): launches boot the home; " \
      "chi home set makes this chi the home"
    )
    expect(lines.grep(/chi 1\.2\.2 on #{Regexp.escape(ruby)}/)).not_to be_empty
  end

  it "says a source checkout starts its own code" do
    expect(lines(spec: nil)).to include("ok    this chi runs from a source checkout: it starts its own code, not the home")
  end

  context "with the desktop helper" do
    let(:helper) { instance_double(Samagotchi::Desktop::MacOS, launch_problem: nil, home_problem: nil) }

    before { stub_version("1.2.3") }

    it "fails a launch file that can't run, warns one that isn't on the home" do
      allow(helper).to receive(:launch_problem).and_return("chi not found at /x: run chi desktop install --force …")
      expect(lines).to include("fail  chi not found at /x: run chi desktop install --force …")
      expect(doctor.rows.map(&:status)).to include(:fail)

      allow(helper).to receive(:launch_problem).and_return(nil)
      allow(helper).to receive(:home_problem).with(home).and_return("the desktop helper runs a b, not …: chi desktop upgrade")
      expect(lines).to include("warn  the desktop helper runs a b, not …: chi desktop upgrade")
    end
  end

  describe ".default_helper" do
    let(:launch) { File.join(tmp, "Library", "Application Support", Samagotchi::Desktop::MacOS::APP_NAME, "launch.json") }
    let(:env) { { "HOME" => tmp, "XDG_CONFIG_HOME" => File.join(tmp, "config") } }

    before { allow(Samagotchi::Desktop).to receive(:supported?).and_return(true) }

    def write_launch(baked)
      FileUtils.mkdir_p(File.dirname(launch))
      File.write(launch, JSON.generate({ "argv" => [ruby, "chi"], "env" => baked }))
    end

    it "is the installed helper whose chi reads this chi's config dir (home.json's), else none" do
      expect(described_class.default_helper(env: env)).to be_nil

      write_launch({ "XDG_CONFIG_HOME" => File.join(tmp, "config") })
      expect(described_class.default_helper(env: env)&.launch_path).to eq(launch)

      write_launch({ "XDG_CONFIG_HOME" => File.join(tmp, "elsewhere") })
      expect(described_class.default_helper(env: env)).to be_nil
      write_launch({})
      expect(described_class.default_helper(env: env)).to be_nil
      with_env("HOME" => tmp) { expect(described_class.default_helper(env: { "HOME" => tmp })&.launch_path).to eq(launch) }
    end
  end

  context "with sessions saved by a newer chi" do
    let(:sessions) do
      %w[1.2.3 1.3.0 1.4.0 junk].map { |v| instance_double(Samagotchi::Session, written_by: v) } +
        [instance_double(Samagotchi::Session, written_by: nil)]
    end

    it "counts them and names the newest" do
      stub_version("1.2.3")
      expect(lines).to include("warn  2 sessions were last saved by a newer chi (1.4.0) than the home's 1.2.3: " \
                               "their workers run without what it added; chi update brings the home up to date")
    end
  end

  it "warns about a chi script for tools that doesn't boot the home, not about a missing one" do
    stub_version("1.2.3")
    expect(lines.join).not_to include("chi script")
    FileUtils.mkdir_p(shim_dir)
    File.write(File.join(shim_dir, "chi"), "#!/bin/sh\nexec /old/ruby\n")
    expect(lines.grep(/chi script tools run/).first).to start_with("warn  the chi script tools run")
    Samagotchi::ChiShim.ensure!(home, dir: shim_dir)
    expect(lines.join).not_to include("chi script")
  end

  describe "the project's Gemfile.lock" do
    it "warns when it bundles samagotchi, from a subfolder too, never for chi's own tree" do
      File.write(File.join(project, "Gemfile.lock"), "GEM\n  specs:\n    rake (13.0)\n")
      expect(lines(nil).join).not_to include("Gemfile.lock")

      File.write(File.join(project, "Gemfile.lock"), "GEM\n  specs:\n    samagotchi (0.132.0)\n      json\n")
      FileUtils.mkdir_p(File.join(project, "sub"))
      row = described_class.new(home: nil, env: { "SAMAGOTCHI_MISE_CLI" => mise }, cwd: File.join(project, "sub"),
                                sessions: -> { [] }, shim_dir: shim_dir, log_path: nil).rows
      expect(row.map(&:to_s)).to include(start_with("warn  #{File.join(project, "Gemfile.lock")} bundles samagotchi"))

      File.write(File.join(project, "samagotchi.gemspec"), "")
      expect(lines(nil).join).not_to include("Gemfile.lock")
    end
  end

  describe "mise" do
    it "names the mise found, and warns of none only when session.project_env says mise" do
      fake = File.join(tmp, "mise").tap { |f| File.write(f, "") && File.chmod(0o755, f) }
      expect(described_class.new(home: nil, env: { "SAMAGOTCHI_MISE_CLI" => fake }, cwd: project,
                                 sessions: -> { [] }, shim_dir: shim_dir, log_path: nil).rows.last.to_s)
        .to eq("ok    project env: mise (#{fake})")

      allow(Samagotchi::Config).to receive(:get_with_origin).with("session.project_env").and_return(["mise", :file])
      expect(lines(nil).last).to eq("warn  #{Samagotchi::ProjectEnv::NO_MISE}")

      allow(Samagotchi::Config).to receive(:get_with_origin).with("session.project_env").and_return(["off", :file])
      expect(lines(nil).last).to start_with("ok    project env off")
    end
  end

  describe "the last worker's project env" do
    def log(level, event, **fields)
      record = Samagotchi::LogLine::Record.new(ts: Time.utc(2026, 10, 30, 9), level: level, tag: "worker", pid: 1,
                                               sid: "abcd1234", event: event, fields: fields, payload: nil)
      File.write(log_path, Samagotchi::LogLine.format(record), mode: "a")
    end

    it "warns with the fix when the newest record for this folder is a warning" do
      log("WARN", "project_env", reason: "mise_failed", dir: project,
                                 error: "mise_failed: exit 1: Config files in #{project}/mise.toml are not trusted.")
      log("WARN", "project_env", reason: "mise_timeout", dir: "/elsewhere", error: "mise_timeout: no answer in 5 s")
      expect(lines(nil).last).to eq(
        "warn  the last worker in #{Samagotchi::Paths.tilde(project)} (2026-10-30T09:00:00.000Z) got no project env " \
        "(mise_failed: exit 1: Config files in #{project}/mise.toml are not trusted.): " \
        "mise trust in #{Samagotchi::Paths.tilde(project)}, then chi sessions restart abcd1234"
      )

      FileUtils.mkdir_p(File.join(project, "sub"))
      from_sub = described_class.new(home: nil, env: { "SAMAGOTCHI_MISE_CLI" => mise }, cwd: File.join(project, "sub"),
                                     sessions: -> { [] }, shim_dir: shim_dir, log_path: log_path).rows
      expect(from_sub.last.text).to start_with("the last worker in #{Samagotchi::Paths.tilde(project)} ")

      log("INFO", "project_env_applied", dir: project, ruby: "/r")
      expect(lines(nil).join).not_to include("the last worker")
    end
  end
end
