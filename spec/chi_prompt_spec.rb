# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/session"
require "support/fake_provider_server"

# `chi -p … --non-interactive` as a script or a parent agent runs it: stdout
# holds the answer alone, everything else goes to stderr, and the exit
# status says how the turn ended (a fake model server answers).
RSpec.describe "chi -p --non-interactive" do
  def run_chi(*args, server: nil, env: {})
    Dir.mktmpdir do |dir|
      env = isolated_chi_env(dir, "SAMAGOTCHI_DEFAULT_MODEL" => "spec-model", "SAMAGOTCHI_SERVER_HOST" => "127.0.0.1",
                                  "SAMAGOTCHI_SERVER_PORT" => (server&.port || 9).to_s, "SAMAGOTCHI_RETRY_MAX" => "0")
                         .merge(env)
      out, err, status = super(*args, env: env, chdir: dir)
      sessions = File.join(dir, "state", "samagotchi", "sessions")
      kept = Dir.glob(File.join(sessions, "*.json")).map { |path| File.basename(path, ".json") }
      [out, err, status, kept]
    end
  end

  def answer(text)
    ["data: #{JSON.generate(content: text, stop: true)}\n\n"]
  end

  it "prints the answer alone on stdout, and the session line on stderr first" do
    server = FakeProviderServer.start
    server.default("/completion", sse: answer("PONG"))

    out, err, status, kept = run_chi("-p", "hi", "--non-interactive", server: server)

    expect(status.exitstatus).to eq(0), err
    expect(out).to eq("PONG\n")
    expect(err).to eq("Session: #{kept.first}\n")
  ensure
    server&.stop
  end

  it "exits 1 with a line on stderr and nothing on stdout when the answer is empty" do
    server = FakeProviderServer.start
    server.default("/completion", sse: answer(""))

    out, err, status, = run_chi("-p", "hi", "--non-interactive", server: server)

    expect(status.exitstatus).to eq(1), err
    expect(out).to eq("")
    expect(err).to include("chi: the model gave an empty answer\n")
  ensure
    server&.stop
  end

  # A failed first turn: the session line comes first, then the error, then
  # how to go on; the session is kept with the prompt, so --resume retries.
  it "says before the error which session it is, and after it that the session is kept" do
    out, err, status, kept = run_chi("-p", "hello there", "--non-interactive")

    expect(status.exitstatus).to eq(1)
    expect(out).to eq("")
    expect(kept.size).to eq(1)
    id = kept.first
    lines = err.lines.map(&:chomp)
    expect(lines.first).to eq("Session: #{id}")
    expect(lines[1]).to start_with("Error: can't reach host")
    expect(lines.last).to eq("chi: the session is kept with your prompt; continue it with: chi --resume #{id}")
    expect(lines.size).to eq(3)
  end
end
