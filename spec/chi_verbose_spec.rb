# frozen_string_literal: true

require "tmpdir"
require "json"
require "support/fake_provider_server"
require "support/detached_session"

# `chi -v` runs attached: the TUI shows its session's debug records (the
# worker it spawned logs at debug) on stdout, above the live region, and
# mirrors nothing to stderr. A real bin/chi (and its worker) each.
RSpec.describe "chi -v" do
  include SpecDetachedSession

  def chi_run(*args)
    server = FakeProviderServer.start
    server.default("/completion", sse: ["data: #{JSON.generate(content: "PONG", stop: true)}\n\n"])
    Dir.mktmpdir do |dir|
      env = isolated_chi_env(dir, "SAMAGOTCHI_DEFAULT_MODEL" => "spec-model", "SAMAGOTCHI_SERVER_HOST" => "127.0.0.1",
                                  "SAMAGOTCHI_SERVER_PORT" => server.port.to_s)
      result = run_chi(*args, env: env, chdir: dir, timeout: 60)
      # chi -p detaches: end its worker before the dir goes.
      stop_detached_session(result.first, env: env, chdir: dir)
      result
    end
  ensure
    server&.stop
  end

  it "shows this session's debug records, the worker's among them, attached" do
    out, err, status = chi_run("-v", "-p", "Reply with exactly: PONG")

    expect(status.exitstatus).to eq(0), err
    expect(out).to include("PONG")
    sid = out[/Detached; the session keeps running\. Re-attach with: chi --attach (\h{8})/, 1]
    expect(sid).not_to be_nil, out
    records = out.lines.filter_map { |line| Samagotchi::LogLine.parse(line.gsub(/\e\[[\d;]*m/, "")) }
    expect(records.map(&:level)).to include("DEBUG")
    expect(records.map(&:sid).uniq).to eq([sid])
    # A worker's records: another pid than the TUI's.
    expect(records.map(&:pid).uniq.size).to be > 1
    expect(err).not_to include("DEBUG")
  end

  it "shows none without it" do
    out, err, status = chi_run("-p", "Reply with exactly: PONG")

    expect(status.exitstatus).to eq(0), err
    expect(out.lines.filter_map { |line| Samagotchi::LogLine.parse(line) }).to be_empty
  end
end
