# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "samagotchi/host_keys"

RSpec.describe Samagotchi::HostKeys do
  # A Keychain stand-in counting its reads; never the real one.
  let(:fake) do
    Struct.new(:items, :reads) do
      def read(name)
        reads << name
        items[name]
      end
    end.new({}, [])
  end

  before { described_class.keychain = fake }

  it "takes the variable when set, without reading the Keychain" do
    fake.items["BOX_KEY"] = "sk-keychain"
    env = { "BOX_KEY" => "sk-env" }
    expect(described_class.fetch("BOX_KEY", env: env)).to eq("sk-env")
    expect(described_class.source("BOX_KEY", env: env)).to eq(:env)
    expect(fake.reads).to be_empty
  end

  it "falls back to the Keychain when the variable is unset or blank" do
    fake.items["BOX_KEY"] = "sk-keychain"
    expect(described_class.fetch("BOX_KEY", env: {})).to eq("sk-keychain")
    expect(described_class.fetch("BOX_KEY", env: { "BOX_KEY" => "  " })).to eq("sk-keychain")
    expect(described_class.source("BOX_KEY", env: {})).to eq(:keychain)
  end

  it "caches a hit for the process, but not a miss" do
    expect(described_class.fetch("BOX_KEY", env: {})).to be_nil
    expect(described_class.source("BOX_KEY", env: {})).to be_nil
    expect(fake.reads).to eq(%w[BOX_KEY BOX_KEY])

    fake.items["BOX_KEY"] = "sk-keychain"
    3.times { expect(described_class.fetch("BOX_KEY", env: {})).to eq("sk-keychain") }
    expect(fake.reads).to eq(%w[BOX_KEY BOX_KEY BOX_KEY])
  end

  it "reads nothing with SAMAGOTCHI_KEYCHAIN=off" do
    fake.items["BOX_KEY"] = "sk-keychain"
    off = { "SAMAGOTCHI_KEYCHAIN" => "Off" }
    expect(described_class.fetch("BOX_KEY", env: off)).to be_nil
    expect(described_class.from_keychain("BOX_KEY", env: off)).to be_nil
    expect(fake.reads).to be_empty
    expect(described_class.fetch("BOX_KEY", env: off.merge("BOX_KEY" => "sk-env"))).to eq("sk-env")
  end

  it "is off for the whole spec run (bin/chi and workers inherit it)" do
    expect(ENV.fetch("SAMAGOTCHI_KEYCHAIN", nil)).to eq("off")
  end

  it "never shows a key in inspect" do
    fake.items["BOX_KEY"] = "sk-keychain"
    described_class.fetch("BOX_KEY", env: {})
    expect(described_class.inspect).to include("BOX_KEY")
    expect(described_class.inspect).not_to include("sk-keychain")
  end

  it "is available on macOS unless switched off" do
    expect(described_class.available?("darwin24", env: {})).to be(true)
    expect(described_class.available?("darwin24", env: { "SAMAGOTCHI_KEYCHAIN" => "off" })).to be(false)
    expect(described_class.available?("linux-gnu", env: {})).to be(false)
  end

  it "names the command that stores a key" do
    expect(described_class.store_command("BOX_KEY")).to eq("security add-generic-password -s chi -a BOX_KEY -w")
  end
end

RSpec.describe Samagotchi::HostKeys::Keychain do
  let(:dir) { Dir.mktmpdir("host-keys-spec") }

  after { FileUtils.rm_rf(dir) }

  # A fake `security`: records its argv, then runs +body+.
  def security(body)
    path = File.join(dir, "security")
    File.write(path, "#!/bin/sh\necho \"$@\" > #{dir}/argv\n#{body}\n")
    File.chmod(0o755, path)
    path
  end

  def keychain(body, **options)
    described_class.new(security: security(body), host_os: "darwin24", **options)
  end

  it "reads service chi, account VAR, the password alone, and drops the newline" do
    expect(keychain("echo sk-keychain-1").read("BOX_KEY")).to eq("sk-keychain-1")
    expect(File.read(File.join(dir, "argv")).strip).to eq("find-generic-password -s chi -a BOX_KEY -w")
  end

  it "is nil on a non-zero exit (no item, a locked keychain) or an empty answer" do
    expect(keychain("echo 'security: SecKeychainSearchCopyNext' >&2; exit 44").read("BOX_KEY")).to be_nil
    expect(keychain("echo sk-partial; exit 1").read("BOX_KEY")).to be_nil
    expect(keychain("echo").read("BOX_KEY")).to be_nil
  end

  it "is nil off macOS or without the binary, running nothing" do
    path = security("echo sk-keychain-1")
    expect(described_class.new(security: path, host_os: "linux-gnu").read("BOX_KEY")).to be_nil
    expect(described_class.new(security: File.join(dir, "missing"), host_os: "darwin24").read("BOX_KEY")).to be_nil
    expect(File).not_to exist(File.join(dir, "argv"))
  end

  it "kills a hung run at its deadline and logs the name only" do
    allow(Samagotchi::Log).to receive(:warn)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(keychain("echo sk-late; exec sleep 30", timeout: 0.3).read("BOX_KEY")).to be_nil
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
    expect(Samagotchi::Log).to have_received(:warn).with(:config, "keychain_timeout", name: "BOX_KEY", seconds: 0.3)
  end
end
