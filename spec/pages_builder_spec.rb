# frozen_string_literal: true

require "json"
require "spec_helper"
require "samagotchi/pages"

# A page script's `ui`: the blocks it collects and the rules a script breaks.
RSpec.describe Samagotchi::Pages::Builder do
  let(:ui) { described_class.new("Usage") }
  let(:usage) { JSON.parse(File.read(File.expand_path("fixtures/pages/usage.json", __dir__))) }

  def blocks = ui.data["blocks"]

  it "collects blocks in order with the title" do
    ui.text("one")
    ui.walk(title: "W", actors: %w[a b], steps: [{ id: 1, actor: "a", does: "x" }])
    expect(ui.data["title"]).to eq("Usage")
    expect(blocks.map { |b| b["type"] }).to eq(%w[text walk])
    expect(blocks[0]).to eq("type" => "text", "text" => "one")
  end

  it "refuses a page without a title" do
    expect { described_class.new("  ") }.to raise_error(Samagotchi::Pages::Refused, "page needs a title")
  end

  describe "the usage table (spec/fixtures/pages/usage.json)" do
    before do
      ui.text("Stored cost per model.")
      ui.table(usage["groups"].map { |model, g| g.merge("model" => model) },
               columns: { "model" => "Model", "turns" => "Turns", "cost" => "Stored" },
               format: { "cost" => :money }, key: %w[turns cost],
               total: { "model" => "Total", "turns" => usage["totals"]["turns"], "cost" => usage["totals"]["cost"] })
    end

    it "stores the columns, raw cells, the total and nothing dropped" do
      table = blocks[1]
      expect(table["columns"]).to eq([{ "key" => "model", "label" => "Model" },
                                      { "key" => "turns", "label" => "Turns", "key_column" => true },
                                      { "key" => "cost", "label" => "Stored", "format" => "money", "key_column" => true }])
      expect(table["rows"]).to eq([["claude:sonnet-5-5", 96, 14.221], ["openrouter:deepseek-v4", 141, 3.9042],
                                   ["splash:qwen3.8-flash-next", 175, 0.0]])
      expect(table["total"]).to eq(["Total", 412, 18.1252])
      expect(table["dropped"]).to eq(0)
    end
  end

  describe "table" do
    it "takes symbol-keyed rows and a list of columns (the label is the key)" do
      ui.table([{ a: 1, b: "x" }], columns: %i[a b])
      expect(blocks[0]["columns"].map { |c| c["label"] }).to eq(%w[a b])
      expect(blocks[0]["rows"]).to eq([[1, "x"]])
      expect(blocks[0]).not_to have_key("total")
    end

    it "picks the first two all-number columns after the first as key columns" do
      ui.table([{ "n" => "x", "s" => "t", "a" => 1, "b" => nil, "c" => 2.5 }], columns: %w[n s a b c])
      expect(blocks[0]["columns"].select { |c| c["key_column"] }.map { |c| c["key"] }).to eq(%w[a b])
    end

    it "never counts the first column as a key column" do
      ui.table([{ "a" => 1, "b" => 2 }], columns: %w[a b], key: %w[a b])
      expect(blocks[0]["columns"].map { |c| c["key_column"] }).to eq([nil, true])
    end

    it "drops rows past 500 and counts them" do
      ui.table((1..503).map { |i| { "i" => i } }, columns: ["i"])
      expect(blocks[0]["rows"].size).to eq(500)
      expect(blocks[0]["dropped"]).to eq(3)
    end

    it "keeps numbers, nil and booleans, and makes the rest text" do
      ui.table([{ "a" => nil, "b" => true, "c" => Float::NAN, "d" => Float::INFINITY, "e" => :sym, "f" => Rational(1, 2),
                  "g" => "bad \xFF".b }], columns: %w[a b c d e f g])
      expect(blocks[0]["rows"]).to eq([[nil, true, "NaN", "Infinity", "sym", 0.5, "bad �"]])
      expect { JSON.generate(ui.data) }.not_to raise_error
    end

    it "cuts a cell over 300 characters with an ellipsis" do
      ui.table([{ "a" => "x" * 301 }], columns: ["a"])
      cell = blocks[0]["rows"][0][0]
      expect(cell.size).to eq(300)
      expect(cell).to end_with("…")
    end

    it "names the block and the format it refuses" do
      ui.text("first")
      expect { ui.table([{ "cost" => 1 }], columns: ["cost"], format: { "cost" => :percent }) }
        .to raise_error(Samagotchi::Pages::Refused, 'table 2: column "cost" has format :percent (use :money or :count)')
    end

    it "refuses a format, a key or a total naming no column" do
      expect { ui.table([], columns: ["a"], format: { "b" => :money }) }.to raise_error(Samagotchi::Pages::Refused)
      expect { ui.table([], columns: ["a"], key: ["b"]) }.to raise_error(Samagotchi::Pages::Refused)
      expect { ui.table([], columns: ["a"], total: { "b" => 1 }) }.to raise_error(Samagotchi::Pages::Refused)
    end

    it "refuses a row that isn't a mapping, and rows that aren't a list" do
      expect { ui.table([{ "a" => 1 }, [1]], columns: ["a"]) }
        .to raise_error(Samagotchi::Pages::Refused, "table 1: row 2 isn't a mapping")
      expect { ui.table(nil, columns: ["a"]) }.to raise_error(Samagotchi::Pages::Refused)
    end

    it "refuses more than 12 columns, naming the limit and the size" do
      expect { ui.table([], columns: (1..13).map(&:to_s)) }
        .to raise_error(Samagotchi::Pages::Refused, "table 1 has 13 columns (at most 12)")
    end

    it "refuses no columns" do
      expect { ui.table([], columns: {}) }.to raise_error(Samagotchi::Pages::Refused)
    end
  end

  describe "text" do
    it "refuses a text over 16 KB, naming the limit and the size" do
      expect { ui.text("x" * (17 * 1024)) }.to raise_error(Samagotchi::Pages::Refused, "text 1 is 17.0 KB (at most 16 KB)")
    end
  end

  describe "walk" do
    it "takes a Hash argument as well as keywords" do
      ui.walk({ "title" => "W", "actors" => %w[a b], "steps" => [{ "id" => "1", "actor" => "a", "does" => "x" }] })
      expect(blocks[0]["data"]["title"]).to eq("W")
    end

    it "fails with the check's message, naming the block" do
      expect { ui.walk(title: "W", actors: ["a"], steps: []) }
        .to raise_error(Samagotchi::Pages::Refused, "walk 1: walk has 1 actors (2-5)")
    end
  end

  it "refuses a 21st block" do
    20.times { ui.text("x") }
    expect { ui.text("x") }.to raise_error(Samagotchi::Pages::Refused, "the page has more than 20 blocks (text 21 is one too many)")
  end
end
