# frozen_string_literal: true

require "samagotchi/launch_mode"

RSpec.describe Samagotchi::LaunchMode do
  def resolve(shared_config, **options) = described_class.resolve(options, shared_config: shared_config)

  context "with session.shared off" do
    it "runs a plain REPL" do
      expect(resolve(false)).to eq([:repl, nil])
      expect(resolve(false, resume: "s1")).to eq([:repl, nil])
      expect(resolve(false, prompt: "hi")).to eq([:repl, nil])
    end

    it "attaches for an explicit --shared or --attach" do
      expect(resolve(false, shared: true)).to eq([:attached, nil])
      expect(resolve(false, attach: "s1")).to eq([:attached, nil])
    end
  end

  context "with session.shared on" do
    it "attaches plain chi and chi --resume ID" do
      expect(resolve(true)).to eq([:attached, nil])
      expect(resolve(true, resume: "s1")).to eq([:attached, nil])
    end

    it "runs a plain REPL for --no-shared" do
      expect(resolve(true, shared: false)).to eq([:repl, nil])
    end

    it "never attaches a --non-interactive one-shot" do
      expect(resolve(true, prompt: "hi", non_interactive: true)).to eq([:repl, nil])
    end

    it "attaches -p, which then sends the prompt" do
      expect(resolve(true, prompt: "hi")).to eq([:attached, nil])
    end

    {
      { model: "m" } => "--model",
      { memories: ["a"] } => "--memory",
      { verbose: true } => "--verbose",
      { no_interrupt: true } => "--no-interrupt"
    }.each do |options, flag|
      it "runs a plain REPL, with a note, for #{flag}" do
        expect(resolve(true, **options)).to eq([:repl, "(session.shared: #{flag} runs in a plain REPL)"])
      end
    end

    it "keeps the explicit flags' behavior" do
      expect(resolve(true, shared: true, model: "m")).to eq([:attached, nil])
      expect(resolve(true, attach: "s1")).to eq([:attached, nil])
    end
  end
end
