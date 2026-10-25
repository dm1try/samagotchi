# frozen_string_literal: true

require "samagotchi/recap_title"

# The auto title the recap reply leads with, split off the recap.
RSpec.describe Samagotchi::RecapTitle do
  def parts(text) = described_class.split(text).to_h

  it "takes the first line's title and leaves the recap without it" do
    expect(parts("Title: Parser tab handling\n\nTabs were fixed. Spaces are next."))
      .to eq(title: "Parser tab handling", body: "Tabs were fixed. Spaces are next.")
  end

  it "strips markup, quotes and a closing period, any case of the label" do
    ["**Title:** Parser tab handling", "## title: \"Parser tab handling.\"", "TITLE: *Parser tab handling*",
     "Title: `Parser tab handling`", "Title:“Parser tab handling”"].each do |line|
      expect(parts("#{line}\n\nTabs were fixed.")).to eq(title: "Parser tab handling", body: "Tabs were fixed."), line
    end
  end

  it "drops an echoed instruction or a Recap: label between the title and the recap (the spike's echo)" do
    expect(parts("Title: Sandbox cleanup\n\nBlank line follows title.\n\nTwo folders were removed."))
      .to eq(title: "Sandbox cleanup", body: "Two folders were removed.")
    expect(parts("Title: Sandbox cleanup\n(blank line)\nRecap: Two folders were removed.\nOne is left."))
      .to eq(title: "Sandbox cleanup", body: "Two folders were removed.\nOne is left.")
    expect(parts("Title: Sandbox cleanup\n**Recap:**\nTwo folders were removed."))
      .to eq(title: "Sandbox cleanup", body: "Two folders were removed.")
  end

  it "keeps a recap's own words that only look like those (Blank lines, Title-casing)" do
    text = "Blank lines in YAML were kept. Title-casing was dropped."
    expect(parts(text)).to eq(title: nil, body: text)
    expect(parts("Title-casing the headings was fixed.\nIt works.")).to eq(title: nil, body: "Title-casing the headings was fixed.\nIt works.")
  end

  it "tolerates the title on the last line" do
    expect(parts("Tabs were fixed. Spaces are next.\n\nTitle: Parser tab handling"))
      .to eq(title: "Parser tab handling", body: "Tabs were fixed. Spaces are next.")
  end

  it "is no title without a title line: the reply is the recap" do
    expect(parts("  Tabs were fixed.\n")).to eq(title: nil, body: "Tabs were fixed.")
    expect(parts("")).to eq(title: nil, body: "")
  end

  it "rejects a title outside 2-6 words or one naming an actor, and still drops its line" do
    ["Parser", "A very long title that has far too many words", "The user fixes tabs", "The user's parser work",
     "We fix the parser", "I fixed tabs", "", "**  **"].each do |title|
      expect(parts("Title: #{title}\n\nTabs were fixed.")).to eq(title: nil, body: "Tabs were fixed."), title
    end
  end

  it "keeps a title that names a thing called User or Chi" do
    expect(parts("Title: User settings page\n\nIt was built.")[:title]).to eq("User settings page")
    expect(parts("Title: Chi web push devices\n\nThey were listed.")[:title]).to eq("Chi web push devices")
  end

  it "cuts a long title at 60 characters" do
    title = parts("Title: Internationalization of documentation infrastructure everywhere\n\nDone.")[:title]
    expect(title.length).to eq(described_class::MAX_CHARS)
    expect(title).to end_with("…")
  end

  it "is the title with an empty recap for a title alone" do
    expect(parts("Title: Parser tab handling")).to eq(title: "Parser tab handling", body: "")
  end
end
