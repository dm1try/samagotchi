# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "spec_helper"
require "samagotchi/session"
require "samagotchi/sessions_command"
require "samagotchi/session_metrics"
require "samagotchi/worker_sidecar"
require "samagotchi/owner_lock"
require "samagotchi/engine"
require "samagotchi/bridge"
require "support/test_kernel"

# `chi sessions stats ID`: a session's cost, tokens and progress without
# running a model turn — a live worker's GET stats, else the snapshot an
# analytics.json on disk rebuilds (SessionMetrics), never starting a worker.
RSpec.describe "chi sessions stats" do
  let(:xdg_state) { Dir.mktmpdir("chi-sessions-stats") }
  let(:outside) { Dir.mktmpdir("chi-sessions-stats-cwd") }
  let(:state_dir) { Samagotchi::Session.default_state_dir(env: { "XDG_STATE_HOME" => xdg_state }) }
  let(:env) { { "XDG_STATE_HOME" => xdg_state, "CI" => nil, "RACK_ENV" => nil, "SAMAGOTCHI_ENV" => nil } }
  let(:locks) { [] }

  after do
    locks.each(&:release)
    FileUtils.rm_rf(xdg_state)
    FileUtils.rm_rf(outside)
  end

  def run_stats(*args)
    out = StringIO.new
    err = StringIO.new
    code = with_env(env) { Dir.chdir(outside) { Samagotchi::SessionsCommand.new(["stats", *args], stdout: out, stderr: err).run } }
    [out.string, err.string, code]
  end

  def make(model: "gemma4", status: "idle")
    Samagotchi::Session.new_session(mode: "assist", model_name: model, working_directory: "/work/app").tap do |s|
      s.status = status
      s.save(state_dir: state_dir)
    end
  end

  def dir_of(session) = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)

  # A saved analytics.json with one finished turn: 1520 prompt / 240
  # completion server tokens over a 8192-token window, one tool call, one
  # retry — the record shapes SessionMetrics#load_persisted reads back.
  def save_analytics(session, turns: 1)
    dir = dir_of(session)
    FileUtils.mkdir_p(dir)
    started = Time.now - 60
    turn_records = Array.new(turns) do |i|
      {
        "id" => "turn-#{i}", "status" => "completed",
        "started_at" => (started + (i * 10)).iso8601(3), "completed_at" => (started + (i * 10) + 1).iso8601(3),
        "duration_ms" => 1000, "continue" => false, "model" => session.model_name, "generations" => 1,
        "prompt_tokens" => 1520, "prompt_tokens_max" => 1520, "prompt_tokens_sum" => 1520,
        "completion_tokens" => 240, "context_used_tokens" => 1760,
        "token_source" => "server", "gen_ms" => 812, "tool_calls" => 1, "tool_errors" => 0,
        "iterations" => 1, "retries" => 1, "cuts" => 0, "capped" => 0,
        "cached_tokens_sum" => 0, "cache_write_tokens_sum" => 0, "reprefill_tokens_sum" => 0,
        "reasoning_tokens" => 0, "cost" => 0.0, "cost_estimate" => 0.0, "decode_ms" => 0, "decode_tokens" => 0
      }
    end
    tool_records = Array.new(turns) do |i|
      { "id" => "call-#{i}", "turn_id" => "turn-#{i}", "iteration" => 1, "call_index" => 1, "tool" => "read",
        "status" => "ok", "started_at" => (started + (i * 10)).iso8601(3), "duration_ms" => 12 }
    end
    File.write(File.join(dir, "analytics.json"), JSON.pretty_generate({
      "session_id" => session.id,
      "turns" => turns, "cancellations" => 0,
      "tokens" => { "prompt_sum" => 1520 * turns, "completion_sum" => 240 * turns, "cached_sum" => 0,
                    "cache_write_sum" => 0, "reprefill_sum" => 0, "reasoning_sum" => 0, "cost_sum" => 0,
                    "cost_estimate_sum" => 0, "decode_ms_sum" => 0, "decode_tokens_sum" => 0,
                    "avg_decode_tps" => nil, "last_decode_tps" => nil, "last_prefill_tps" => nil,
                    "tps_source" => nil, "source" => "server" },
      "context" => { "used_tokens" => 1760, "window_tokens" => 8192, "window_source" => "server",
                     "source" => "server", "at" => (started + 1).iso8601(3) },
      "memory_index" => nil, "profile" => nil, "profile_source" => nil,
      "served_model" => nil, "served_model_for" => nil,
      "tool_calls_total" => turns, "tool_calls_by_tool" => { "read" => turns }, "tool_errors" => 0,
      "iterations_total" => turns, "gen_latency_ms" => 812 * turns, "retries" => turns,
      "cuts" => 0, "capped" => 0,
      "started_at" => started.iso8601(3), "last_activity_at" => (started + 1).iso8601(3),
      "session_duration_ms" => 1000,
      "turn_records" => turn_records, "tool_records" => tool_records,
      "active_turn" => nil, "active_tools" => []
    }) + "\n")
  end

  # A sidecar whose port refuses a connect is stale: removed, so the stats
  # falls back to the disk snapshot.
  def write_dead_sidecar(session)
    Samagotchi::WorkerSidecar.new(port: 1, bind: "127.0.0.1", session_id: session.id,
                                  started_at: Time.now.iso8601(3), version: nil,
                                  input_format: nil, features: []).write(dir_of(session))
  end

  describe "a stopped session (no live worker)" do
    it "prints the header and the /stats text from analytics.json, exit 0" do
      session = make
      save_analytics(session)

      out, err, code = run_stats(session.id)

      expect([err, code]).to eq(["", 0])
      lines = out.lines.map(&:chomp)
      expect(lines.first).to eq("#{session.id[0, 8]}  idle    gemma4")
      expect(lines[1..]).to eq([
        "turns:            1",
        "tool calls:       1 (0 errors)",
        "  by tool:        read=1",
        "iterations:       1",
        "tokens in/out:    1520/240 (all requests, server-reported)",
        "gen latency (ms): 812",
        "cancellations:    0",
        "retries:          1",
        "thinking cuts:    0",
        "output cap hits:  0",
        "context used:     1760 tokens (21.5%)",
        "context window:   8192 tokens (server)"
      ])
    end

    it "resolves a unique prefix of the id" do
      session = make
      save_analytics(session)

      out, _err, code = run_stats(session.id[0, 8])

      expect(code).to eq(0)
      expect(out.lines.first).to eq("#{session.id[0, 8]}  idle    gemma4\n")
    end

    it "--format json prints one object with the snapshot as metrics, live false" do
      session = make(status: "running")
      save_analytics(session, turns: 2)

      out, err, code = run_stats("--format", "json", session.id)

      expect([err, code]).to eq(["", 0])
      report = JSON.parse(out)
      expect(report["session_id"]).to eq(session.id)
      expect(report["status"]).to eq("running")
      expect(report["live"]).to be(false)
      metrics = report["metrics"]
      expect(metrics["turns"]).to eq(2)
      expect(metrics["tool_calls_total"]).to eq(2)
      expect(metrics["tokens"]).to include("prompt_sum" => 3040, "completion_sum" => 480, "source" => "server")
      expect(metrics["context"]).to include("used_tokens" => 1760, "window_tokens" => 8192)
      expect(metrics["retries"]).to eq(2)
      # The newest saved turn and its tool calls, as a live worker's
      # snapshot carries its newest finished turn (never an empty list
      # while turns happened); the full history is analytics.json.
      expect(metrics["turn_records"].map { |record| record["id"] }).to eq(%w[turn-1])
      expect(metrics["tool_records"].map { |record| record["id"] }).to eq(%w[call-1])
    end

    it "without an analytics.json prints what is known and (no metrics yet), exit 0" do
      session = make

      out, err, code = run_stats(session.id)

      expect([err, code]).to eq(["", 0])
      expect(out).to eq("#{session.id[0, 8]}  idle    gemma4\n(no metrics yet)\n")

      out, _err, code = run_stats("--format", "json", session.id)
      expect(code).to eq(0)
      report = JSON.parse(out)
      expect(report).to include("session_id" => session.id, "status" => "idle", "live" => false, "metrics" => nil)
    end

    it "refuses an unknown id with stop's wording, exit 1" do
      _out, err, code = run_stats("nope")

      expect(code).to eq(1)
      expect(err).to include("nope")
    end

    it "refuses an ambiguous prefix with stop's wording, exit 1" do
      first = make
      second = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/work/app")
      second.id = first.id[0, 8] + "0000-0000-0000-000000000000"
      second.save(state_dir: state_dir)

      _out, err, code = run_stats(first.id[0, 8])

      expect(code).to eq(1)
      expect(err).to include("matches 2 sessions")
    end

    it "asks for an id, and refuses an unknown flag or format with its usage (exit 2)" do
      session = make

      expect(run_stats).to eq(["", "chi sessions stats: give a session id\n#{described_class_usage}", 2])
      expect(run_stats("--bogus", session.id)).to eq(["", "chi sessions stats: unknown option --bogus\n#{described_class_usage}", 2])
      expect(run_stats("--format", "yaml", session.id))
        .to eq(["", "chi sessions stats: unknown format \"yaml\": use --format text|json\n#{described_class_usage}", 2])
    end

    def described_class_usage
      "Usage: chi sessions stats ID [--format text|json]\n"
    end
  end

  describe "a live worker" do
    let(:bridges) { [] }

    after { bridges.each(&:stop) }

    # A live worker's Bridge (no turn loop: it answers requests only), with
    # the session owned by a worker lock, as a real worker's is.
    def serve(session)
      locks << Samagotchi::OwnerLock.acquire(dir_of(session), kind: "worker")
      engine = Samagotchi::Engine.new(client: test_client, kernel: test_kernel)
      bridge = Samagotchi::Bridge.new(engine: engine, state_dir: state_dir, session_id: session.id,
                                      heartbeat_interval: 5, input_format: Samagotchi::SessionInbox::INPUT_FORMAT)
      bridge.start
      bridges << bridge
      engine
    end

    it "asks its Bridge for GET stats: no model call, live true in json, exit 0" do
      session = make(status: "running")
      engine = serve(session)
      save_analytics(session) # the worker's own metrics are empty: what the Bridge answers wins
      allow(engine).to receive(:stats_snapshot).and_return(
        { turns: 7, tool_calls_total: 3, tool_errors: 0, tool_calls_by_tool: { "execute" => 3 },
          iterations_total: 4, tokens: { prompt_sum: 900, completion_sum: 120, source: "estimate" },
          gen_latency_ms: 100, cancellations: 0, retries: 0, cuts: 0, capped: 0,
          context: { used_tokens: 1020, window_tokens: 8192, window_source: "server" } }
      )

      out, err, code = run_stats(session.id)
      expect([err, code]).to eq(["", 0])
      expect(out.lines.first).to eq("#{session.id[0, 8]}  running gemma4\n")
      expect(out).to include("turns:            7")
      expect(out).not_to include("1520/240")

      out, _err, code = run_stats("--format", "json", session.id)
      expect(code).to eq(0)
      report = JSON.parse(out)
      expect(report).to include("session_id" => session.id, "status" => "running", "live" => true)
      expect(report["metrics"]["turns"]).to eq(7)
      expect(engine).to have_received(:stats_snapshot).at_least(:once)
    end

    it "falls back to the disk snapshot when the worker does not answer in time, and says so" do
      session = make(status: "running")
      save_analytics(session)
      # A sidecar for a port nothing listens on: the probe finds it stale.
      write_dead_sidecar(session)
      # The session's owner is still a worker: one that stopped answering.
      locks << Samagotchi::OwnerLock.acquire(dir_of(session), kind: "worker")

      out, err, code = run_stats(session.id)

      expect([err, code]).to eq(["", 0])
      expect(out.lines.first).to eq("#{session.id[0, 8]}  running gemma4\n")
      expect(out).to include("(no live worker answered; from the saved analytics.json)")
      expect(out).to include("turns:            1")
    end
  end

  it "lists stats in the help" do
    out = StringIO.new
    Samagotchi::SessionsCommand.new(["--help"], stdout: out, stderr: StringIO.new).run

    expect(out.string).to include("stats ID")
    expect(out.string).to include("--format text|json")
  end
end
