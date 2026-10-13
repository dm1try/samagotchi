# frozen_string_literal: true

require "samagotchi/llm/dialect"
require "samagotchi/config"

# A Messages host's dialect: the overrides a provider's /v1/messages needs
# on top of Anthropic's own wire.
RSpec.describe Samagotchi::LLM::Dialect do
  before { Samagotchi::ConfigFile.reset_warnings! }

  describe ".for" do
    it "gives the named dialect, and the standard one for none or an unknown name" do
      expect(described_class.for("fireworks")).to be(described_class::FIREWORKS)
      expect(described_class.for("standard")).to be(described_class::STANDARD)
      expect(described_class.for(nil)).to be(described_class::STANDARD)
      expect(described_class.for("nope")).to be(described_class::STANDARD)
    end

    it "keeps the standard wire as Anthropic's, and Fireworks' overrides" do
      expect(described_class::STANDARD).to have_attributes(auth: :x_api_key, thinking_display: "summarized",
                                                           cache_breakpoints: true, session_header: nil)
      expect(described_class::FIREWORKS).to have_attributes(auth: :bearer, thinking_display: nil,
                                                            cache_breakpoints: false, session_header: "x-session-affinity")
    end
  end

  describe ".parse" do
    it "reads a known name on an api: anthropic host (any case), nil when unset" do
      expect(described_class.parse(" Fireworks ", "hosts entry 'fw'", api: :anthropic)).to eq("fireworks")
      expect(described_class.parse(nil, "hosts entry 'fw'", api: :anthropic)).to be_nil
      expect(described_class.parse("", "hosts entry 'fw'", api: :anthropic)).to be_nil
    end

    it "takes the default written out (standard) without a warning" do
      expect { expect(described_class.parse("standard", "hosts entry 's'", api: :anthropic)).to eq("standard") }
        .not_to output.to_stderr
    end

    it "warns once and ignores an unknown name" do
      expect { expect(described_class.parse("splash", "hosts entry 'x'", api: :anthropic)).to be_nil }
        .to output(/hosts entry 'x': dialect must be one of standard, fireworks; ignored/).to_stderr
      expect { described_class.parse("splash", "hosts entry 'x'", api: :anthropic) }.not_to output.to_stderr
    end

    it "warns once and ignores a dialect on a host whose api isn't anthropic" do
      expect { expect(described_class.parse("fireworks", "hosts entry 'o'", api: :openai)).to be_nil }
        .to output(/hosts entry 'o': dialect has no effect on api: openai; ignored/).to_stderr
      expect { expect(described_class.parse("fireworks", "hosts entry 'n'", api: nil)).to be_nil }
        .to output(/hosts entry 'n': dialect has no effect on api: \(none\); ignored/).to_stderr
    end
  end
end
