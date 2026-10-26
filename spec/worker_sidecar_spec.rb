# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/worker_sidecar"

RSpec.describe Samagotchi::WorkerSidecar do
  let(:dir) { Dir.mktmpdir("worker-sidecar") }

  after { FileUtils.rm_rf(dir) }

  it "writes bridge.json in the Bridge's key order, input_format, epoch and secret only when set, and reads it back" do
    sidecar = described_class.new(port: 4321, bind: "127.0.0.1", session_id: "s1", started_at: "2026-09-30T10:00:00.000+02:00",
                                  version: "0.7.0", input_format: 3, features: ["restart"], epoch: "a1b2c3d4",
                                  secret: "5e" * 32)
    sidecar.write(File.join(dir, "s1"))

    expect(JSON.parse(File.read(File.join(dir, "s1", "bridge.json"))).keys)
      .to eq(%w[port bind session_id started_at version input_format features epoch secret])
    expect(described_class.read(File.join(dir, "s1"))).to eq(sidecar)

    sidecar.with(input_format: nil, epoch: nil, secret: nil).write(dir)
    expect(JSON.parse(File.read(described_class.path(dir)))).not_to include("input_format", "epoch", "secret")
  end

  it "reads a secret of another shape (not hex, too short, a number) as none: it never reaches a header" do
    [("5e" * 32) + "\r\nX-Evil: 1", "abc", 1234, "zz" * 32].each do |secret|
      File.write(described_class.path(dir), JSON.generate(port: 4321, secret: secret))
      expect(described_class.read(dir).secret).to be_nil, secret.inspect
    end
  end

  it "is 0600 from the moment the file exists, never readable by others while it is written" do
    modes = []
    allow(File).to receive(:open).and_wrap_original do |original, *args, **opts, &block|
      original.call(*args, **opts) do |io|
        modes << (io.stat.mode & 0o777)
        block.call(io)
      end
    end
    described_class.new(port: 4321, secret: "5e" * 32).write(dir)

    expect(modes).to eq([0o600])
  end

  # Only this user's chi reads it (chi web, the TUI, chi send): no other
  # account on a shared host learns a worker's port from it.
  it "writes bridge.json readable by this user only (0600)" do
    described_class.new(port: 4321, session_id: "s1").write(dir)
    expect(File.stat(described_class.path(dir)).mode & 0o777).to eq(0o600)
  end

  it "reads what an older worker wrote (no version, no epoch, a string port) and is nil for none, a broken one or a non-object" do
    File.write(described_class.path(dir), JSON.generate(port: "4321", session_id: "s1"))
    expect(described_class.read(dir)).to have_attributes(port: 4321, version: nil, input_format: nil, features: [],
                                                         epoch: nil)

    File.write(described_class.path(dir), JSON.generate(session_id: "s1"))
    expect(described_class.read(dir).port).to eq(0)

    ["{", "[1]"].each do |body|
      File.write(described_class.path(dir), body)
      expect(described_class.read(dir)).to be_nil, body
    end
    expect(described_class.read(File.join(dir, "none"))).to be_nil
  end
end
