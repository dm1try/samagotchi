# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "support/fake_provider_server"
require "support/detached_session"

# `chi -p X </dev/null` (attached): the prompt runs once. In the old
# in-process REPL a failed turn restored its prompt for a retry, and Reline,
# reading from no terminal, handed it back as the next line: the prompt went
# again and again (447 requests in 5 s against a host that answers 400).
# The error shows once and chi exits 1; the provider's retries inside the
# turn still run.
RSpec.describe "chi -p with no terminal" do
  include SpecDetachedSession

  let(:server) { FakeProviderServer.start }
  let(:dir) { Dir.mktmpdir("chi-p-pipe") }

  around { |example| FakeProviderServer.without_webmock { example.run } }

  after do
    server.stop
    FileUtils.rm_rf(dir)
  end

  # A real bin/chi each: the bug was Reline's, which a fork (the suite's
  # stubbed Reline) can't show. The retries' backoff is short: their count
  # is what is checked, not their delay.
  def run_prompt(retries:)
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
        base_delay: 0.01
      recap: false
    YAML
    env = isolated_chi_env(dir)
    out, _err, status = run_chi("-p", "hello", env: env, timeout: 30)
    # chi -p detaches: end its worker before the dir goes.
    stop_detached_session(out, env: env)
    [out, status]
  end

  def chat_requests = server.requests.count { |r| r.path.end_with?("/chat/completions") }

  it "sends a prompt its host refuses once, prints the error once and exits 1" do
    server.default("/v1/chat/completions", status: 400, json: { error: { message: "fake is not a valid model ID" } })

    out, status = run_prompt(retries: 0)

    expect(chat_requests).to eq(1)
    expect(status.exitstatus).to eq(1)
    expect(out.scan("turn failed").size).to eq(1)
    expect(out).not_to include("prompt restored for retry")
  end

  it "stops after the retry policy's attempts when the host keeps failing" do
    server.default("/v1/chat/completions", status: 503, json: { error: { message: "overloaded" } })

    _out, status = run_prompt(retries: 2)

    expect(chat_requests).to eq(3)
    expect(status.exitstatus).to eq(1)
  end

  it "exits 0 after an answer" do
    server.default("/v1/chat/completions", sse: FakeProviderServer.fixture("text_stream.sse"))

    out, status = run_prompt(retries: 0)

    expect(chat_requests).to eq(1)
    expect(status.exitstatus).to eq(0)
    expect(out).not_to include("turn failed")
  end
end
