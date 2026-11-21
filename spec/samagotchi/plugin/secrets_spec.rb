# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/plugin/context"
require "samagotchi/plugin/secrets"

# ctx.secrets (Plugin::Secrets) on its file store: one 0600 file per secret
# under <state dir>/plugins/<bundle>/secrets, a lock per secret for update.
RSpec.describe Samagotchi::Plugin::Secrets do
  subject(:secrets) { described_class.new(store) }

  let(:root) { Dir.mktmpdir("chi-secrets") }
  let(:env) { { "XDG_STATE_HOME" => root } }
  let(:store) { described_class::FileStore.for_bundle("mcp", env: env) }
  let(:folder) { File.join(root, "samagotchi", "plugins", "mcp", "secrets") }

  after { FileUtils.remove_entry(root) }

  it "keeps a value in a 0600 file in a 0700 folder under the bundle's state, and reads it back each time" do
    expect(secrets.get("linear")).to be_nil
    expect(secrets.set("linear", '{"access_token":"tok"}')).to be(true)
    expect(secrets.get("linear")).to eq('{"access_token":"tok"}')
    expect(File.stat(File.join(folder, "linear")).mode & 0o777).to eq(0o600)
    expect(File.stat(folder).mode & 0o777).to eq(0o700)

    File.write(File.join(folder, "linear"), "changed outside")
    expect(secrets.get("linear")).to eq("changed outside")
    expect(secrets.backend).to eq(:file)
  end

  it "keeps any String up to 16 KB byte for byte: newlines, quotes, non-ASCII" do
    value = "a\nb \"c\" \\ ✓ 日本 #{"x" * 15_000}"
    secrets.set("v", value)
    expect(secrets.get("v")).to eq(value)
    expect(secrets.get("v").encoding).to eq(Encoding::UTF_8)
  end

  it "deletes, saying whether there was one" do
    secrets.set("linear", "v")
    expect(secrets.delete("linear")).to be(true)
    expect(secrets.delete("linear")).to be(false)
    expect(secrets.get("linear")).to be_nil
  end

  it "keeps each bundle's apart: another bundle's 'linear' is another secret" do
    other = described_class.new(described_class::FileStore.for_bundle("other", env: env))
    secrets.set("linear", "mine")
    expect(other.get("linear")).to be_nil
    other.set("linear", "theirs")
    expect(secrets.get("linear")).to eq("mine")
  end

  it "refuses a bad name or value, never naming the value" do
    ["", "Linear", "../x", "a/b", ".hidden", "x" * 65, nil, 3].each do |name|
      expect { secrets.get(name) }.to raise_error(ArgumentError, /a secret's name/), name.inspect
    end
    expect { secrets.set("ok", :sym) }.to raise_error(ArgumentError, /is a String/)
    big = "SECRET-VALUE#{"x" * (16 * 1024)}"
    expect { secrets.set("ok", big) }.to raise_error(ArgumentError) { |e| expect(e.message).not_to include("SECRET-VALUE") }
    expect(secrets.get("ok")).to be_nil
    expect(secrets.get(:linear)).to be_nil
  end

  it "never shows the value in #inspect" do
    secrets.set("linear", "SECRET-VALUE")
    expect(secrets.inspect).to eq("#<Samagotchi::Plugin::Secrets backend=file>")
    expect(store.inspect).not_to include("SECRET")
  end

  it "says the store is unavailable naming the secret only, when the folder can't be written" do
    FileUtils.mkdir_p(File.dirname(folder))
    File.write(folder, "a file where the folder goes")
    expect { secrets.set("linear", "SECRET-VALUE") }
      .to raise_error(described_class::Unavailable, /secret linear/) { |e| expect(e.message).not_to include("SECRET") }
  end

  describe "#update" do
    it "gives the block the value now and keeps what it returns; nil deletes" do
      expect(secrets.update("n") { |old| "#{old.inspect}+1" }).to eq("nil+1")
      expect(secrets.update("n") { |old| "#{old}+1" }).to eq("nil+1+1")
      expect(secrets.update("n") { nil }).to be_nil
      expect(secrets.get("n")).to be_nil
    end

    it "writes nothing when the block returns a bad value" do
      secrets.set("n", "kept")
      expect { secrets.update("n") { 42 } }.to raise_error(ArgumentError)
      expect(secrets.get("n")).to eq("kept")
    end

    it "runs one process's block at a time: the second gets the first's new value" do
      secrets # the folder, before the forks (a lazy let would make one in each)
      started_r, started_w = IO.pipe
      release_r, release_w = IO.pipe
      first = fork do
        secrets.update("token") do
          started_w.puts("in")
          release_r.gets
          "refreshed-by-first"
        end
        exit!(0)
      end
      started_r.gets # the first holds the lock
      seen_r, seen_w = IO.pipe
      second = fork do
        secrets.update("token") do |old|
          seen_w.puts(old.inspect)
          "refreshed-by-second"
        end
        exit!(0)
      end
      release_w.puts("go")
      expect(Process.wait2(first).last.exitstatus).to eq(0)
      expect(Process.wait2(second).last.exitstatus).to eq(0)
      expect(seen_r.gets.chomp).to eq('"refreshed-by-first"')
      expect(secrets.get("token")).to eq("refreshed-by-second")
    ensure
      [started_r, started_w, release_r, release_w, seen_r, seen_w].compact.each(&:close)
    end

    it "raises Busy when another holder keeps the lock past the deadline (set and delete too)" do
      ticks = [0, 31].each
      late = described_class.new(described_class::FileStore.new(folder, clock: -> { ticks.next }, wait: ->(_) {}))
      secrets.update("token") do
        expect { late.update("token") { "x" } }.to raise_error(described_class::Busy, /secret token .* 30 s/)
        ticks = [0, 2].each
        expect { late.set("token", "x", timeout: 1) }.to raise_error(described_class::Busy, /waited 1 s/)
        "mine"
      end
      expect(secrets.get("token")).to eq("mine")
    end
  end

  it "is ctx.secrets, on the store the host gives for the plugin's bundle" do
    stores = {}
    host = Samagotchi::Plugin::Host.new(session_id: -> {}, cwd: -> {},
                                        secrets_store: ->(bundle) { stores[bundle] ||= described_class::MemoryStore.new })
    ctx = Samagotchi::Plugin::Context.new(bundle: "mcp", label: "mcp", settings: {}, host: host)
    ctx.secrets.set("linear", "v")
    expect(stores.keys).to eq(["mcp"])
    expect(stores["mcp"].to_h).to eq("linear" => "v")
  end
end
