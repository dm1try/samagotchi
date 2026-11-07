# frozen_string_literal: true

require "spec_helper"
require "samagotchi/web/markdown_renderer"

RSpec.describe Samagotchi::Web::MarkdownRenderer do
  let(:renderer) { described_class.new(enabled: true) }

  it "does nothing when Markdown rendering is disabled" do
    disabled = described_class.new

    expect(disabled.available?).to be(false)
    expect(disabled.warning).to be_nil
    expect(disabled.render("# heading")).to be_nil
  end

  it "warns and falls back when commonmarker is unavailable" do
    allow(renderer).to receive(:load_bundled_commonmarker!).and_return(false)

    expect(renderer.available?).to be(false)
    expect(renderer.render("# heading")).to be_nil
    expect(renderer.warning).to include("gem install commonmarker")
  end

  describe "#tip" do
    it "is nil while rendering is on" do
      expect(renderer.tip).to be_nil
    end

    it "says how to turn rendering on while it is off and the gem is installed, without loading it" do
      disabled = described_class.new
      allow(Gem::Specification).to receive(:find_all_by_name).with("commonmarker").and_return([double])
      expect(disabled).not_to receive(:load_bundled_commonmarker!)

      expect(disabled.tip).to eq(described_class::TIP)
      expect(disabled.tip).to include("--web-markdown", "web.markdown: true")
      expect(disabled.tip).not_to include("gem install")
    end

    it "adds the gem install while it is off and the gem is missing" do
      disabled = described_class.new
      allow(Gem::Specification).to receive(:find_all_by_name).with("commonmarker").and_return([])

      expect(disabled.tip).to eq(described_class::TIP_GEM)
      expect(disabled.tip).to include("gem install commonmarker", "--web-markdown")
    end
  end

  it "renders markdown and sanitizes generated HTML and unsafe links" do
    html = renderer.render(
      "# Heading\n\n" \
      "[bad](javascript:alert(1)) and a [good](https://example.test) link"
    )

    expect(html).to include("<h1>Heading</h1>")
    expect(html).to include('href="https://example.test"')
    expect(html).to include('target="_blank"')
    expect(html).to include('rel="noopener noreferrer"')
    expect(html).not_to include("javascript:")
    expect(html).not_to include("onclick")
  end

  it "highlights code blocks with CSS classes, not inline styles, so both palettes can colour them" do
    html = renderer.render("```ruby\nputs \"hi\" # note\n```")

    expect(html).to include('<pre class="syntax-highlighting" data-lang="ruby">')
    expect(html).to match(/<span class="[^"]*\bhl-string\b/)
    expect(html).to match(/<span class="[^"]*\bhl-comment\b/)
    expect(html).not_to include("style=")
  end

  describe "a code block's language (data-lang, what a block renderer finds)" do
    def langs(markdown)
      Nokogiri::HTML5.fragment(renderer.render(markdown)).css("pre").map { |pre| pre["data-lang"] }
    end

    it "keeps the fence's first word, downcased" do
      expect(langs("```Mermaid extra words\ngraph TD\n```")).to eq(["mermaid"])
      expect(langs("~~~ruby\nx\n~~~")).to eq(["ruby"])
    end

    it "keeps the source as the block's text, with or without a highlighter grammar" do
      pre = Nokogiri::HTML5.fragment(renderer.render("```mermaid\ngraph TD\n  A-->B\n```")).at_css("pre")
      expect(pre.text).to eq("graph TD\n  A-->B\n")
    end

    it "pairs each block with its own fence, in document order, whatever holds it" do
      markdown = <<~MD
        ```ruby
        a
        ```

        - item

          ```mermaid
          b
          ```

        > ```python
        > c
        > ```

            indented, so no language

        ```
        none
        ```

        ~~~sh
        d
        ~~~
      MD
      expect(langs(markdown)).to eq(["ruby", "mermaid", "python", nil, nil, "sh"])
    end

    it "sets nothing for a hostile or over-long info string" do
      ['"><img src=x onerror=alert(1)>', "a/b", "`x", "x" * 33, "&quot;x", "../../x"].each do |info|
        html = renderer.render("~~~#{info}\nx\n~~~")
        expect(Nokogiri::HTML5.fragment(html).at_css("pre")["data-lang"]).to be_nil, info
        expect(html).not_to include("onerror")
      end
    end

    it "takes raw HTML in the source for text, so a raw <pre> doesn't shift the pairs" do
      markdown = "<pre>raw</pre>\n\n<!-- comment -->\n\n<svg><text>x</text></svg>\n\n```mermaid\nb\n```\n"
      expect(langs(markdown)).to eq(["mermaid"])
    end

    it "sets nothing when the blocks and the fences don't pair" do
      allow(renderer).to receive(:fences).and_return(%w[ruby mermaid].map { |lang| described_class::Fence.new(language: lang, literal: "") })

      expect(langs("```ruby\na\n```")).to eq([nil])
    end

    it "doesn't parse a second time for a text with no fence" do
      expect(Commonmarker).not_to receive(:parse)

      expect(langs("    just indented\n")).to eq([nil])
    end
  end

  describe "a chi-ui block (what the page draws as a widget)" do
    let(:picks) { "type: picks\nrows:\n  - id: 1\n    text: Drop the buffer?\n    options: [fix, skip]\n" }

    def pres(markdown) = Nokogiri::HTML5.fragment(renderer.render(markdown)).css("pre")

    it "carries the parsed widget as JSON, or the reason it stays source" do
      good, bad = pres("```chi-ui\n#{picks}```\n\n```chi-ui\ntype: table\n```\n")

      expect(JSON.parse(good["data-widget"])).to eq("type" => "picks", "rows" => [{ "id" => "1", "text" => "Drop the buffer?",
                                                                                    "options" => %w[fix skip] }])
      expect(good["data-lang"]).to eq("chi-ui")
      expect(good["data-widget-error"]).to be_nil
      expect(good["data-widget-lenient"]).to be_nil
      expect(bad["data-widget-error"]).to eq('unknown type "table" (picks or walk)')
      expect(bad["data-widget"]).to be_nil
    end

    it "marks a block the lenient pass mended" do
      pre = pres("```chi-ui\n#{picks.sub("Drop the buffer?", "Asked: drop it?")}```\n").first

      expect(JSON.parse(pre["data-widget"])["rows"].first["text"]).to eq("Asked: drop it?")
      expect(pre["data-widget-lenient"]).to eq("")
    end

    it "lands on its own block when an answer mixes chi-ui, mermaid and plain fences, in a list item too" do
      markdown = "```mermaid\ngraph TD\n```\n\n- item\n\n  ```chi-ui\n#{picks.gsub(/^/, "  ")}  ```\n\n```\nplain\n```\n"
      mermaid, widget, plain = pres(markdown)

      expect(mermaid.attributes.keys).to contain_exactly("class", "data-lang")
      expect(mermaid["data-lang"]).to eq("mermaid")
      expect(JSON.parse(widget["data-widget"])["type"]).to eq("picks")
      expect(plain.attributes.keys).to eq(["class"])
    end

    it "keeps model HTML in a step inert: it is JSON in an attribute" do
      walk = "type: walk\ntitle: t\nactors: [a, b]\nsteps:\n  - id: s1\n    actor: a\n    does: <img src=x onerror=alert(1)>\n"
      html = renderer.render("```chi-ui\n#{walk}```\n")
      pre = Nokogiri::HTML5.fragment(html).at_css("pre")

      expect(JSON.parse(pre["data-widget"])["steps"].first["does"]).to eq("<img src=x onerror=alert(1)>")
      expect(Nokogiri::HTML5.fragment(html).css("img")).to be_empty
      expect(html).not_to include("<img")
    end
  end

  it "prefixes every highlighter class, so scope names like diff never hit page CSS" do
    html = renderer.render("```diff\n-a\n+b\n```")
    span_classes = Nokogiri::HTML5.fragment(html).css("span").flat_map { |span| span["class"].split }

    expect(span_classes).to include("hl-diff", "hl-inserted", "hl-deleted")
    expect(span_classes).to all(start_with("hl-"))
  end

  it "keeps raw HTML in the source as text, so it can carry no class or style" do
    html = renderer.render('<span class="keyword" style="color:red">x</span>')

    expect(html).to include("&lt;span")
    expect(html).not_to include("<span")
  end
end
