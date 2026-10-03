# frozen_string_literal: true

require "json"
require "rbconfig"
require "tmpdir"
require "samagotchi/session"
require "support/fake_provider_server"

# `chi -p … --non-interactive` as a script or a parent agent runs it: stdout
# holds the answer alone, everything else goes to stderr, and the exit
# status says how the turn ended (a fake model server answers).
RSpec.describe "chi -p --non-interactive" do
  # No server: a dead port (9), so the turn fails at once.
  def chi_env(dir, server)
    isolated_chi_env(dir, "SAMAGOTCHI_DEFAULT_MODEL" => "spec-model", "SAMAGOTCHI_SERVER_HOST" => "127.0.0.1",
                          "SAMAGOTCHI_SERVER_PORT" => (server&.port || 9).to_s, "SAMAGOTCHI_RETRY_MAX" => "0")
  end

  def run_chi(*args, server: nil)
    Dir.mktmpdir do |dir|
      out, err, status = super(*args, env: chi_env(dir, server), chdir: dir)
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

  # Ctrl-C mid-turn (the model is still streaming): exit 130, the prompt
  # saved for --resume, no backtrace.
  it "exits 130 at a Ctrl-C and keeps the session with the prompt" do
    server = FakeProviderServer.start
    server.default("/completion", sse: ["data: #{JSON.generate(content: "thinking about it", stop: false)}\n\n"], hold: true)
    Dir.mktmpdir do |dir|
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe
      pid = Process.spawn(chi_env(dir, server), RbConfig.ruby, ChiCli::CHI, "-p", "count slowly", "--non-interactive",
                          in: File::NULL, out: out_w, err: err_w, chdir: dir)
      out_w.close
      err_w.close
      expect(wait_until(timeout: 15) { server.requests.any? { |r| r.path == "/completion" } }).to be_truthy
      Process.kill("INT", pid)
      _, status = Process.wait2(pid)
      out = out_r.read
      err = err_r.read

      expect(status.exitstatus).to eq(130), err
      expect(out).to eq("")
      id = err[/\ASession: (\S+)/, 1]
      expect(err).not_to include("from ")
      expect(err.lines.last).to eq("chi: canceled (Ctrl-C); the session is kept: continue it with chi --resume #{id}\n")
      saved = JSON.parse(File.read(File.join(dir, "state", "samagotchi", "sessions", "#{id}.json")))
      expect(saved["messages"]).to include(include("role" => "user", "content" => "count slowly"))
    ensure
      Process.kill("KILL", pid) if pid && !status
    end
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
