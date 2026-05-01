# frozen_string_literal: true

require "samagotchi/tools/read"
require "tmpdir"

RSpec.describe Samagotchi::Tools::Read do
  around do |example|
    original_env = {
      "SAMAGOTCHI_READ_HARD_MAX_BYTES" => ENV["SAMAGOTCHI_READ_HARD_MAX_BYTES"],
      "SAMAGOTCHI_READ_TRUNCATE_AT_BYTES" => ENV["SAMAGOTCHI_READ_TRUNCATE_AT_BYTES"],
      "SAMAGOTCHI_READ_PREVIEW_BYTES" => ENV["SAMAGOTCHI_READ_PREVIEW_BYTES"],
      "SAMAGOTCHI_CONTEXT_WINDOW_TOKENS" => ENV["SAMAGOTCHI_CONTEXT_WINDOW_TOKENS"],
      "SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN" => ENV["SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN"],
      "SAMAGOTCHI_READ_TELEMETRY_THRESHOLD_PCT" => ENV["SAMAGOTCHI_READ_TELEMETRY_THRESHOLD_PCT"]
    }

    example.run
  ensure
    original_env.each { |key, value| ENV[key] = value }
  end

  describe ".name" do
    it "is 'read'" do
      expect(described_class.name).to eq("read")
    end
  end

  describe ".call" do
    it "reads an existing file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "test.txt")
        File.write(path, "hello samagotchi")
        expect(described_class.call(path)).to eq("hello samagotchi")
      end
    end

    it "returns an error string for a missing file" do
      expect(described_class.call("/nonexistent/file.rb")).to include("Error")
    end

    it "strips surrounding whitespace from the path" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "test.txt")
        File.write(path, "content")
        expect(described_class.call("  #{path}  ")).to eq("content")
      end
    end

    it "returns a truncated head+tail preview for files over truncate limit" do
      ENV["SAMAGOTCHI_READ_TRUNCATE_AT_BYTES"] = "50"
      ENV["SAMAGOTCHI_READ_PREVIEW_BYTES"] = "20"

      Dir.mktmpdir do |dir|
        path = File.join(dir, "large.txt")
        content = "A" * 40 + "B" * 40 + "C" * 40
        File.write(path, content)

        result = described_class.call(path)

        expect(result).to include("truncated=true")
        expect(result).to include("preview_strategy=head_tail")
        expect(result).to include("file_bytes=120")
        expect(result).to include("[TRUNCATED_PREVIEW_HEAD]")
        expect(result).to include("[TRUNCATED_PREVIEW_TAIL]")
      end
    end

    it "returns an error for files over the hard max limit" do
      ENV["SAMAGOTCHI_READ_HARD_MAX_BYTES"] = "100"

      Dir.mktmpdir do |dir|
        path = File.join(dir, "too_large.txt")
        File.write(path, "x" * 120)

        result = described_class.call(path)
        expect(result).to include("Error: file too large")
        expect(result).to include("hard limit 100 bytes")
      end
    end

    it "includes token telemetry only when preview payload crosses threshold" do
      ENV["SAMAGOTCHI_READ_TRUNCATE_AT_BYTES"] = "10"
      ENV["SAMAGOTCHI_READ_PREVIEW_BYTES"] = "40"
      ENV["SAMAGOTCHI_CONTEXT_WINDOW_TOKENS"] = "10"
      ENV["SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN"] = "1"
      ENV["SAMAGOTCHI_READ_TELEMETRY_THRESHOLD_PCT"] = "50"

      Dir.mktmpdir do |dir|
        path = File.join(dir, "threshold.txt")
        File.write(path, "z" * 100)

        result = described_class.call(path)
        expect(result).to include("estimated_tokens_for_preview=")
        expect(result).to include("estimated_window_pct_for_preview=")
      end
    end

    it "omits token telemetry when preview payload is below threshold" do
      ENV["SAMAGOTCHI_READ_TRUNCATE_AT_BYTES"] = "10"
      ENV["SAMAGOTCHI_READ_PREVIEW_BYTES"] = "10"
      ENV["SAMAGOTCHI_CONTEXT_WINDOW_TOKENS"] = "100000"
      ENV["SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN"] = "4"
      ENV["SAMAGOTCHI_READ_TELEMETRY_THRESHOLD_PCT"] = "99"

      Dir.mktmpdir do |dir|
        path = File.join(dir, "below_threshold.txt")
        File.write(path, "z" * 100)

        result = described_class.call(path)
        expect(result).not_to include("estimated_tokens_for_preview=")
        expect(result).not_to include("estimated_window_pct_for_preview=")
      end
    end
  end
end
