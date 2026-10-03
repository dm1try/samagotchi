# frozen_string_literal: true

require "spec_helper"
require_relative "support/fake_provider_server"
require "socket"
require "tmpdir"
require "samagotchi/live_versions"

RSpec.describe Samagotchi::LiveVersions do
  # Real localhost HTTP (the chi web probe): other suites may enable WebMock.
  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:state_dir) { Dir.mktmpdir("live-versions") }
  let(:servers) { [] }

  after do
    servers.each(&:close)
    FileUtils.remove_entry(state_dir)
  end

  def listener
    TCPServer.new("127.0.0.1", 0).tap { |s| servers << s }
  end

  def sidecar(id, port:, version: nil)
    FileUtils.mkdir_p(File.join(state_dir, id))
    data = { "port" => port, "session_id" => id }
    data["version"] = version if version
    File.write(File.join(state_dir, id, "bridge.json"), JSON.generate(data))
  end

  it "lists live workers with their version, unknown for an older sidecar, and skips dead ones without removing them" do
    sidecar("a", port: listener.addr[1], version: "0.3.1")
    sidecar("b", port: listener.addr[1])
    dead = listener.addr[1]
    servers.pop.close
    sidecar("c", port: dead, version: "0.2.0")

    expect(described_class.workers(state_dir: state_dir).map(&:to_h))
      .to eq([{ session_id: "a", version: "0.3.1", restart: false }, { session_id: "b", version: nil, restart: false }])
    expect(described_class.stale_workers("0.3.1", state_dir: state_dir).map(&:session_id)).to eq(["b"])
    expect(File).to exist(File.join(state_dir, "c", "bridge.json"))
  end

  it "skips a broken sidecar and one that is not an object" do
    sidecar("a", port: listener.addr[1], version: "0.3.1")
    { "b" => "{", "c" => "[1]" }.each do |id, body|
      FileUtils.mkdir_p(File.join(state_dir, id))
      File.write(File.join(state_dir, id, "bridge.json"), body)
    end

    expect(described_class.workers(state_dir: state_dir).map(&:session_id)).to eq(["a"])
  end

  describe ".web_version" do
    def serve(body, status: "200 OK")
      server = listener
      Thread.new do
        client = server.accept
        client.readpartial(4096)
        client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
      rescue IOError
        nil
      end
      server.addr[1]
    end

    it "reads a chi web's version from /api/info" do
      port = serve(JSON.generate(app: "chi-web", version: "0.2.0"))
      expect(described_class.web_version("127.0.0.1", port)).to eq("0.2.0")
    end

    it "is nil for something else on the port, or nothing" do
      expect(described_class.web_version("127.0.0.1", serve("{}"))).to be_nil
      port = listener.addr[1]
      servers.pop.close
      expect(described_class.web_version("127.0.0.1", port)).to be_nil
    end
  end
end
