# frozen_string_literal: true

require "spec_helper"
require "samagotchi/output_formatter"

RSpec.describe Samagotchi::OutputFormatter do
  def strip(text)
    described_class.strip(text)
  end

  # Qwen prompt-literal placeholders arrive in result.output verbatim. Build
  # them via concatenation so the bytes reach Ruby intact (the tool/shell layer
  # masks bare [[...]] literals into <|...> before the interpreter sees them).
  def literal(name)
    "[[SAMAGOTCHI_LITERAL_" + name + "]]"
  end

  describe ".strip_markup" do
    it "removes thinking and tool-call blocks but keeps the text's layout" do
      text = "<think>\nhm\n</think>\n\nSee:\n\n\n\n    indented  twice\n<tool_call>\n<function=read>\n</function>\n</tool_call>"
      expect(described_class.strip_markup(text)).to eq("See:\n\n    indented  twice")
    end

    it "returns an empty string for markup only" do
      expect(described_class.strip_markup("<think>x</think><tool_call>y</tool_call>")).to eq("")
    end
  end

  describe ".strip" do
    it "removes Gemma control tokens without dropping surrounding text" do
      result = strip("hello <|think|> world")
      expect(result).to include("hello")
      expect(result).to include("world")
      expect(result).not_to include("<|")
      expect(result).not_to include("<|think|>")
    end

    it "removes short Gemma control tokens (<...>)" do
      result = strip("<|tool_call>call:read{path:'x'}<tool_call|> end")
      expect(result).to include("call:read{path:'x'}")
      expect(result).not_to include("<|tool_call>")
      expect(result).not_to include("<tool_call|>")
    end

    it "removes the Gemma string delimiter <|\"|>" do
      result = strip("a <|\"|> b")
      expect(result).to include("a")
      expect(result).to include("b")
      expect(result).not_to include('<|"|>')
    end

    it "removes Qwen [[SAMAGOTCHI_LITERAL_*]] call literals" do
      body = "before " + literal("TOOL_CALL_OPEN") + " <function=execute> after"
      result = strip(body)
      expect(result).to include("<function=execute>")
      expect(result).not_to include(literal("TOOL_CALL_OPEN"))
    end

    it "removes Qwen [[SAMAGOTCHI_LITERAL_*]] close literals" do
      body = literal("THINK_CLOSE") + "\nHello!"
      result = strip(body)
      expect(result).to eq("Hello!")
      expect(result).not_to include(literal("THINK_CLOSE"))
    end

    it "removes both token families in a single chunk" do
      body = "x " + literal("TOOL_CALL_OPEN") + " <|think|> y"
      result = strip(body)
      expect(result).to include("x")
      expect(result).to include("y")
      expect(result).not_to include(literal("TOOL_CALL_OPEN"))
      expect(result).not_to include("<|")
    end

    # Regression: the control-token set must be enumerated, never a broad
    # <word> wildcard. Arbitrary <word> content (tool/file results, HTML/XML)
    # in the surrounding output must be preserved — only known control tokens
    # are stripped.
    it "preserves arbitrary <word> markup in the surrounding content (over-strip guard)" do
      expect(strip("here is <resp> the answer")).to eq("here is <resp> the answer")
      expect(strip("<div>content</div>")).to eq("<div>content</div>")
      result = strip("<|tool_call>call:read{path: x}<tool_call|> done")
      expect(result).to eq("call:read{path: x} done")
    end

    it "preserves internal newlines in multi-line responses" do
      result = strip("line one\n<|tool_call>kept\nline three")
      expect(result.count("\n")).to eq(2)
      expect(result).to include("line one")
      expect(result).to include("line three")
      expect(result).not_to include("<|tool_call>")
    end

    it "returns an empty string for token-only input" do
      expect(strip("<|think|>")).to eq("")
    end

    it "returns an empty string for whitespace-only input" do
      expect(strip("   \n  ")).to eq("")
    end

    it "returns an empty string for empty input" do
      expect(strip("")).to eq("")
    end
  end
end
