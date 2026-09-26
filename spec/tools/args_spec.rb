# frozen_string_literal: true

require "spec_helper"
require "samagotchi/tools/args"

RSpec.describe Samagotchi::Tools::Args do
  describe ".parse_gemma" do
    let(:q) { '<|"|>' }

    def parse(raw) = described_class.parse_gemma(raw, q)

    it "reads delimited, quoted and bare values" do
      expect(parse("text:#{q}a, b{c}#{q},n:3,x:-1.5,ok:true,no:null,word:hello there,s:\"q\\\"t\"")).to eq(
        "text" => "a, b{c}", "n" => 3, "x" => -1.5, "ok" => true, "no" => nil, "word" => "hello there", "s" => 'q"t'
      )
    end

    it "reads lists and nested objects, and a trailing comma" do
      expect(parse("tags:[#{q}a#{q}, #{q}b#{q}],meta:{priority:2,deep:{on:false},},empty:[]")).to eq(
        "tags" => %w[a b], "meta" => { "priority" => 2, "deep" => { "on" => false } }, "empty" => []
      )
    end

    it "is empty for no arguments, and nil for what doesn't parse" do
      expect(parse("")).to eq({})
      expect(parse("text:#{q}open")).to be_nil
      expect(parse("tags:[1,2")).to be_nil
      expect(parse("just words")).to be_nil
    end
  end

  describe ".coerce" do
    let(:parameters) do
      { type: "object", properties: {
        n: { type: "integer" }, x: { type: "number" }, ok: { type: "boolean" }, s: { type: "string" },
        opt: { type: %w[integer null] },
        list: { type: "array", items: { type: "integer" } },
        meta: { type: "object", properties: { on: { type: "boolean" } } }
      } }
    end

    it "types text by the schema" do
      args = { "n" => "3", "x" => "2.5", "ok" => "TRUE", "s" => 42, "opt" => "7",
               "list" => "[1, \"2\"]", "meta" => '{"on":"false","other":1}', "extra" => "as is" }
      expect(described_class.coerce(args, parameters)).to eq(
        "n" => 3, "x" => 2.5, "ok" => true, "s" => "42", "opt" => 7,
        "list" => [1, 2], "meta" => { "on" => false, "other" => 1 }, "extra" => "as is"
      )
    end

    it "leaves a value that doesn't fit as it came" do
      args = { "n" => "three", "x" => "lots", "ok" => "maybe", "list" => "not json", "meta" => "[1]" }
      expect(described_class.coerce(args, parameters)).to eq(args)
    end

    it "keeps typed values, and a whole float given for an integer becomes one" do
      expect(described_class.coerce({ "n" => 3.0, "x" => 1, "ok" => false, "list" => [1] }, parameters))
        .to eq("n" => 3, "x" => 1, "ok" => false, "list" => [1])
    end

    it "string-keys the args without a schema" do
      expect(described_class.coerce({ text: "hi" }, nil)).to eq("text" => "hi")
    end
  end
end
