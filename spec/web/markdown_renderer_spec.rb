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

    expect(html).to include('<pre class="syntax-highlighting">')
    expect(html).to match(/<span class="[^"]*\bhl-string\b/)
    expect(html).to match(/<span class="[^"]*\bhl-comment\b/)
    expect(html).not_to include("style=")
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
