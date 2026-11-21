# frozen_string_literal: true

require "spec_helper"
require "samagotchi/block_fix"

# A failed block's place in an answer, the side request asking for it again,
# and the checks on what came back.
RSpec.describe Samagotchi::BlockFix do
  fixtures = Dir[File.expand_path("fixtures/inline_widgets/*.yml", __dir__)].reject { |f| f.end_with?("manifest.yml") }

  describe ".key" do
    it "is 32 hex characters over the language and the normalised source" do
      key = described_class.key("mermaid", "graph TD\n  A-->B\n")
      expect(key).to match(/\A\h{32}\z/)
      expect(described_class.key("mermaid", "graph TD\r\n  A-->B")).to eq(key)
      expect(described_class.key("chi-ui", "graph TD\n  A-->B\n")).not_to eq(key)
    end
  end

  describe ".locate and .replace" do
    def body_of(text, place) = text.lines[place.first..place.last].join

    shapes = {
      "plain" => ->(src) { "Text\n\n```chi-ui\n#{src}```\n\nAfter.\n" },
      "a 2-space list item" => ->(src) { "- item\n\n  ```chi-ui\n#{src.gsub(/^(?=.)/, "  ")}  ```\n" },
      "a 4-space list item" => ->(src) { "1. item\n\n    ```chi-ui\n#{src.gsub(/^(?=.)/, "    ")}    ```\n" },
      "a nested list item" => ->(src) { "- a\n  - b\n\n    ```chi-ui\n#{src.gsub(/^(?=.)/, "    ")}    ```\n" },
      "after a paragraph" => ->(src) { "Here it is:\n```chi-ui\n#{src}```\n" },
      "tildes" => ->(src) { "~~~chi-ui\n#{src}~~~\n" },
      "CRLF line ends" => ->(src) { "Text\r\n\r\n```chi-ui\r\n#{src.gsub("\n", "\r\n")}```\r\n" }
    }

    shapes.each do |shape, wrap|
      it "finds every fixture in #{shape} and replaces it in place" do
        fixtures.each do |file|
          source = File.read(file)
          text = wrap.call(source)
          place = described_class.locate(text, lang: "chi-ui", source: source)
          expect(place).not_to be_nil, "#{File.basename(file)} not found in #{shape}"

          fixed = "type: picks\nrows:\n  - id: a\n    text: fixed\n    options: [x, y]\n"
          patched = described_class.replace(text, place, fixed)
          expect(described_class.locate(patched, lang: "chi-ui", source: fixed)).not_to be_nil
          expect(described_class.locate(patched, lang: "chi-ui", source: source)).to be_nil
          expect(patched.lines.first).to eq(text.lines.first)
          expect(patched.include?("\r\n")).to eq(text.include?("\r\n"))
        end
      end
    end

    it "takes the first of two equal blocks" do
      text = "```mermaid\ngraph TD\n```\n\nand\n\n```mermaid\ngraph TD\n```\n"
      place = described_class.locate(text, lang: "mermaid", source: "graph TD")
      expect([place.first, place.last]).to eq([1, 1])
      expect(described_class.replace(text, place, "graph LR")).to eq("```mermaid\ngraph LR\n```\n\nand\n\n```mermaid\ngraph TD\n```\n")
    end

    it "finds every copy of a repeated block (.locate_all) and replaces them all, list item's indent kept" do
      text = "```mermaid\ngraph TD\n```\n\n- again\n\n  ```mermaid\n  graph TD\n  ```\n"
      places = described_class.locate_all(text, lang: "mermaid", source: "graph TD")
      expect(places.map(&:first)).to eq([1, 7])
      expect(described_class.replace_all(text, places, "graph LR\n  A")).to eq(
        "```mermaid\ngraph LR\n  A\n```\n\n- again\n\n  ```mermaid\n  graph LR\n    A\n  ```\n"
      )
      expect(described_class.locate_all("no fence", lang: "mermaid", source: "x")).to eq([])
    end

    it "finds nothing in a blockquote, in another language or for another source" do
      expect(described_class.locate("> ```mermaid\n> graph TD\n> ```\n", lang: "mermaid", source: "graph TD")).to be_nil
      expect(described_class.locate("```dot\ngraph TD\n```\n", lang: "mermaid", source: "graph TD")).to be_nil
      expect(described_class.locate("```mermaid\ngraph TD\n```\n", lang: "mermaid", source: "graph LR")).to be_nil
      expect(described_class.locate("no fence", lang: "mermaid", source: "graph LR")).to be_nil
    end

    it "keeps a longer fence's inner fence line as body, and an unclosed fence's last line" do
      text = "````mermaid\nx\n```\n````\n"
      place = described_class.locate(text, lang: "mermaid", source: "x\n```\n")
      expect(body_of(text, place)).to eq("x\n```\n")
      unclosed = "Text\n\n```mermaid\ngraph TD"
      place = described_class.locate(unclosed, lang: "mermaid", source: "graph TD")
      expect(described_class.replace(unclosed, place, "graph LR\n")).to eq("Text\n\n```mermaid\ngraph LR")
    end

    it "indents a list item's new lines as its old ones" do
      text = "- item\n\n  ```mermaid\n  graph TD\n    A-->B\n  ```\n"
      place = described_class.locate(text, lang: "mermaid", source: "graph TD\n  A-->B\n")
      expect(described_class.replace(text, place, "graph LR\n  A-->C")).to eq("- item\n\n  ```mermaid\n  graph LR\n    A-->C\n  ```\n")
    end
  end

  describe ".request" do
    it "is the transcript up to the answer, then the block and its error, the error cut" do
      messages = [{ role: "user", content: "draw it" }, { role: "model", content: "```mermaid\ngraph\n```" }]
      request = described_class.request(messages: messages, lang: "mermaid", source: "a ``` b", reason: "x" * 400)
      expect(request.map { |m| m[:role] }).to eq(%w[system user])
      expect(request.first[:content]).to eq(described_class::SYSTEM)
      user = request.last[:content]
      expect(user).to include("<conversation>", "User: draw it", "Error: #{"x" * 300}\n")
      expect(user).not_to include("x" * 301)
      expect(user).to include("````mermaid\na ``` b\n````")
    end

    it "adds the chi-ui schemas for a chi-ui block" do
      request = described_class.request(messages: [], lang: "chi-ui", source: "type: picks", reason: "bad")
      expect(request.first[:content]).to end_with(Samagotchi::InlineWidgets::FIX_RULES)
    end
  end

  describe ".extract" do
    it "takes the first fence, else the whole answer" do
      expect(described_class.extract("Here:\n```mermaid\ngraph LR\n```\nmore\n```x\ny\n```", cut_off: false, failed: "g").source).to eq("graph LR")
      expect(described_class.extract("  graph LR\n", cut_off: false, failed: "g").source).to eq("graph LR")
    end

    it "refuses a cut-off, empty, unchanged or oversized answer" do
      expect(described_class.extract("```\ngraph\n```", cut_off: true, failed: "g").refusal).to eq("the fix was cut off")
      expect(described_class.extract("```mermaid\n```", cut_off: false, failed: "g").refusal).to eq("the fix was empty")
      expect(described_class.extract("```mermaid\ng\n```", cut_off: false, failed: "g\n").refusal).to eq("the fix was the same block")
      expect(described_class.extract("a" * (17 * 1024), cut_off: false, failed: "g").refusal).to eq("the fix is over 16 KB")
    end
  end

  describe ".check" do
    it "parses a chi-ui block and passes any other language" do
      expect(described_class.check(lang: "chi-ui", source: "type: nope")).to include("unknown type")
      expect(described_class.check(lang: "chi-ui", source: "type: picks\nrows:\n  - id: a\n    text: t\n    options: [x, y]\n")).to be_nil
      expect(described_class.check(lang: "mermaid", source: "anything")).to be_nil
    end
  end

  describe "the stamp" do
    it "reads string or symbol keys and adds an entry to a fresh list" do
      message = { role: "model", content: "x", "block_fixes" => [{ "key" => "k1", "state" => "failed" }] }
      expect(described_class.stamps(message)).to eq([{ key: "k1", state: "failed" }])
      entry = described_class.entry(key: "k2", fixed_key: "k3", state: "fixed")
      copy = described_class.with_stamp(message, entry)
      expect(copy[:block_fixes].map { |e| e[:key] }).to eq(%w[k1 k2])
      expect(copy).not_to have_key("block_fixes")
      expect(message["block_fixes"].size).to eq(1)
      expect(described_class.stamp_for(copy, "k3")[:key]).to eq("k2")
    end
  end
end
