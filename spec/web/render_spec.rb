# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"
require "samagotchi/web/app"

# POST /api/render: the page's markdown read for a text it already shows
# (the stage's asking text, a resolved question card's reply), rendered and
# sanitised by the same MarkdownRenderer as the answers.
RSpec.describe Samagotchi::Web::App, "render" do
  let(:state_dir) { Dir.mktmpdir("web-render") }
  let(:markdown) { true }
  let(:app) { described_class.new(state_dir: state_dir, bridge_wait_timeout: 0, markdown: markdown) }

  after { FileUtils.remove_entry(state_dir) }

  def render(body, headers: {})
    env = Rack::MockRequest.env_for("/api/render", "HTTP_HOST" => "127.0.0.1", method: "POST", input: body,
                                                   "CONTENT_TYPE" => "application/json", **headers)
    status, _headers, chunks = app.call(env)
    [status, JSON.parse(chunks.to_a.join)]
  end

  it "answers a heading and a link as sanitised HTML whose link opens in a new tab" do
    status, body = render(JSON.generate(text: "## Decision\n\n- see [PR 12](https://example.com/pr/12)"))
    expect(status).to eq(200)
    html = Nokogiri::HTML5.fragment(body["html"])
    expect(html.at_css("h2").text).to eq("Decision")
    link = html.at_css("li a")
    expect(link["href"]).to eq("https://example.com/pr/12")
    expect(link["target"]).to eq("_blank")
  end

  it "keeps a script and a javascript: link inert" do
    _, body = render(JSON.generate(text: "<script>alert(1)</script>\n\n[x](javascript:alert(1))"))
    html = Nokogiri::HTML5.fragment(body["html"])
    expect(html.css("script")).to be_empty
    expect(body["html"]).to include("&lt;script&gt;")
    expect(html.css("a").map { |a| a["href"] }.compact).to all(satisfy { |href| !href.start_with?("javascript:") })
  end

  context "with markdown off" do
    let(:markdown) { false }

    it "answers html: null, so the page keeps the raw text" do
      expect(render(JSON.generate(text: "# hi"))).to eq([200, { "html" => nil }])
    end
  end

  it "refuses a body that isn't an object, or a text that isn't a string" do
    ["[]", "nope", "", JSON.generate(text: 3), JSON.generate(other: "x")].each do |body|
      expect(render(body)).to eq([400, { "error" => "invalid_json", "detail" => "give {text}" }]), body
    end
  end

  it "refuses a body over 64 KB, by its Content-Length or by what it reads" do
    big = JSON.generate(text: "a" * (64 * 1024))
    expect(render(big).first).to eq(413)
    expect(render(big, headers: { "CONTENT_LENGTH" => "10" }).first).to eq(413)
  end

  it "answers a body at the cap" do
    text = "a" * ((64 * 1024) - JSON.generate(text: "").bytesize)
    expect(render(JSON.generate(text: text)).first).to eq(200)
  end
end
