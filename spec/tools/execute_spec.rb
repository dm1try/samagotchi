# frozen_string_literal: true

require "samagotchi/tools/execute"
require "tempfile"

RSpec.describe Samagotchi::Tools::Execute do
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
  end
end
