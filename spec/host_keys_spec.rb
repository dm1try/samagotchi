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

  # The fake runs from the env it inherits; restore whatever was there.
  around do |example|
    was = ENV.fetch("FAKE_SECURITY_DIR", nil)
    ENV["FAKE_SECURITY_DIR"] = dir
    example.run
  ensure
    was ? ENV["FAKE_SECURITY_DIR"] = was : ENV.delete("FAKE_SECURITY_DIR")
    FileUtils.rm_rf(dir)
  end

  # The checked-in fake `security` (spec/fixtures/host_keys/security): it
  # records its argv, then runs +body+. Never a script written here: a
  # just-written executable's first exec waits on macOS's malware scan,
  # which a busy suite has seen outlast the 5 s deadline (a nil read).
  def security(body)
    File.write(File.join(dir, "body.sh"), "#{body}\n")
    File.expand_path("fixtures/host_keys/security", __dir__)
  end

  # A roomy deadline unless the example tests it: a busy machine's exec is
  # not what these examples are about.
  def keychain(body, timeout: 30)
    described_class.new(security: security(body), host_os: "darwin24", timeout: timeout)
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
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < time_bound(5, below: 30)
    expect(Samagotchi::Log).to have_received(:warn).with(:config, "keychain_timeout", name: "BOX_KEY", seconds: 0.3)
  end

  # A stall inside Process.spawn itself (macOS holding a first exec while it
  # scans the binary), staged without a new binary: the child's stdin is a
  # FIFO, whose open blocks the child before its exec until a writer comes.
  it "cuts a stalled spawn at the deadline and kills the pid that turns up late" do
    allow(Samagotchi::Log).to receive(:warn)
    fifo = File.join(dir, "stdin")
    File.mkfifo(fifo)
    pids = Queue.new
    spawner = lambda do |*argv, **opts|
      Process.spawn(*argv, **opts, in: fifo).tap { |pid| pids << pid }
    end
    reader = described_class.new(security: security("exec sleep 30"), host_os: "darwin24",
                                 timeout: 0.3, spawner: spawner)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(reader.read("BOX_KEY")).to be_nil
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < time_bound(2, below: 30)
    expect(Samagotchi::Log).to have_received(:warn).with(:config, "keychain_timeout", name: "BOX_KEY", seconds: 0.3)

    File.open(fifo, "w", &:close) # the spawn returns now, past the deadline
    pid = pids.pop(timeout: 10)
    expect(pid).to be_a(Integer)
    # Killed and reaped, not left sleeping (a zombie still answers kill 0).
    wait_for("the timed-out spawn to be killed and reaped") { process_gone?(pid) }
  end
end
