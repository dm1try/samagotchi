# frozen_string_literal: true

require "spec_helper"
require "samagotchi/config"
require "samagotchi/llm_context_override"

RSpec.describe Samagotchi::LLMContextOverride do
  describe ".update" do
    it "sets what the words name and keeps the rest; default unsets a field" do
      current = described_class.new(strategy: [:stale], apply: :turn_end)

      updated = described_class.update(current, strategy: "stale,forget", budget_tokens: "64k")
      expect(updated).to eq(described_class.new(strategy: %i[stale forget], apply: :turn_end, budget_tokens: 64_000))
      expect(described_class.update(updated, apply: "default", strategy: "Default"))
        .to eq(described_class.new(budget_tokens: 64_000))
      expect(described_class.update(nil, apply: "next_request")).to eq(described_class.new(apply: :next_request))
    end

    it "reads none and off as values, set on purpose (not unset)" do
      expect(described_class.update(nil, strategy: "none", budget_tokens: "off"))
        .to eq(described_class.new(strategy: [], budget_tokens: 0))
    end

    it "reads a strategy as a comma, space or | list, and a budget as tokens or k" do
      expect(described_class.parse_strategy("stale forget")).to eq(%i[stale forget])
      expect(described_class.parse_strategy("STALE|forget,stale")).to eq(%i[stale forget])
      expect(described_class.parse_strategy("forget stale")).to eq(%i[stale forget])
      expect(described_class.parse_budget_tokens("48000")).to eq(48_000)
      expect(described_class.parse_budget_tokens("48_000")).to eq(48_000)
      expect(described_class.parse_budget_tokens("48K")).to eq(48_000)
      expect(described_class.parse_budget_tokens("0")).to eq(0)
      expect(described_class.parse_budget_tokens("4k")).to eq(4000)
      expect(described_class.parse_budget_tokens("10000k")).to eq(10_000_000)
    end

    it "refuses a budget under 4k or over 10M tokens (off is 0)" do
      expect { described_class.parse_budget_tokens("3999") }
        .to raise_error(ArgumentError, "a budget of 3999 tokens is out of range: 4000 (4k) to 10000000 (10000k), or off")
      expect { described_class.parse_budget_tokens("10001k") }.to raise_error(ArgumentError, /out of range/)
    end

    it "refuses a word that isn't a value, saying what is" do
      expect { described_class.update(nil, strategy: "stale,summarize") }
        .to raise_error(ArgumentError, /unknown llm_context strategy summarize \(none, or a list of stale, forget\)/)
      expect { described_class.update(nil, apply: "later") }
        .to raise_error(ArgumentError, /unknown llm_context apply later \(payoff, next_request, turn_end\)/)
      expect { described_class.update(nil, budget_tokens: "-5") }
        .to raise_error(ArgumentError, /a budget is a number of tokens \(64000 or 64k\) or off/)
      expect { described_class.update(nil, strategy: " ") }.to raise_error(ArgumentError, /a strategy is none or a list/)
    end
  end

  describe "the session file" do
    it "keeps the set fields only, and nothing for an empty one" do
      override = described_class.new(strategy: %i[stale forget], budget_tokens: 0)

      expect(override.to_file).to eq("strategy" => %w[stale forget], "budget_tokens" => 0)
      expect(described_class.from_file(override.to_file)).to eq(override)
      expect(described_class.new.to_file).to be_nil
      expect(described_class.from_file(nil)).to be_nil
      expect(described_class.from_file({})).to be_nil
    end

    it "leaves a field it can't read unset, without a warning, and names it as unread" do
      data = { "apply" => "later", "budget_tokens" => 12, "strategy" => %w[forget stale] }

      expect { expect(described_class.from_file(data)).to eq(described_class.new(strategy: %i[stale forget])) }
        .not_to output.to_stderr
      expect(described_class.unread(data)).to eq("apply" => "later", "budget_tokens" => 12)
      expect(described_class.from_file("strategy" => %w[stale summarize])).to be_nil
      expect(described_class.unread("strategy" => %w[stale summarize])).to eq("strategy" => %w[stale summarize])
    end
  end

  it "words its fields as /llm-context shows them" do
    expect(described_class.word(:strategy, [])).to eq("none")
    expect(described_class.word(:strategy, %i[stale forget])).to eq("stale, forget")
    expect(described_class.word(:budget_tokens, 0)).to eq("off")
    expect(described_class.word(:budget_tokens, 64_000)).to eq("64000")
    expect(described_class.word(:apply, nil)).to be_nil
  end
end
