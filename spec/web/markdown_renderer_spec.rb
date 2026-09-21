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

  it "applies syntax highlighting to code blocks by default" do
    html = renderer.render("```ruby\nputs 1\n```")

    expect(html).to include("<pre")
    expect(html).to include("style=")
  end
end
