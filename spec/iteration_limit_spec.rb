# frozen_string_literal: true

require "samagotchi/iteration_limit"

RSpec.describe Samagotchi::IterationLimit do
  it "gives a turn 100 iterations, and a --no-interrupt one 1000" do
    expect(described_class.for).to eq(100)
    expect(described_class.for(no_interrupt: false)).to eq(100)
    expect(described_class.for(no_interrupt: true)).to eq(1000)
  end

  describe "turn.max_iterations" do
    it "sets a turn's limit (env SAMAGOTCHI_TURN_MAX_ITERATIONS), and --no-interrupt keeps its 1000" do
      with_env("SAMAGOTCHI_TURN_MAX_ITERATIONS" => "3") do
        expect(described_class.for).to eq(3)
        expect(described_class.for(no_interrupt: true)).to eq(1000)
      end
    end

    it "is never lowered by --no-interrupt: a limit above 1000 stays" do
      with_env("SAMAGOTCHI_TURN_MAX_ITERATIONS" => "2500") do
        expect(described_class.for(no_interrupt: true)).to eq(2500)
      end
    end

    it "is read from config.yml" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "samagotchi"))
        File.write(File.join(dir, "samagotchi", "config.yml"), "turn:\n  max_iterations: 7\n")
        with_env("XDG_CONFIG_HOME" => dir, "SAMAGOTCHI_TURN_MAX_ITERATIONS" => nil) do
          expect(described_class.for).to eq(7)
        end
      end
    end

    it "falls back to 100 with a warning on a value below 1 or not a number" do
      %w[0 -5 many].each do |raw|
        with_env("SAMAGOTCHI_TURN_MAX_ITERATIONS" => raw) do
          expect { expect(described_class.for).to eq(100) }.to output(/turn.max_iterations/).to_stderr
        end
      end
    end
  end
end
