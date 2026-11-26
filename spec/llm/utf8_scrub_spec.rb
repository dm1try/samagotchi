# frozen_string_literal: true

require "samagotchi/llm/utf8_scrub"

RSpec.describe Samagotchi::LLM::Utf8Scrub do
  describe ".messages" do
    it "is the same Array when every String is valid UTF-8 (or ASCII-only BINARY)" do
      list = [{ role: "user", content: "naïve ✓" }, { role: "tool_response", content: "plain".b }]

      expect(described_class.messages(list)).to equal(list)
    end

    it "reads a BINARY entry as UTF-8 and scrubs invalid bytes, at any depth, the other entries as they are" do
      clean = { role: "user", content: "hi" }
      list = [clean, { role: "system", kind: "note", content: "naïve ✓".b },
              { role: "user", content: [{ type: "text", text: "bad \xFF".dup.force_encoding(Encoding::UTF_8) }] }]

      out = described_class.messages(list)

      expect(out[0]).to equal(clean)
      expect(out[1][:content]).to eq("naïve ✓")
      expect(out[1][:content].encoding).to eq(Encoding::UTF_8)
      expect(out[2][:content].first[:text]).to eq("bad ?")
      expect(described_class.messages(list)).to eq(out)
    end

    it "never changes the entries it was given" do
      raw = "naïve ✓".b
      list = [{ role: "system", kind: "note", content: raw }]

      described_class.messages(list)

      expect(list.first[:content]).to equal(raw)
      expect(raw.encoding).to eq(Encoding::BINARY)
    end
  end
end
