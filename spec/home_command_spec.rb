# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "spec_helper"
require "samagotchi/home_command"

RSpec.describe Samagotchi::HomeCommand do
  let(:tmp) { Dir.mktmpdir("home-command") }
  let(:path) { File.join(tmp, "samagotchi", "home.json") }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
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
    Samagotchi::ChiHome::Record.new(ruby: ruby, gem_home: gems, gem_path: gems, mise: "/opt/homebrew/bin/mise",
                                    set_at: "2026-10-29T00:00:00Z", set_by_version: "1.2.3")
  end
  let(:probe) { ->(_ruby) { home } }
  # The doctor's rows past the home's are HomeDoctor's (home_doctor_spec):
  # here a doctor without the helper, sessions, a project or mise.
  let(:doctor) do
    lambda do |record|
      Samagotchi::HomeDoctor.new(home: record, env: { "SAMAGOTCHI_MISE_CLI" => File.join(tmp, "no-mise") },
                                 cwd: tmp, gem_spec: nil, helper: nil, sessions: -> { [] },
                                 shim_dir: File.join(tmp, "bin"), log_path: nil)
    end
  end

  before do
    Samagotchi::ChiHome.reset_warnings!
    allow(Samagotchi::Log).to receive(:warn)
  end

  after { FileUtils.remove_entry(tmp) }

  def run(*argv, gem_spec: nil)
    out.truncate(0)
    out.rewind
    described_class.new(argv, stdout: out, stderr: err, path: path, gem_spec: gem_spec, env: {}, probe: probe,
                              doctor: doctor).run
  end

  it "says there is none" do
    expect(run).to eq(0)
    expect(out.string).to start_with("no chi home: chi launches on the Ruby that starts it")
  end

  it "shows the home: its ruby, chi version, gem home and path, mise, when set, and the running chi when another" do
    Samagotchi::ChiHome.write!(home, path: path)
    expect(run).to eq(0)
    expect(out.string.lines.map(&:rstrip)).to eq([
      "ruby      #{ruby}", "chi       1.2.3", "gem home  #{gems}",
      "gem path  #{gems}", "mise      /opt/homebrew/bin/mise",
      "set       2026-10-29T00:00:00Z by chi 1.2.3",
      "running   chi #{Samagotchi::VERSION} on #{RbConfig.ruby} (a checkout)"
    ])
  end

  it "shows a home that can't boot chi, with the problem, exit 1" do
    Samagotchi::ChiHome.write!(home.with(ruby: "/gone/ruby"), path: path)
    expect(run).to eq(1)
    expect(out.string).to include("problem   home ruby missing: /gone/ruby (chi home doctor)")
  end

  it "says what to do about a home.json that isn't its shape" do
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "{")
    expect(run).to eq(1)
    expect(err.string).to include("chi home: ", "home.json", "(chi home set rewrites it)")
  end

  describe "set" do
    it "records this chi's Ruby and gem path" do
      allow(Samagotchi::ChiHome).to receive(:from_running).and_return(home)
      expect(run("set")).to eq(0)
      expect(out.string).to eq("chi home set to #{ruby} (chi 1.2.3); new workers and launches boot it\n")
      expect(Samagotchi::ChiHome.read(path: path)).to eq(home)
    end

    it "records another Ruby, asked for its own gem dirs" do
      other = File.join(tmp, "other-ruby").tap { |f| File.write(f, "") && File.chmod(0o755, f) }
      seen = []
      command = described_class.new(["set", "--ruby", other], stdout: out, stderr: err, path: path, env: {},
                                                               probe: ->(r) { seen << r; home })
      expect(command.run).to eq(0)
      expect(seen).to eq([other])
      expect(Samagotchi::ChiHome.read(path: path)).to eq(home)
    end

    it "refuses a Ruby without samagotchi, one that isn't there, or doesn't answer, writing nothing" do
      allow(Samagotchi::ChiHome).to receive(:from_running).and_return(home.with(gem_path: tmp, gem_home: tmp))
      expect(run("set")).to eq(1)
      expect(err.string).to include("no samagotchi in the home's gems", "gem install samagotchi with #{ruby} first")

      expect(run("set", "--ruby", File.join(tmp, "nope"))).to eq(1)
      expect(err.string).to include("chi home set: no Ruby at #{File.join(tmp, "nope")}")

      expect(described_class.new(["set", "--ruby", ruby], stdout: out, stderr: err, path: path, env: {},
                                                           probe: ->(_) {}).run).to eq(1)
      expect(err.string).to include("didn't answer as a Ruby")
      expect(File.exist?(path)).to be(false)
    end

    it "refuses arguments and unknown options (usage, exit 2)" do
      expect(run("set", "x")).to eq(2)
      expect(run("set", "--frob")).to eq(2)
    end
  end

  describe "doctor" do
    it "is ok without a home and with a working one" do
      expect(run("doctor")).to eq(0)
      Samagotchi::ChiHome.write!(home, path: path)
      expect(run("doctor")).to eq(0)
      expect(out.string.lines.first).to eq("ok    chi home #{ruby} runs chi 1.2.3\n")
    end

    it "fails on a home whose ruby is gone or has no samagotchi, saying what to do" do
      Samagotchi::ChiHome.write!(home.with(ruby: "/gone/ruby"), path: path)
      expect(run("doctor")).to eq(1)
      expect(out.string).to include("fail  home ruby missing: /gone/ruby", "gem install samagotchi", "chi home set")

      Samagotchi::ChiHome.write!(home.with(gem_path: tmp, gem_home: tmp), path: path)
      expect(run("doctor")).to eq(1)
      expect(out.string).to include("fail  no samagotchi in the home's gems")
    end
  end
end
