# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"
require "fileutils"
require_relative "../support/fake_provider_server"

# script/record_provider_fixtures.rb --api API --url URL --model MODEL
# [--out DIR]: records an api's fixtures (spec/fixtures/providers/<api> by
# default) from a live server; here the fake server, into a temp dir.
RSpec.describe "script/record_provider_fixtures.rb" do
  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:script) { File.expand_path("../../script/record_provider_fixtures.rb", __dir__) }
  let(:server) { FakeProviderServer.start }
  let(:out) { Dir.mktmpdir("record-fixtures-") }

  after do
    server.stop
    FileUtils.rm_rf(out)
  end

  def record(*args)
    Open3.capture2e(RbConfig.ruby, script, *args)
  end

  it "records the openai fixtures from --url with --model into --out" do
    server.default("/v1/chat/completions", sse: FakeProviderServer.fixture("text_stream.sse"))
    server.enqueue("/v1/chat/completions", sse: FakeProviderServer.fixture("text_stream.sse"))
    server.default("/v1/models", json: FakeProviderServer.fixture("models.json"))

    output, status = record("--api", "openai", "--url", server.base_url, "--model", "rec-model", "--out", out)

    expect(status).to be_success, output
    expect(Dir.children(out)).to include("text_stream.sse", "tool_call_stream.sse", "text_sync.json", "text_sync.status",
                                         "models.json")
    expect(File.binread(File.join(out, "text_stream.sse"))).to eq(FakeProviderServer.fixture("text_stream.sse"))
    chats = server.requests.select { |request| request.path == "/v1/chat/completions" }
    expect(chats.map { |request| request.json["model"] }.uniq).to eq(["rec-model"])
  end

  it "refuses an api it has no recorder for, and the old positional form" do
    output, status = record("--api", "nope", "--url", server.base_url, "--out", out)
    expect(status).not_to be_success
    expect(output).to include("no recorder for api nope")

    output, status = record(server.base_url, "rec-model")
    expect(status).not_to be_success
    expect(output).to include("--url")
    expect(server.requests).to be_empty
  end
end
