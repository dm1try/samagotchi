# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "support/fake_provider_server"

# `chi --no-shared -p X </dev/null`: the prompt runs once. A failed turn
# restored its prompt for a retry, and Reline, reading from no terminal,
# handed it back as the next line: the prompt went again and again (447
# requests in 5 s against a host that answers 400). Now the error shows
# once and chi exits 1; the provider's retries inside the turn still run.
RSpec.describe "chi --no-shared -p with no terminal" do
  let(:server) { FakeProviderServer.start }
  let(:dir) { Dir.mktmpdir("chi-p-pipe") }

  around { |example| FakeProviderServer.without_webmock { example.run } }

  after do
    server.stop
    FileUtils.rm_rf(dir)
  end

  def run_chi(retries:)
    FileUtils.mkdir_p(File.join(dir, "config", "samagotchi"))
    File.write(File.join(dir, "config", "samagotchi", "config.yml"), <<~YAML)
      default:
        model: fake
      hosts:
        main:
          url: #{server.base_url}
          api: openai
      retry:
        max: #{retries}
      recap: false
    YAML
    out, _err, status = super("--no-shared", "-p", "hello", env: isolated_chi_env(dir), timeout: 30)
    [out, status]
  end

  def chat_requests = server.requests.count { |r| r.path.end_with?("/chat/completions") }

  it "sends a prompt its host refuses once, prints the error once and exits 1" do
    server.default("/v1/chat/completions", status: 400, json: { error: { message: "fake is not a valid model ID" } })

    out, status = run_chi(retries: 0)

    expect(chat_requests).to eq(1)
    expect(status.exitstatus).to eq(1)
    expect(out.scan("turn failed").size).to eq(1)
    expect(out).not_to include("prompt restored for retry")
  end

  it "stops after the retry policy's attempts when the host keeps failing" do
    server.default("/v1/chat/completions", status: 503, json: { error: { message: "overloaded" } })

    _out, status = run_chi(retries: 2)

    expect(chat_requests).to eq(3)
    expect(status.exitstatus).to eq(1)
  end

  it "exits 0 after an answer" do
    server.default("/v1/chat/completions", sse: FakeProviderServer.fixture("text_stream.sse"))

    out, status = run_chi(retries: 0)

    expect(chat_requests).to eq(1)
    expect(status.exitstatus).to eq(0)
    expect(out).not_to include("turn failed")
  end
end
