# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/remotes"

RSpec.describe Samagotchi::Remotes do
  let(:tmpdir) { Dir.mktmpdir("remotes") }
  let(:path) { File.join(tmpdir, "samagotchi", "remotes.yml") }

  after { FileUtils.rm_rf(tmpdir) }

  def entry(name, url = "http://192.168.1.29:4567", token: "t-#{name}")
    described_class::Entry.new(name: name, url: url, token: token)
  end

  it "lives in $XDG_CONFIG_HOME/samagotchi/remotes.yml" do
    expect(described_class.path(env: { "XDG_CONFIG_HOME" => "/cfg" })).to eq("/cfg/samagotchi/remotes.yml")
  end

  it "saves remotes by name in a file only its owner reads, replaces one of the same name, and removes one" do
    expect(described_class.all(path: path)).to eq([])
    described_class.put(entry("studio"), path: path)
    described_class.put(entry("box", token: nil), path: path)
    described_class.put(entry("studio", "http://192.168.1.30:4567"), path: path)

    expect(File.stat(path).mode & 0o777).to eq(0o600)
    expect(described_class.all(path: path).map(&:to_h)).to eq([
      { name: "box", url: "http://192.168.1.29:4567", token: nil },
      { name: "studio", url: "http://192.168.1.30:4567", token: "t-studio" }
    ])
    expect(described_class.find("studio", path: path).url).to eq("http://192.168.1.30:4567")
    expect(described_class.remove("box", path: path)).to be(true)
    expect(described_class.remove("box", path: path)).to be(false)
    expect { described_class.find("box", path: path) }
      .to raise_error(described_class::NotFound, "no remote box (chi remote ls lists them; chi remote add NAME URL adds one)")
  end

  it "rewrites the file under its lock, so two chi remote add at once keep both" do
    described_class.put(entry("studio"), path: path)
    put = nil
    File.open("#{path}.lock", File::RDWR | File::CREAT) do |lock|
      lock.flock(File::LOCK_EX)
      thread = Thread.new { put = described_class.put(entry("box"), path: path) }
      # Blocked on the lock (a put that didn't take it would be done).
      wait_for("the put to wait for the lock") { thread.status == "sleep" }
      expect(described_class.all(path: path).map(&:name)).to eq(%w[studio])
      described_class.send(:write, [entry("studio"), entry("laptop")], path) # another put, between its read and write
      lock.flock(File::LOCK_UN)
      join!(thread, "the put")
    end
    expect(put).not_to be_nil
    expect(described_class.all(path: path).map(&:name)).to eq(%w[box laptop studio])
    expect(File.stat(path).mode & 0o777).to eq(0o600)

    File.open("#{path}.lock", File::RDWR | File::CREAT) do |lock|
      lock.flock(File::LOCK_EX)
      thread = Thread.new { described_class.remove("box", path: path) }
      wait_for("the remove to wait for the lock") { thread.status == "sleep" }
      lock.flock(File::LOCK_UN)
      join!(thread, "the remove")
    end
    expect(described_class.all(path: path).map(&:name)).to eq(%w[laptop studio])
  end

  it "never shows the token in inspect" do
    expect(entry("studio").inspect).not_to include("t-studio")
    expect(entry("studio").inspect).to include("[redacted]")
  end

  it "names a file it can't read" do
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "remotes: [1, 2]\n")
    expect { described_class.all(path: path) }.to raise_error(described_class::Invalid, /remotes: is a map of names/)
    File.write(path, "remotes:\n  studio: {token: x}\n")
    expect { described_class.all(path: path) }.to raise_error(described_class::Invalid, /remote studio has no url/)
    File.write(path, "remotes: [\n")
    expect { described_class.all(path: path) }.to raise_error(described_class::Invalid)
  end

  it "takes chi web's address as http(s)://HOST:PORT, 4567 by default, and nothing else" do
    expect(described_class.normalize_url("192.168.1.29")).to eq("http://192.168.1.29:4567")
    expect(described_class.normalize_url("http://192.168.1.29:45913/")).to eq("http://192.168.1.29:45913")
    expect(described_class.normalize_url("HTTPS://Studio.Local")).to eq("https://studio.local:4567")
    expect(described_class.normalize_url("http://[fe80::1]:80")).to eq("http://[fe80::1]:80")
    ["ftp://x", "http://192.168.1.29:4567/api", "http://x:1?a=b", "http://"].each do |bad|
      expect { described_class.normalize_url(bad) }.to raise_error(described_class::Invalid), bad
    end
  end

  it "takes a short name of letters, digits, - and _" do
    expect(described_class.check_name!("studio-2_b")).to eq("studio-2_b")
    ["", "-x", "a b", "a/b", "x" * 41].each do |bad|
      expect { described_class.check_name!(bad) }.to raise_error(described_class::Invalid), bad
    end
  end
end
