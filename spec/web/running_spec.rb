# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/web/running"

# Where this machine's chi web listens (web.json), for chi share's link.
RSpec.describe Samagotchi::Web::Running do
  let(:dir) { Dir.mktmpdir("web-running") }
  let(:path) { described_class.path(state_dir: File.join(dir, "samagotchi", "sessions")) }

  after { FileUtils.rm_rf(dir) }

  it "lives next to the sessions folder, as web-token does" do
    expect(path).to eq(File.join(dir, "samagotchi", "web.json"))
  end

  it "names the recorded port, and nothing without a file or with a broken one" do
    expect(described_class.port(path: path)).to be_nil

    described_class.record(port: 4999, path: path)
    expect(described_class.port(path: path)).to eq(4999)

    File.write(path, "{not json")
    expect(described_class.port(path: path)).to be_nil
  end

  describe ".live_public_url" do
    let(:origin) { "https://chi-host.example-tailnet.ts.net" }
    let(:answers) { {} }
    let(:probe) { ->(port) { answers.fetch(port, :free) } }

    def live = described_class.live_public_url(path: path, probe: probe)

    it "is the recorded https origin while the process that wrote it answers on its port" do
      described_class.record(port: 4999, path: path, public_url: origin)
      expect(JSON.parse(File.read(path))).to eq({ "pid" => Process.pid, "port" => 4999, "public_url" => origin })
      answers[4999] = { "app" => "chi-web", "pid" => Process.pid }
      expect(live).to eq(Samagotchi::Web::PublicUrl.from_config(url: origin))
    end

    it "keeps a tunnel's identity header with it (a link bound to an email needs one)" do
      described_class.record(port: 4999, path: path, public_url: origin, identity_header: "Tailscale-User-Login")
      answers[4999] = { "app" => "chi-web", "pid" => Process.pid }
      expect(live.identity_header).to eq("Tailscale-User-Login")
    end

    it "is nil for a record left behind: another pid on the port, nothing there, a dead pid" do
      described_class.record(port: 4999, path: path, public_url: origin)
      answers[4999] = { "app" => "chi-web", "pid" => Process.pid + 1 }
      expect(live).to be_nil
      answers.clear
      expect(live).to be_nil
      dead = Process.spawn("true")
      Process.wait(dead)
      described_class.record(port: 4999, path: path, public_url: origin, pid: dead)
      answers[4999] = { "app" => "chi-web", "pid" => dead }
      expect(live).to be_nil
    end

    it "is nil without a public_url or with one that isn't an https origin" do
      answers[4999] = { "app" => "chi-web", "pid" => Process.pid }
      described_class.record(port: 4999, path: path)
      expect(JSON.parse(File.read(path))).not_to have_key("public_url")
      expect(live).to be_nil
      described_class.record(port: 4999, path: path, public_url: "http://chi-host.example-tailnet.ts.net")
      expect(live).to be_nil
    end
  end

  it "is cleared by the process that wrote it only" do
    described_class.record(port: 4999, path: path, pid: Process.pid + 1)
    described_class.clear(path: path)
    expect(described_class.port(path: path)).to eq(4999)

    described_class.record(port: 4999, path: path)
    described_class.clear(path: path)
    expect(File.exist?(path)).to be(false)
  end
end
