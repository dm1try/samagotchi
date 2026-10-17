# frozen_string_literal: true

require "spec_helper"
require "digest"
require "yaml"
require "samagotchi/testing/rspec"

# spec/fixtures/http_echo_bundle: the plugin docs/plugins.md ("Calling
# services") shows, tested on the kit's fake ctx.http the way a bundle's own
# spec is (chi copies this shape when asked to write a plugin).
RSpec.describe "The http-echo bundle", :bundle do
  let(:dir) { File.expand_path("../../fixtures/http_echo_bundle", __dir__) }
  let(:url) { "http://127.0.0.1:9000/ask" }
  let(:bundle) { load_bundle(dir) }

  it "posts the question and returns the service's answer" do
    bundle.http.stub(:post, url, json: { answer: "42" })

    expect(bundle.tool("ask_service", question: "meaning of life?")).to eq("42")
    expect(bundle.http.requests.map { |request| [request.method, request.url, request.json] })
      .to eq([["POST", url, { "question" => "meaning of life?" }]])
  end

  it "reads the service's url from the bundle's settings" do
    custom = load_bundle(dir, settings: { "url" => "http://10.0.0.5:8080/q" })
    custom.http.stub(:post, "http://10.0.0.5:8080/q", json: { answer: "from settings" })

    expect(custom.tool("ask_service", question: "q")).to eq("from settings")
  end

  it "says what the service answered when it isn't a 2xx," do
    bundle.http.stub(:post, url, status: 503, body: "down")

    expect(bundle.tool("ask_service", question: "q")).to eq("the service answered 503")
  end

  it "says the service is unreachable when the request doesn't complete" do
    bundle.http.stub(:post, url, error: :refused)

    expect(bundle.tool("ask_service", question: "q")).to eq("the service is not reachable: POST 127.0.0.1:9000: connection refused")
  end

  it "says so when the answer isn't JSON, instead of raising" do
    bundle.http.stub(:post, url, body: "<html>oops</html>")

    expect(bundle.tool("ask_service", question: "q")).to match(/\Athe service is not reachable: not JSON: status 200/)
  end

  it "is the code docs/plugins.md shows, and its manifest sha256 is current" do
    docs = File.read(File.expand_path("../../../docs/plugins.md", __dir__))
    shown = docs[/^## Calling services.*?^```ruby\n(.*?)^```$/m, 1]
    expect(shown).to eq(File.read(File.join(dir, "plugin.rb")))

    manifest = YAML.safe_load_file(File.join(dir, "manifest.yml"))
    expect(manifest.dig("plugin", "sha256")).to eq("sha256:#{Digest::SHA256.file(File.join(dir, "plugin.rb")).hexdigest}")
  end
end
