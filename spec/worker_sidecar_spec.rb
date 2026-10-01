# frozen_string_literal: true

require "tmpdir"
require "socket"
require "spec_helper"
require "samagotchi/worker_sidecar"

RSpec.describe Samagotchi::WorkerSidecar do
  let(:dir) { Dir.mktmpdir("worker-sidecar") }
  after { FileUtils.rm_rf(dir) }

  it "writes bridge.json in the Bridge's key order, input_format only when set, and reads it back" do
    sidecar = described_class.new(port: 4321, bind: "127.0.0.1", session_id: "s1", started_at: "2026-09-30T10:00:00.000+02:00",
                                  version: "0.7.0", input_format: 3)
    sidecar.write(File.join(dir, "s1"))

    expect(JSON.parse(File.read(File.join(dir, "s1", "bridge.json"))).keys)
      .to eq(%w[port bind session_id started_at version input_format])
    expect(described_class.read(File.join(dir, "s1"))).to eq(sidecar)

    sidecar.with(input_format: nil).write(dir)
    expect(JSON.parse(File.read(described_class.path(dir)))).not_to have_key("input_format")
  end

  it "reads what an older worker wrote (no version, a string port) and is nil for none, a broken one or a non-object" do
    File.write(described_class.path(dir), JSON.generate(port: "4321", session_id: "s1"))
    expect(described_class.read(dir)).to have_attributes(port: 4321, version: nil, input_format: nil)

    File.write(described_class.path(dir), JSON.generate(session_id: "s1"))
    expect(described_class.read(dir).port).to eq(0)

    ["{", "[1]"].each do |body|
      File.write(described_class.path(dir), body)
      expect(described_class.read(dir)).to be_nil, body
    end
    expect(described_class.read(File.join(dir, "none"))).to be_nil
  end

  it "is .live while its port takes a connect; a stale one is nil, and removed only with unlink: true" do
    server = TCPServer.new("127.0.0.1", 0)
    described_class.new(port: server.local_address.ip_port, version: "0.8.1").write(dir)
    expect(described_class.live(dir, unlink: false)).to have_attributes(port: server.local_address.ip_port, version: "0.8.1")
    expect(described_class.live_port(dir, unlink: true)).to eq(server.local_address.ip_port)

    server.close
    expect(described_class.live(dir, unlink: false)).to be_nil
    expect(File.exist?(described_class.path(dir))).to be(true)
    expect(described_class.live_port(dir, unlink: true)).to be_nil
    expect(File.exist?(described_class.path(dir))).to be(false)
  ensure
    server&.close unless server&.closed?
  end
end
