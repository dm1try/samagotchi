# frozen_string_literal: true

require "json"
require "tmpdir"
require "spec_helper"
require "samagotchi/pages"

# Where pages live: scripts, outputs, the lock, and what a failed run keeps.
RSpec.describe Samagotchi::Pages::Store do
  let(:tmp) { Dir.mktmpdir("pages-store") }
  let(:pages) { Samagotchi::Pages }

  around do |example|
    with_env("XDG_CONFIG_HOME" => File.join(tmp, "config"), "XDG_STATE_HOME" => File.join(tmp, "state")) { example.run }
  ensure
    FileUtils.rm_rf(tmp)
  end

  def script(name, body = "page 'x' do |ui| end\n")
    FileUtils.mkdir_p(pages.scripts_dir)
    File.write(pages.script_path(name), body)
  end

  def sha(name) = described_class.script_sha(name)

  def good_run(name, text: "one")
    described_class.record_run(name, title: "Usage", blocks: [{ "type" => "text", "text" => text }], duration_ms: 12,
                                     script_sha: sha(name))
  end

  it "puts scripts under the config dir and outputs under the state dir" do
    expect(pages.script_path("usage")).to eq(File.join(tmp, "config", "samagotchi", "pages", "usage.rb"))
    expect(described_class.output_path("usage")).to eq(File.join(tmp, "state", "samagotchi", "pages", "usage", "output.json"))
    expect(described_class.lock_path("usage")).to eq(File.join(tmp, "state", "samagotchi", "pages", "usage.lock"))
  end

  it "refuses a bad name before building any path" do
    expect { described_class.output_path("../x") }.to raise_error(Samagotchi::Pages::BadName)
    expect { pages.script_path("Usage") }.to raise_error(Samagotchi::Pages::BadName)
    expect { pages.script_path("a" * 41) }.to raise_error(Samagotchi::Pages::BadName)
    expect(pages.valid_name?("a" * 40)).to be(true)
    expect(pages.valid_name?("-a")).to be(false)
    expect(pages.valid_name?("1-a")).to be(true)
  end

  describe ".read" do
    it "reads a page that never ran" do
      script("usage")
      page = described_class.read("usage")
      expect(page.state).to eq(:never_ran)
      expect(page.blocks).to eq([])
      expect(page.ran_at).to be_nil
      expect(page).not_to be_changed
    end

    it "reads a missing or unreadable output file as never ran" do
      script("usage")
      FileUtils.mkdir_p(described_class.output_dir("usage"))
      File.write(described_class.output_path("usage"), "{not json")
      expect(described_class.read("usage").state).to eq(:never_ran)
    end

    it "reads a good run" do
      script("usage")
      good_run("usage")
      page = described_class.read("usage")
      expect(page.state).to eq(:ok)
      expect(page.title).to eq("Usage")
      expect(page.blocks).to eq([{ "type" => "text", "text" => "one" }])
      expect(Time.iso8601(page.ran_at)).to be_within(60).of(Time.now)
      expect(page.duration_ms).to eq(12)
      expect(page.error).to be_nil
    end

    it "says changed once the script differs from the one that made the blocks" do
      script("usage")
      good_run("usage")
      script("usage", "page 'y' do |ui| end\n")
      expect(described_class.read("usage")).to be_changed
    end

    it "reads a newer chi's file without the keys it doesn't know" do
      script("usage")
      FileUtils.mkdir_p(described_class.output_dir("usage"))
      File.write(described_class.output_path("usage"),
                 JSON.generate("name" => "usage", "title" => "T", "blocks" => [], "ran_at" => "2026-11-23T10:00:00Z",
                               "duration_ms" => 3, "script_sha" => "abc", "error" => nil, "params" => { "days" => 7 }))
      page = described_class.read("usage")
      expect(page.state).to eq(:ok)
      expect(page.to_json_hash).not_to have_key("params")
    end
  end

  describe ".record_failure" do
    it "keeps the last good run's blocks and sets the error" do
      script("usage")
      good_run("usage")
      described_class.record_failure("usage", message: "boom", line: 9, script_sha: "other")
      page = described_class.read("usage")
      expect(page.state).to eq(:failed)
      expect(page.blocks).to eq([{ "type" => "text", "text" => "one" }])
      expect(page.error.message).to eq("boom")
      expect(page.error.line).to eq(9)
      expect(page.error.script_sha).to eq("other")
      expect(page.script_sha).to eq(sha("usage"))
    end

    it "fails a page that never ran good, with no blocks" do
      script("usage")
      described_class.record_failure("usage", message: "boom", line: nil, script_sha: sha("usage"))
      page = described_class.read("usage")
      expect(page.state).to eq(:failed)
      expect(page.blocks).to eq([])
      expect(page.ran_at).to be_nil
    end

    it "is cleared by the next good run" do
      script("usage")
      described_class.record_failure("usage", message: "boom", line: nil, script_sha: sha("usage"))
      good_run("usage", text: "two")
      expect(described_class.read("usage").state).to eq(:ok)
    end
  end

  it "refuses an output over 256 KB, naming the limit and the size" do
    script("usage")
    expect { good_run("usage", text: "x" * (300 * 1024)) }
      .to raise_error(Samagotchi::Pages::Refused, /\Athe output is 300\.\d KB \(at most 256 KB\)\z/)
    expect(File.exist?(described_class.output_path("usage"))).to be(false)
  end

  it "lists every script with a valid name, by name, skipping the others" do
    script("zeta")
    script("alpha")
    File.write(File.join(pages.scripts_dir, "Bad_Name.rb"), "")
    File.write(File.join(pages.scripts_dir, "notes.txt"), "")
    expect(described_class.list.map(&:name)).to eq(%w[alpha zeta])
  end

  describe ".locked" do
    it "raises Busy while another holder has the lock, and frees it after" do
      script("usage")
      described_class.locked("usage") do
        expect { described_class.locked("usage") { nil } }
          .to raise_error(Samagotchi::Pages::Busy, "page usage is already running")
      end
      expect(described_class.locked("usage") { :ran }).to eq(:ran)
    end
  end

  describe ".remove" do
    it "deletes the script, the output folder and the lock file" do
      script("usage")
      good_run("usage")
      described_class.remove("usage")
      expect(File.exist?(pages.script_path("usage"))).to be(false)
      expect(File.exist?(described_class.output_dir("usage"))).to be(false)
      expect(File.exist?(described_class.lock_path("usage"))).to be(false)
    end

    it "refuses an unknown page without making a lock file" do
      expect { described_class.remove("nope") }.to raise_error(Samagotchi::Pages::Missing, "no page nope")
      expect(File.exist?(described_class.lock_path("nope"))).to be(false)
    end

    it "refuses a running page" do
      script("usage")
      described_class.locked("usage") do
        expect { described_class.remove("usage") }.to raise_error(Samagotchi::Pages::Busy)
      end
      expect(File.exist?(pages.script_path("usage"))).to be(true)
    end
  end
end
