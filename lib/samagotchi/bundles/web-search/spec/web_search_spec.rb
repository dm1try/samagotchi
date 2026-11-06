# frozen_string_literal: true

require "json"
require "samagotchi/testing/rspec"

# The web-search plugin through the bundle test kit: SearXNG's JSON API
# answered by bundle.http stubs, the URLs the plugin sends written out.
RSpec.describe "The web-search bundle", :bundle do
  let(:base) { "http://127.0.0.1:8888/search?q=ruby+prism&format=json&pageno=1" }

  def plugin(settings = {}, host = {}) = shipped_bundle("web-search", settings: settings, host: host)

  def searxng(results: [], answers: [], suggestions: [], unresponsive: [])
    { query: "ruby prism", number_of_results: results.size, results: results, answers: answers,
      suggestions: suggestions, unresponsive_engines: unresponsive }
  end

  def result(number, **fields)
    { url: "https://example.com/#{number}", title: "Title #{number}", content: "Snippet #{number}",
      engine: "duckduckgo", engines: ["duckduckgo"] }.merge(fields)
  end

  def search(bundle, **args) = bundle.tool("web_search", { query: "ruby prism" }.merge(args))

  def urls(bundle) = bundle.http.requests.map(&:url)

  it "lists the results (number, title, URL, snippet) and sends the query to SearXNG's JSON API" do
    bundle = plugin
    bundle.http.stub(:get, base, json: searxng(results: [
      result(1, title: "Prism — Ruby parser", url: "https://github.com/ruby/prism",
                content: "A portable,\n  error-tolerant Ruby parser"),
      result(2)
    ]))

    expect(search(bundle)).to eq(<<~TEXT.chomp)
      SearXNG results for "ruby prism" (page 1):
      1. Prism — Ruby parser
         https://github.com/ruby/prism
         A portable, error-tolerant Ruby parser
      2. Title 2
         https://example.com/2
         Snippet 2
    TEXT
    expect(bundle.http.requests.map(&:method)).to eq(["GET"])
    expect(urls(bundle)).to eq([base])
  end

  it "declares one tool with a preview of the query" do
    bundle = plugin
    expect(bundle.bundle_tools.map(&:name)).to eq(["web_search"])
    expect(bundle.tools["web_search"].preview.call({ name: "web_search", args: { "query" => "ruby prism" } })).to eq("ruby prism")
  end

  describe "the list" do
    it "caps it at max_results, clamped to 1..20" do
      many = searxng(results: (1..25).map { |number| result(number) })
      { 3 => 3, 0 => 1, 50 => 20, "x" => 8 }.each do |setting, shown|
        bundle = plugin("max_results" => setting)
        bundle.http.stub(:get, base, json: many)
        expect(search(bundle).scan(/^\d+\. /).size).to eq(shown), "max_results: #{setting.inspect}"
      end
    end

    it "cuts a long snippet, skips a result without a url, shows the URL for a missing title and drops an empty snippet" do
      bundle = plugin
      bundle.http.stub(:get, base, json: searxng(results: [
        result(1, content: "word " * 100),
        result(2, url: nil),
        result(3, title: nil),
        result(4, content: "")
      ]))

      lines = search(bundle).lines(chomp: true)
      expect(lines[3]).to start_with("   word word")
      expect(lines[3].length).to eq(3 + 300)
      expect(lines[3]).to end_with("…")
      expect(lines[4..]).to eq(["2. https://example.com/3", "   https://example.com/3", "   Snippet 3",
                                "3. Title 4", "   https://example.com/4"])
    end

    it "shows the first answer (a String or a Hash with answer) and the suggestions" do
      bundle = plugin
      bundle.http.stub(:get, base, json: searxng(results: [result(1)], answers: ["", "Prism is a parser"],
                                                 suggestions: ["ruby prism gem", "prism vs parser"]))
      text = search(bundle)
      expect(text.lines(chomp: true)[1]).to eq("Answer: Prism is a parser")
      expect(text.lines(chomp: true).last).to eq("Suggestions: ruby prism gem, prism vs parser")

      current = plugin
      current.http.stub(:get, base, json: searxng(results: [result(1)], answers: [{ answer: "From a dict", url: nil }]))
      expect(search(current).lines(chomp: true)[1]).to eq("Answer: From a dict")
    end
  end

  describe "the query" do
    it "sends time_range and page, coercing a page given as text or not a number" do
      bundle = plugin
      bundle.http.stub(:get, %r{\Ahttp://127\.0\.0\.1:8888/search\?}, json: searxng(results: [result(1)]))

      search(bundle, time_range: "week", page: 2)
      search(bundle, page: "3")
      search(bundle, page: "soon")
      search(bundle, page: -4)
      expect(urls(bundle)).to eq([
        "http://127.0.0.1:8888/search?q=ruby+prism&format=json&pageno=2&time_range=week",
        "http://127.0.0.1:8888/search?q=ruby+prism&format=json&pageno=3",
        base, base
      ])
      expect(search(bundle, page: 3)).to start_with(%(SearXNG results for "ruby prism" (page 3):))
    end

    it "sends the optional settings only when set, in a fixed order, under a url with a trailing slash" do
      bundle = plugin("url" => "http://10.0.0.5:8080/", "language" => "en", "safesearch" => 1,
                      "categories" => "general,it", "engines" => "", "timeout" => 3)
      url = "http://10.0.0.5:8080/search?q=ruby+prism&format=json&pageno=1&language=en&safesearch=1&categories=general%2Cit"
      bundle.http.stub(:get, url, json: searxng(results: [result(1)]))

      expect(search(bundle)).to start_with("SearXNG results")
      expect(urls(bundle)).to eq([url])
    end

    it "answers a blank query without a request" do
      bundle = plugin
      expect(bundle.tool("web_search", query: "  ")).to eq("Error: query is required")
      expect(bundle.http.requests).to be_empty
    end
  end

  describe "no results" do
    it "says so, a normal result" do
      bundle = plugin
      bundle.http.stub(:get, base, json: searxng)
      expect(search(bundle)).to eq(%(No results for "ruby prism".))
    end

    it "names the engines that failed" do
      bundle = plugin
      bundle.http.stub(:get, base, json: searxng(unresponsive: [%w[google timeout], ["brave", "Suspended: too many requests"]]))
      expect(search(bundle)).to eq(%(No results for "ruby prism".\nEngines that failed: google, brave))
    end
  end

  describe "a failure" do
    it "explains a 403, a 429 and another status" do
      {
        403 => "Error: SearXNG refused the JSON format (403): add json to search.formats in its settings.yml",
        429 => "Error: SearXNG rate-limited the request (429): turn its limiter off for a local instance (server.limiter: false)",
        500 => "Error: SearXNG answered 500"
      }.each do |status, text|
        bundle = plugin
        bundle.http.stub(:get, base, status: status, body: "nope")
        expect(search(bundle)).to eq(text)
      end
    end

    it "says an answer that isn't JSON, or isn't an object, isn't JSON" do
      ["<html><body>SearXNG</body></html>", "[1, 2]"].each do |body|
        bundle = plugin
        bundle.http.stub(:get, base, body: body)
        expect(search(bundle)).to eq("Error: SearXNG's answer isn't JSON (is url the SearXNG root?)")
      end
    end

    it "says SearXNG isn't reachable when the request doesn't complete, without the configured url" do
      { refused: "connection refused", timeout: "timed out" }.each do |error, words|
        bundle = plugin("url" => "http://user:secret@127.0.0.1:8888")
        bundle.http.stub(:get, %r{/search\?}, error: error)
        text = search(bundle)
        expect(text).to eq("Error: SearXNG is not reachable: GET 127.0.0.1:8888: #{words}. Is it running? (bundles: web-search: url)")
        expect(text).not_to include("secret")
      end
    end

    it "says the search was cancelled when the turn is stopped" do
      bundle = plugin({}, { cancelled: true })
      expect(search(bundle)).to eq("Error: search cancelled")
    end
  end

  describe "bad settings" do
    it "refuses a url that isn't http(s) with a host, without a request" do
      ["127.0.0.1:8888", "ftp://example.com", "http://", "not a url"].each do |url|
        bundle = plugin("url" => url)
        expect(search(bundle)).to eq("Error: bundles: web-search: url must be an http(s) URL"), url
        expect(bundle.http.requests).to be_empty
      end
    end

    it "uses the default timeout for one that isn't a positive number" do
      [0, -2, "soon"].each do |timeout|
        bundle = plugin("timeout" => timeout)
        bundle.http.stub(:get, base, json: searxng(results: [result(1)]))
        expect(search(bundle)).to start_with("SearXNG results"), timeout.inspect
      end
    end
  end
end
