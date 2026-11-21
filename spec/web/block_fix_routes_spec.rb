# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"
require "samagotchi/web/app"
require "samagotchi/bridge_client"

# POST /api/sessions/:id/blocks/fix (Web::BlockFixRoutes), the body's
# data-block-fix, and the answer render's marks from the stamp.
RSpec.describe Samagotchi::Web::BlockFixRoutes do
  let(:state_dir) { Dir.mktmpdir("web-block-fix") }

  after { FileUtils.rm_rf(state_dir) }

  def build_app(**extra) = Samagotchi::Web::App.new(state_dir: state_dir, bridge_wait_timeout: 0, **extra)

  def env_for(path, method: "GET", body: nil)
    Rack::MockRequest.env_for(path, "HTTP_HOST" => "127.0.0.1", method: method, input: body)
  end

  def post(app, body = { turn_id: "t1", lang: "mermaid", source: "graph", reason: "bad" })
    status, _headers, resp = app.call(env_for("/api/sessions/s1/blocks/fix", method: "POST",
                                              body: body.is_a?(String) ? body : JSON.generate(body)))
    [status, JSON.parse(resp.first)]
  end

  def with_worker(app, status, body)
    response = Samagotchi::BridgeClient::Response.new(status: status, body: JSON.generate(body))
    client = instance_double(Samagotchi::BridgeClient, fix_block: response)
    allow(app).to receive(:bridge_client).and_return(client)
    client
  end

  it "relays the block to the worker and passes 200 and 202 through" do
    app = build_app
    client = with_worker(app, 202, { state: "running" })
    expect(client).to receive(:fix_block).with(turn_id: "t1", lang: "mermaid", source: "graph", reason: "bad")
    expect(post(app)).to eq([202, { "state" => "running" }])
    with_worker(app, 200, { state: "failed", reason: "the fix was empty" })
    expect(post(app)).to eq([200, { "state" => "failed", "reason" => "the fix was empty" }])
  end

  it "passes the worker's refusals on with their code, anything else as 502" do
    app = build_app
    [[400, "missing_fields"], [409, "block_not_found"], [413, "block_too_large"], [429, "fix_busy"]].each do |status, code|
      with_worker(app, status, { error: code, detail: "why" })
      expect(post(app)).to eq([status, { "error" => code, "detail" => "why" }])
    end
    with_worker(app, 500, { error: "bridge_error", detail: "boom" })
    expect(post(app).first).to eq(502)
  end

  it "says a worker older than the route can't fix blocks (501), and one that isn't live (503)" do
    app = build_app
    with_worker(app, 404, { error: "not_found" })
    expect(post(app)).to match([501, hash_including("error" => "not_supported")])
    allow(app).to receive(:bridge_client).and_return(nil)
    expect(post(app)).to match([503, hash_including("error" => "not_live")])
  end

  it "refuses invalid JSON and a body over 64 KB, and answers 404 with web.block_fix off" do
    app = build_app
    with_worker(app, 202, { state: "running" })
    expect(post(app, "nope")).to eq([400, { "error" => "invalid_json", "detail" => "invalid JSON body" }])
    expect(post(app, { turn_id: "t1", lang: "mermaid", source: "x" * (65 * 1024) }).first).to eq(413)
    expect(post(build_app(block_fix: "off")).first).to eq(404)
  end

  it "tells the owner's page whether it asks (data-block-fix)" do
    page = ->(**opts) { build_app(**opts).call(env_for("/"))[2].first }
    expect(page.call).to include(' data-block-fix="auto"')
    expect(page.call(block_fix: "off")).to include(' data-block-fix="off"')
  end

  describe "the answer's render" do
    let(:app) { build_app(markdown: true) }
    let(:bad) { "graph TD\n  A--B" }
    let(:good) { "graph TD\n  A-->B" }
    let(:text) { "One:\n\n```mermaid\n#{good}\n```\n\nTwo:\n\n```mermaid\n#{bad}\n```\n\n```mermaid\nother\n```\n" }

    def html_of(message) = app.send(:messages_for_display, [{ role: "user", content: "q" }, message]).last[:html]

    it "marks the fixed block and the one whose fix failed, from the stamp" do
      stamp = [{ "key" => "k1", "fixed_key" => Samagotchi::BlockFix.key("mermaid", good), "state" => "fixed" },
               { "key" => Samagotchi::BlockFix.key("mermaid", bad), "state" => "failed", "reason" => "no" }]
      html = html_of({ role: "model", content: text, block_fixes: stamp })
      pres = Nokogiri::HTML5.fragment(html).css("pre")
      expect(pres.map { |pre| [pre.key?("data-block-fixed"), pre.key?("data-block-fix-failed")] })
        .to eq([[true, false], [false, true], [false, false]])
    end

    it "is byte-identical to the HTML before block fixes for an answer without a stamp (a golden)" do
      source = "One:\n\n```mermaid\ngraph TD\n  A-->B\n```\n\n```chi-ui\ntype: nope\n```\n"
      golden = "<p>One:</p>\n<pre class=\"syntax-highlighting\" data-lang=\"mermaid\"><code><span class=\"hl-text hl-plain\">" \
               "graph TD\n  A--&gt;B\n</span></code></pre>\n<pre class=\"syntax-highlighting\" data-lang=\"chi-ui\" " \
               "data-widget-error=\"unknown type &quot;nope&quot; (picks or walk)\"><code><span class=\"hl-text hl-plain\">" \
               "type: nope\n</span></code></pre>\n"
      expect(html_of({ role: "model", content: source })).to eq(golden)
    end

    it "is byte-identical to today's for an answer without a stamp" do
      plain = html_of({ role: "model", content: text })
      expect(plain).to eq(Samagotchi::Web::MarkdownRenderer.new(enabled: true).render(text))
      expect(plain).not_to include("data-block-fix")
      expect(Digest::SHA256.hexdigest(plain)).to eq(Digest::SHA256.hexdigest(html_of({ role: "model", content: text, block_fixes: [] })))
    end
  end
end
