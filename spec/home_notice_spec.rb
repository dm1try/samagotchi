# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "spec_helper"
require "samagotchi/home_notice"

RSpec.describe Samagotchi::HomeNotice do
  let(:tmp) { File.realpath(Dir.mktmpdir("home-notice")) }
  let(:env) { { "XDG_CONFIG_HOME" => File.join(tmp, "config"), "XDG_STATE_HOME" => File.join(tmp, "state") } }
  let(:io) { StringIO.new }
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
                                    set_at: "t", set_by_version: "1.2.3")
  end
  let(:gem_spec) { instance_double(Gem::Specification) }
  let(:line) do
    "chi #{Samagotchi::VERSION} on #{RbConfig.ruby}; the chi home is #{ruby} (chi 1.2.3) (chi home doctor)"
  end

  before do
    Samagotchi::ChiHome.reset_warnings!
    allow(Samagotchi::Log).to receive(:warn)
    Samagotchi::ChiHome.write!(home, path: Samagotchi::ChiHome.path(env: env))
  end

  after { FileUtils.remove_entry(tmp) }

  def show(argv: [], tty: true, today: "2026-10-30", environment: env, spec: gem_spec)
    described_class.show(argv: argv, env: environment, tty: tty, io: io, gem_spec: spec, today: today)
  end

  it "prints one dim line on another Ruby than the home's, once a day" do
    expect(show).to eq(line)
    expect(io.string).to eq("\e[2m#{line}\e[0m\n")
    expect(show).to be_nil
    expect(show(argv: %w[sessions list])).to be_nil
    expect(show(today: "2026-10-31")).to eq(line)
    expect(io.string.lines.size).to eq(2)
  end

  it "says nothing on the home" do
    expect(described_class.mismatch(home, ruby: ruby, gem_dir: gems, version: "1.2.3")).to be_nil
    expect(described_class.mismatch(home, ruby: ruby, gem_dir: gems, version: "1.2.2")).to start_with("chi 1.2.2 on ")
    expect(described_class.mismatch(nil)).to be_nil
    expect(described_class.mismatch(home, ruby: ruby, gem_dir: "/other/gems", version: "1.2.3"))
      .to eq("chi 1.2.3 on #{ruby} (gems /other/gems); the chi home is #{ruby} (gems #{gems}) (chi 1.2.3)")
  end

  it "says nothing without a TTY, from a checkout, inside a worker's tools or a test run, without a home" do
    expect(show(tty: false)).to be_nil
    expect(show(spec: nil)).to be_nil
    expect(show(environment: env.merge("SAMAGOTCHI_PROJECT_ENV" => "none:off"))).to be_nil
    expect(show(environment: env.merge("CI" => "1"))).to be_nil
    expect(show(environment: env.merge("XDG_CONFIG_HOME" => File.join(tmp, "none")))).to be_nil
    expect(io.string).to eq("")
  end

  it "says nothing for machine output, scripts and the commands that say it themselves" do
    [%w[sessions list --format json], %w[sessions list --format=json], %w[send --json], %w[-p x --non-interactive],
     %w[--version], %w[home], %w[update], %w[self]].each do |argv|
      expect(show(argv: argv)).to be_nil, argv.join(" ")
    end
    expect(io.string).to eq("")
  end
end
