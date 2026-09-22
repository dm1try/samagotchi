# frozen_string_literal: true

require "samagotchi/tools/execute"
require "tempfile"
require "tmpdir"
require "fileutils"

RSpec.describe Samagotchi::Tools::Execute do
  around do |example|
    original_env = {
      "SAMAGOTCHI_EXECUTE_TRUNCATE_AT_BYTES" => ENV["SAMAGOTCHI_EXECUTE_TRUNCATE_AT_BYTES"],
      "SAMAGOTCHI_EXECUTE_PREVIEW_BYTES" => ENV["SAMAGOTCHI_EXECUTE_PREVIEW_BYTES"],
      "SAMAGOTCHI_EXECUTE_TIMEOUT_SEC" => ENV["SAMAGOTCHI_EXECUTE_TIMEOUT_SEC"],
      "SAMAGOTCHI_CONTEXT_WINDOW_TOKENS" => ENV["SAMAGOTCHI_CONTEXT_WINDOW_TOKENS"],
      "SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN" => ENV["SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN"],
      "SAMAGOTCHI_EXECUTE_TELEMETRY_THRESHOLD_PCT" => ENV["SAMAGOTCHI_EXECUTE_TELEMETRY_THRESHOLD_PCT"]
    }

    example.run
  ensure
    original_env.each { |key, value| ENV[key] = value }
  end

  describe ".name" do
    it "is 'execute'" do
      expect(described_class.name).to eq("execute")
    end
  end

  describe ".call" do
    it "captures stdout and reports exit 0" do
      result = described_class.call("ruby -e 'puts \"hello world\"'")
      expect(result).to include("hello world")
      expect(result).to include("exit: 0")
    end

    it "captures stderr" do
      result = described_class.call("ruby -e '$stderr.puts \"oops\"'")
      expect(result).to include("oops")
    end

    it "captures non-zero exit codes" do
      result = described_class.call("ruby -e 'exit 42'")
      expect(result).to include("exit: 42")
    end

    it "captures Ruby syntax errors" do
      result = described_class.call("ruby -e 'def bad('")
      expect(result).not_to include("exit: 0")
    end

    it "can run an rspec spec file" do
      spec_content = <<~SPEC
        RSpec.describe "math" do
          it "adds correctly" do
            expect(1 + 1).to eq(2)
          end
        end
      SPEC

      tmp = Tempfile.new(["samagotchi_test", "_spec.rb"])
      tmp.write(spec_content)
      tmp.close

      result = described_class.call("bundle exec rspec #{tmp.path} --no-color")
      expect(result).to include("1 example, 0 failures")
    ensure
      tmp&.unlink
    end

    it "truncates oversized stdout with preview metadata" do
      ENV["SAMAGOTCHI_EXECUTE_TRUNCATE_AT_BYTES"] = "100"
      ENV["SAMAGOTCHI_EXECUTE_PREVIEW_BYTES"] = "20"

      result = described_class.call("ruby -e 'print " + ("\"A\"*200") + "'")

      expect(result).to include("stdout:")
      expect(result).to include("truncated=true")
      expect(result).to include("preview_strategy=head_tail")
      expect(result).to include("stdout_bytes=200")
      expect(result).to include("[TRUNCATED_PREVIEW_HEAD]")
      expect(result).to include("[TRUNCATED_PREVIEW_TAIL]")
      expect(result).to include("exit: 0")
    end

    it "includes output telemetry only when threshold is crossed" do
      ENV["SAMAGOTCHI_EXECUTE_TRUNCATE_AT_BYTES"] = "10"
      ENV["SAMAGOTCHI_EXECUTE_PREVIEW_BYTES"] = "40"
      ENV["SAMAGOTCHI_CONTEXT_WINDOW_TOKENS"] = "10"
      ENV["SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN"] = "1"
      ENV["SAMAGOTCHI_EXECUTE_TELEMETRY_THRESHOLD_PCT"] = "50"

      result = described_class.call("ruby -e 'print " + ("\"z\"*100") + "'")

      expect(result).to include("estimated_tokens_for_command_output=")
      expect(result).to include("estimated_window_pct_for_command_output=")
    end

    it "omits output telemetry when threshold is not crossed" do
      ENV["SAMAGOTCHI_EXECUTE_TRUNCATE_AT_BYTES"] = "10"
      ENV["SAMAGOTCHI_EXECUTE_PREVIEW_BYTES"] = "10"
      ENV["SAMAGOTCHI_CONTEXT_WINDOW_TOKENS"] = "100000"
      ENV["SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN"] = "4"
      ENV["SAMAGOTCHI_EXECUTE_TELEMETRY_THRESHOLD_PCT"] = "99"

      result = described_class.call("ruby -e 'print " + ("\"z\"*100") + "'")

      expect(result).not_to include("estimated_tokens_for_command_output=")
      expect(result).not_to include("estimated_window_pct_for_command_output=")
    end

    it "runs in the specified cwd" do
      dir = Dir.mktmpdir("execute_cwd")
      result = described_class.call("ruby -e 'puts Dir.pwd'", cwd: dir)
      expect(result).to include(dir)
      expect(result).to include("exit: 0")
    end

    it "resolves a relative cwd against the project root" do
      subdir = File.join(Dir.pwd, "tmp", "execute_cwd_relative_probe")
      FileUtils.mkdir_p(subdir)
      begin
        result = described_class.call("ruby -e 'puts Dir.pwd'", cwd: "tmp/execute_cwd_relative_probe")
        expect(result).to include(subdir)
        expect(result).to include("exit: 0")
      ensure
        FileUtils.remove_entry(subdir)
      end
    end

    it "returns an error for a nonexistent cwd" do
      result = described_class.call("ruby -e 'puts 1'", cwd: "/definitely/not/here/execute_probe")
      expect(result).to start_with("Error: cwd not found:")
    end

    it "returns a timeout error when command exceeds configured timeout" do
      ENV["SAMAGOTCHI_EXECUTE_TIMEOUT_SEC"] = "1"

      result = described_class.call("ruby -e 'sleep 5'")

      expect(result).to eq("Error: command timed out after 1s")
    end

    it "returns the output captured before the timeout along with the error" do
      ENV["SAMAGOTCHI_EXECUTE_TIMEOUT_SEC"] = "1"

      result = described_class.call(%q(ruby -e '$stdout.sync = true; puts "before"; warn "oops"; sleep 5; puts "never-printed"'))

      expect(result).to start_with("Error: command timed out after 1s\n")
      expect(result).to include("stdout:\nbefore")
      expect(result).to include("stderr:\noops")
      expect(result).not_to include("never-printed")
      expect(result).not_to include("exit:")
    end

    it "keeps partial output from a compound command whose last part hangs" do
      ENV["SAMAGOTCHI_EXECUTE_TIMEOUT_SEC"] = "1"

      result = described_class.call("echo first-part; sleep 5")

      expect(result).to start_with("Error: command timed out after 1s")
      expect(result).to include("first-part")
    end
  end
end
