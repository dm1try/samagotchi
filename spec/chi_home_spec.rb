# frozen_string_literal: true

require "json"
require "tmpdir"
require "spec_helper"
require "samagotchi/chi_home"

RSpec.describe Samagotchi::ChiHome do
  let(:tmp) { Dir.mktmpdir("chi-home") }
  let(:path) { File.join(tmp, "config", "samagotchi", "home.json") }
  let(:ruby) { File.join(tmp, "ruby", "bin", "ruby").tap { |f| make_executable(f) } }
  let(:gems) { File.join(tmp, "gems").tap { |d| add_gemspec(d, "samagotchi", "1.2.3") } }
  let(:gem_spec) { Gem::Specification.new { |s| s.name = "samagotchi"; s.version = "1.2.3" } }
  let(:home) do
    described_class::Record.new(ruby: ruby, gem_home: gems, gem_path: gems, mise: nil, set_at: "2026-10-29T00:00:00Z",
                                set_by_version: "1.2.3")
  end

  before do
    described_class.reset_warnings!
    allow(Samagotchi::Log).to receive(:warn)
  end

  after { FileUtils.remove_entry(tmp) }

  def make_executable(file)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, "#!/bin/sh\n")
    File.chmod(0o755, file)
  end

  def add_gemspec(dir, name, version)
    FileUtils.mkdir_p(File.join(dir, "specifications"))
    File.write(File.join(dir, "specifications", "#{name}-#{version}.gemspec"), "")
  end

  def write_home(record = home) = described_class.write!(record, path: path)

  describe ".path" do
    it "is home.json in the config dir, honouring XDG_CONFIG_HOME" do
      expect(described_class.path(env: { "XDG_CONFIG_HOME" => "/x" })).to eq("/x/samagotchi/home.json")
      expect(described_class.path(env: {})).to eq(File.join(Dir.home, ".config", "samagotchi", "home.json"))
    end
  end

  describe ".current" do
    it "is the recorded home when its ruby runs and has samagotchi" do
      write_home
      expect(described_class.current(path: path, gem_spec: gem_spec)).to eq(home)
      expect(JSON.parse(File.read(path)).keys).to eq(%w[ruby gem_home gem_path mise set_at set_by_version])
    end

    it "is nil without home.json" do
      expect(described_class.current(path: path, gem_spec: gem_spec)).to be_nil
    end

    it "is nil from a source checkout, a home.json or not" do
      write_home
      expect(described_class.current(path: path, gem_spec: nil)).to be_nil
    end

    it "is nil for a file that isn't home.json's shape, warned once" do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{not json")
      2.times { expect(described_class.current(path: path, gem_spec: gem_spec)).to be_nil }
      File.write(path, JSON.generate("ruby" => "relative/ruby", "gem_home" => gems, "gem_path" => gems))
      expect(described_class.current(path: path, gem_spec: gem_spec)).to be_nil
      File.write(path, "[]")
      expect(described_class.current(path: path, gem_spec: gem_spec)).to be_nil
      expect(Samagotchi::Log).to have_received(:warn).with(:config, "home_invalid", path: path, error: anything).exactly(3).times
    end

    it "is nil when its ruby is gone (a Ruby upgrade), warned once" do
      write_home(home.with(ruby: File.join(tmp, "gone", "ruby")))
      2.times { expect(described_class.current(path: path, gem_spec: gem_spec)).to be_nil }
      expect(Samagotchi::Log).to have_received(:warn)
        .with(:config, "home_unusable", path: path, problem: "home ruby missing: #{File.join(tmp, "gone", "ruby")}").once
    end

    it "is nil when the ruby isn't executable" do
      File.chmod(0o644, ruby)
      write_home
      expect(described_class.current(path: path, gem_spec: gem_spec)).to be_nil
    end

    it "is nil when no samagotchi gemspec is under its gem path" do
      empty = File.join(tmp, "empty").tap { |d| add_gemspec(d, "commonmarker", "2.0.0") }
      write_home(home.with(gem_home: empty, gem_path: empty))
      expect(described_class.current(path: path, gem_spec: gem_spec)).to be_nil
      expect(Samagotchi::Log).to have_received(:warn).with(:config, "home_unusable", path: path,
                                                                                     problem: /no samagotchi/)
    end
  end

  describe "Record.from_h" do
    let(:valid) { home.to_h }

    it "takes home.json's fields, mise absolute or null" do
      expect(described_class::Record.from_h(valid)).to eq(home)
      expect(described_class::Record.from_h(valid.merge("mise" => "/opt/homebrew/bin/mise")).mise).to eq("/opt/homebrew/bin/mise")
    end

    it "refuses a relative or missing ruby, gem_home, gem_path entry or mise" do
      [{ "ruby" => "ruby" }, { "ruby" => nil }, { "gem_home" => "gems" }, { "gem_path" => "/a:rel" },
       { "gem_path" => "" }, { "mise" => "mise" }, { "mise" => 3 }].each do |bad|
        expect { described_class::Record.from_h(valid.merge(bad)) }.to raise_error(described_class::Invalid), bad.inspect
      end
    end
  end

  describe "Record" do
    it "lists the samagotchi versions across its gem path, newest last" do
      other = File.join(tmp, "user-gems").tap { |d| add_gemspec(d, "samagotchi", "1.10.0") }
      add_gemspec(gems, "samagotchi", "1.2.4.pre")
      add_gemspec(gems, "samagotchi-extra", "9.0.0")
      record = home.with(gem_path: [other, gems].join(File::PATH_SEPARATOR))
      expect(record.versions.map(&:to_s)).to eq(%w[1.2.3 1.2.4.pre 1.10.0])
      expect(record.newest_version.to_s).to eq("1.10.0")
      expect(record.gem?("samagotchi-extra")).to be(true)
      expect(record.gem?("commonmarker")).to be(false)
    end

    it "boots its ruby with Gem.paths set in the -e string: string literals, no env" do
      record = home.with(gem_home: "/g/h", gem_path: "/u/g:/g/h\#{x}")
      expect(record.boot_argv(run: "puts 1")).to eq(
        [ruby, "-e", "Gem.paths = {'GEM_HOME' => \"/g/h\", 'GEM_PATH' => \"/u/g:/g/h\\\#{x}\"}; puts 1"]
      )
    end

    it "names its own gem command" do
      expect(home.gem_bin).to eq(File.join(tmp, "ruby", "bin", "gem"))
    end

    it "says whether this process runs on it: the same ruby and gem dir" do
      expect(home.running_here?(ruby: ruby, gem_dir: gems)).to be(true)
      expect(home.running_here?(ruby: ruby, gem_dir: tmp)).to be(false)
      expect(home.running_here?(ruby: "/other/ruby", gem_dir: gems)).to be(false)
    end
  end

  describe ".boot_argv / .gem_bin / .install_env" do
    it "are nil, this Ruby's gem and {} without a home" do
      expect(described_class.boot_argv(run: "x", home: nil)).to be_nil
      expect(described_class.gem_bin(nil)).to eq(File.join(RbConfig::CONFIG["bindir"], "gem"))
      expect(described_class.install_env(nil)).to eq({})
    end

    it "install into the home's gems, mise's dir on PATH once" do
      expect(described_class.boot_argv(run: "x", home: home)).to eq(home.boot_argv(run: "x"))
      expect(described_class.gem_bin(home)).to eq(home.gem_bin)
      expect(described_class.install_env(home, env: { "PATH" => "/bin", "GEM_HOME" => "/stray" }))
        .to eq("GEM_HOME" => gems, "GEM_PATH" => gems)
      with_mise = home.with(mise: "/opt/homebrew/bin/mise")
      expect(described_class.install_env(with_mise, env: { "PATH" => "/usr/bin:/bin" }))
        .to eq("GEM_HOME" => gems, "GEM_PATH" => gems, "PATH" => "/usr/bin:/bin:/opt/homebrew/bin")
      expect(described_class.install_env(with_mise, env: { "PATH" => "/opt/homebrew/bin:/bin" }))
        .to eq("GEM_HOME" => gems, "GEM_PATH" => gems)
    end
  end

  describe ".fallback_version" do
    it "pins the spawner's version when the home has it, else the home's newest" do
      add_gemspec(gems, "samagotchi", "1.3.0")
      expect(described_class.fallback_version(home, gem_spec)).to eq("1.2.3")
      expect(described_class.fallback_version(home, gem_spec.dup.tap { |s| s.version = "0.9.0" })).to eq("1.3.0")
      expect(described_class.fallback_version(home, nil)).to eq("1.3.0")
    end
  end

  describe ".probe" do
    it "asks the Ruby for its gem dirs with GEM_*, RUBYOPT and Bundler unset, unless the launch file gave GEM_*" do
      calls = []
      runner = lambda do |env, argv|
        calls << [env, argv]
        [JSON.generate("ruby" => ruby, "gem_home" => gems, "gem_path" => gems), true]
      end
      probed = described_class.probe(ruby, env: {}, runner: runner)
      expect(probed).to have_attributes(ruby: File.realpath(ruby), gem_home: gems, gem_path: gems)
      expect(calls.first.first).to include("GEM_HOME" => nil, "GEM_PATH" => nil, "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil)
      expect(calls.first.last).to eq([ruby, "-e", described_class::PROBE])

      described_class.probe(ruby, gem_env: { "GEM_HOME" => "/g", "PATH" => "/x" }, env: {}, runner: runner)
      expect(calls.last.first).to include("GEM_HOME" => "/g", "GEM_PATH" => nil)
      expect(calls.last.first).not_to have_key("PATH")
    end

    it "is nil when the Ruby fails, doesn't answer JSON, or answers what home.json may not hold" do
      expect(described_class.probe(ruby, env: {}, runner: ->(*) { ["boom", false] })).to be_nil
      expect(described_class.probe(ruby, env: {}, runner: ->(*) { ["not json", true] })).to be_nil
      expect(described_class.probe(ruby, env: {}, runner: ->(*) { ["[]", true] })).to be_nil
      relative = JSON.generate("ruby" => ruby, "gem_home" => "gems", "gem_path" => "gems")
      expect(described_class.probe(ruby, env: {}, runner: ->(*) { [relative, true] })).to be_nil
    end
  end

  describe ".record_first!" do
    let(:launch_path) { File.join(tmp, "launch.json") }
    let(:helper_ruby) { File.join(tmp, "helper-ruby", "bin", "ruby").tap { |f| make_executable(f) } }
    # The helper's chi is at least this one (999.0.0): a first record never moves launches to an older chi.
    let(:helper_gems) { File.join(tmp, "helper-gems").tap { |d| add_gemspec(d, "samagotchi", "999.0.0") } }
    let(:probes) { [] }
    let(:runner) do
      lambda do |env, argv|
        probes << [env, argv]
        [JSON.generate("ruby" => argv.first, "gem_home" => helper_gems, "gem_path" => helper_gems), true]
      end
    end

    before { allow(described_class).to receive(:from_running).and_return(home) }

    def record!(bundler: false) = described_class.record_first!(gem_spec: gem_spec, launch_path: launch_path, path: path,
                                                                env: {}, runner: runner, bundler: bundler)

    def helper_launch(env = {}) = File.write(launch_path, JSON.generate("argv" => [helper_ruby, "/x/bin/chi"], "env" => env))

    it "records the helper's ruby when its launch file names one that has a chi at least this one, with its GEM_*" do
      helper_launch("GEM_HOME" => "/hg")
      expect(record!).to have_attributes(ruby: File.realpath(helper_ruby), gem_home: helper_gems)
      expect(probes.first.first).to include("GEM_HOME" => "/hg")
      expect(described_class.read(path: path).ruby).to eq(File.realpath(helper_ruby))
    end

    it "records the candidate with the newest chi: this chi's Ruby when it has a newer one than the helper's" do
      add_gemspec(gems, "samagotchi", "1000.0.0")
      helper_launch
      expect(record!).to eq(home)
    end

    it "passes over a helper whose newest chi is older than this one" do
      FileUtils.rm_rf(File.join(helper_gems, "specifications"))
      add_gemspec(helper_gems, "samagotchi", "0.0.1")
      add_gemspec(gems, "samagotchi", "0.0.0") # this chi's Ruby has an even older one: still not the helper's
      helper_launch
      expect(record!).to eq(home)
    end

    it "records this chi's Ruby without a usable helper" do
      expect(record!).to eq(home)
      expect(described_class.read(path: path)).to eq(home)

      FileUtils.rm(path)
      File.write(launch_path, JSON.generate("argv" => ["/gone/ruby", "/x/bin/chi"]))
      expect(record!).to eq(home)
      expect(probes).to be_empty

      FileUtils.rm(path)
      FileUtils.rm_rf(File.join(helper_gems, "specifications"))
      helper_launch
      expect(record!).to eq(home)
    end

    it "never overwrites a home.json, records nothing from a checkout, under Bundler or without samagotchi" do
      write_home(home.with(set_by_version: "0.1.0"))
      expect(record!).to be_nil
      expect(described_class.read(path: path).set_by_version).to eq("0.1.0")

      FileUtils.rm(path)
      expect(described_class.record_first!(gem_spec: nil, path: path, env: {}, runner: runner, bundler: false)).to be_nil
      expect(record!(bundler: true)).to be_nil
      # This suite runs under Bundler: found out by default.
      expect(described_class.record_first!(gem_spec: gem_spec, path: path, env: {}, runner: runner)).to be_nil
      expect(File.exist?(path)).to be(false)

      allow(described_class).to receive(:from_running).and_return(home.with(gem_path: tmp, gem_home: tmp))
      expect(record!).to be_nil
      expect(File.exist?(path)).to be(false)
    end
  end

  describe ".from_running" do
    it "is this process's real ruby and gem path" do
      running = described_class.from_running(env: {})
      expect(running).to have_attributes(ruby: File.realpath(RbConfig.ruby), gem_home: Gem.dir,
                                         gem_path: Gem.path.join(File::PATH_SEPARATOR),
                                         set_by_version: Samagotchi::VERSION)
    end
  end

  describe ".find_mise" do
    it "finds mise on PATH (absolute dirs only)" do
      mise = File.join(tmp, "mise-bin", "mise").tap { |f| make_executable(f) }
      expect(described_class.find_mise(env: { "PATH" => "rel:#{File.dirname(mise)}" })).to eq(mise)
    end
  end
end
