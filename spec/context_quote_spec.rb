# frozen_string_literal: true

require "spec_helper"
require "samagotchi/context_quote"

RSpec.describe Samagotchi::ContextQuote do
  describe ".block" do
    it "quotes each line and ends in exactly one blank line" do
      expect(described_class.block("one\ntwo")).to eq("> one\n> two\n\n")
    end

    it "turns CRLF and CR into lines" do
      expect(described_class.block("one\r\ntwo\rthree")).to eq("> one\n> two\n> three\n\n")
    end

    it "drops leading and trailing blank lines and trailing whitespace" do
      expect(described_class.block("\n  \nfirst  \t\n\nlast \n\n \n")).to eq("> first\n>\n> last\n\n")
    end

    it "keeps leading indentation" do
      expect(described_class.block("  def x\n    1\n  end\n")).to eq(">   def x\n>     1\n>   end\n\n")
    end

    it "is nil for nil, empty or all-blank text" do
      expect([nil, "", " \n\t\r\n"].map { |text| described_class.block(text) }).to eq([nil, nil, nil])
    end
  end
end
