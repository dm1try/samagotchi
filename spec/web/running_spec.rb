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

  it "is cleared by the process that wrote it only" do
    described_class.record(port: 4999, path: path, pid: Process.pid + 1)
    described_class.clear(path: path)
    expect(described_class.port(path: path)).to eq(4999)

    described_class.record(port: 4999, path: path)
    described_class.clear(path: path)
    expect(File.exist?(path)).to be(false)
  end
end
