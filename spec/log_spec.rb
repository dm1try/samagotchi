# frozen_string_literal: true

require "samagotchi/log"
require "samagotchi/config"
require "fileutils"
require "tmpdir"

RSpec.describe Samagotchi::Log do
  let(:dir) { Dir.mktmpdir("samagotchi-log") }
  let(:path) { File.join(dir, "samagotchi.log") }

  after { FileUtils.remove_entry(dir) if File.directory?(dir) }

  def records
    return [] unless File.exist?(path)

    File.open(path) { |io| Samagotchi::LogLine.each_record(io).to_a }
  end

  describe "levels" do
    it "writes records at or above the configured level" do
      described_class.configure(path: path, level: :warn)
      described_class.info(:worker, "start")
      described_class.warn(:worker, "slow")
      described_class.error(:worker, "crash")

      expect(records.map(&:event)).to eq(%w[slow crash])
    end

    it "defaults to log.level from Config (info)" do
      described_class.configure(path: path)
      described_class.debug(:worker, "noise")
      described_class.info(:worker, "start")

      expect(records.map(&:event)).to eq(%w[start])
      expect(described_class.level?(:debug)).to be(false)
    end

    it "takes log.level from SAMAGOTCHI_LOG_LEVEL" do
      stub_const("ENV", ENV.to_h.merge("SAMAGOTCHI_LOG_LEVEL" => "debug"))
      Samagotchi::Config.reload!
      described_class.configure(path: path)

      expect(described_class.level?(:debug)).to be(true)
    ensure
      Samagotchi::Config.instance_variable_set(:@store, nil)
    end
  end

  describe "the lazy default" do
    after { Samagotchi::Config.set_cli_overrides({}) }

    it "resolves the file from Config once, and again after Config.reload!" do
      first = File.join(dir, "first.log")
      second = File.join(dir, "second.log")
      Samagotchi::Config.set_cli_overrides("log.file" => first)
      described_class.info(:worker, "one")
      Samagotchi::Config.set_cli_overrides("log.file" => second)
      described_class.info(:worker, "two")

      expect(File.read(first)).to include(" one")
      expect(File.read(second)).to include(" two")
    end

    it "writes nothing with log.disable" do
      Samagotchi::Config.set_cli_overrides("log.file" => path, "log.disable" => true)
      described_class.warn(:worker, "x")

      expect(File.exist?(path)).to be(false)
    end

    it "only echoes a record logged while it resolves (Config warning about itself)" do
      Samagotchi::Config.set_cli_overrides("log.file" => path)
      allow(Samagotchi::LogPath).to receive(:resolve).and_wrap_original do |original|
        described_class.warn(:config, "bad_value", echo: "Warning: bad value")
        original.call
      end

      expect { described_class.info(:worker, "after") }.to output("Warning: bad value\n").to_stderr
      expect(records.map(&:event)).to eq(%w[after])
    end
  end

  describe "echo (what was a plain warn)" do
    it "prints the text unchanged to stderr and logs it as msg=" do
      described_class.configure(path: path)

      expect { described_class.warn(:hooks, "hook_failed", echo: "[samagotchi:hooks] boom", hook: "x") }
        .to output("[samagotchi:hooks] boom\n").to_stderr
      expect(records.first.fields).to eq("msg" => "[samagotchi:hooks] boom", "hook" => "x")
    end

    it "echoes whatever the level, even with no file" do
      described_class.configure(path: nil, level: :error)

      expect { described_class.warn(:config, "x", echo: "Warning: x") }.to output("Warning: x\n").to_stderr
    end

    it "goes only to the file in a worker (stderr: false)" do
      described_class.configure(path: path, stderr: false)

      expect { described_class.warn(:hooks, "hook_failed", echo: "boom") }.not_to output.to_stderr
      expect(records.first.fields["msg"]).to eq("boom")
    end

    it "is not mirrored a second time with -v" do
      described_class.configure(path: path, level: :debug, mirror: true)

      expect { described_class.warn(:hooks, "hook_failed", echo: "boom") }.to output("boom\n").to_stderr
    end
  end

  describe "session id" do
    it "tags records with the process's session, or an explicit sid:" do
      described_class.configure(path: path)
      described_class.session_id = "0123456789abcdef"
      described_class.info(:worker, "a")
      described_class.info(:web, "b", sid: "fedcba9876543210")

      expect(records.map(&:sid)).to eq(%w[01234567 fedcba98])
    end
  end

  describe "safety" do
    before { described_class.configure(path: path) }

    it "redacts credential-like fields but keeps token counts" do
      described_class.info(:http, "request", api_key: "sk-1", token: "t", authorization: "Bearer x",
                                             prompt_tokens: 12, model_key: "qwen")

      expect(records.first.fields).to eq("api_key" => "[redacted]", "token" => "[redacted]",
                                         "authorization" => "[redacted]", "prompt_tokens" => "12",
                                         "model_key" => "[redacted]")
    end

    it "drops userinfo and query from URLs" do
      described_class.info(:http, "request", url: "https://user:pw@api.test/v1/chat?key=sk-1#frag")

      expect(records.first.fields["url"]).to eq("https://api.test/v1/chat")
    end

    it "caps a payload at 64 KB and says how much was cut" do
      described_class.configure(path: path, level: :debug)
      described_class.debug(:model, "response", payload: "x" * (70 * 1024))

      record = records.first
      expect(record.payload.bytesize).to eq(64 * 1024)
      expect(record.fields["truncated"]).to eq((6 * 1024).to_s)
    end

    it "drops a record it can't format, and keeps logging" do
      expect(described_class.info(:nope, "x")).to be_nil
      expect(described_class.info(:worker, "Bad Event")).to be_nil
      bad = Object.new
      def bad.to_s = raise("no")
      expect(described_class.info(:worker, "x", thing: bad)).to be_nil
      described_class.info(:worker, "ok")

      expect(records.map(&:event)).to eq(%w[ok])
    end

    it "keeps logging after invalid UTF-8" do
      described_class.configure(path: path, level: :debug)
      described_class.debug(:model, "tool_result", payload: "\xFF\xFEbinary".b, tool: "\xC3".b)
      described_class.info(:worker, "after")

      expect(records.map(&:event)).to eq(%w[tool_result after])
    end

    it "writes each record with a single write" do
      writer = instance_double(Samagotchi::DebugLog, write: true, close: nil, path: path)
      allow(Samagotchi::DebugLog).to receive(:new).and_return(writer)
      described_class.configure(path: path, level: :debug)
      described_class.debug(:model, "response", payload: "a\nb\nc", model: "m")

      expect(writer).to have_received(:write).once.with(/response model=m\n    a\n    b\n    c\n\z/)
    ensure
      described_class.reset!
    end
  end

  describe ".exception" do
    it "logs an ERROR with the class, message and the first 20 frames" do
      described_class.configure(path: path)
      error = RuntimeError.new("boom")
      error.set_backtrace((1..30).map { |i| "file.rb:#{i}:in 'm'" })
      described_class.exception(:worker, "crash", error, thread: "bridge")

      record = records.first
      expect(record.to_h).to include(level: "ERROR", event: "crash")
      expect(record.fields).to eq("error" => "RuntimeError", "msg" => "boom", "thread" => "bridge")
      expect(record.payload.lines.size).to eq(20)
    end
  end

  it "only uses tags from the closed list anywhere in lib/" do
    used = Dir[File.expand_path("../lib/**/*.rb", __dir__)].flat_map do |file|
      File.read(file).scan(/\bLog\.(?:debug|info|warn|error|exception)\(\s*:(\w+)/).flatten
    end

    expect(used).not_to be_empty
    expect(used.uniq - Samagotchi::LogLine::TAGS).to eq([])
  end
end
