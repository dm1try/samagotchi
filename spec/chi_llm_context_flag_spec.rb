# frozen_string_literal: true

require "tmpdir"
require "json"
require "support/fake_provider_server"

# --llm-context on the plain REPL path (--non-interactive): the session
# starts with its own strategy (saved in its file), and the native prompt
# declares forget_outputs under forget. One run is a real bin/chi; the rest
# fork it (ChiCli#fork_chi).
RSpec.describe "chi --llm-context" do
  # One --non-interactive turn against a fake llama.cpp, forked or with
  # +spawn+ a real process: its status, stderr, prompt and saved session.
  def chi_turn(*args, spawn: false)
    server = FakeProviderServer.start
    server.default("/completion", sse: ["data: #{JSON.generate(content: "ok", stop: true)}\n\n"])
    Dir.mktmpdir do |dir|
      env = { "XDG_CONFIG_HOME" => File.join(dir, "config"), "XDG_STATE_HOME" => File.join(dir, "state"), "HOME" => dir,
              "SAMAGOTCHI_DEFAULT_MODEL" => "spec-model", "SAMAGOTCHI_MODEL_PROFILE" => nil,
              "SAMAGOTCHI_SERVER_HOST" => "127.0.0.1", "SAMAGOTCHI_SERVER_PORT" => server.port.to_s }
      _out, err, status = run_or_fork_chi(*args, "--non-interactive", "-p", "hi", spawn: spawn, env: env, chdir: dir)
      request = server.requests.find { |r| r.path == "/completion" }
      files = Dir.glob(File.join(dir, "state", "**", "*.json")).select { |path| File.basename(path, ".json").match?(/\A\h{8}-/) }
      saved = files.map { |path| JSON.parse(File.read(path)) }.find { |data| data.key?("llm_context") }
      { status: status, err: err, prompt: request&.json&.fetch("prompt"), saved: saved }
    end
  ensure
    server&.stop
  end

  it "starts the session with its own values: saved, and forget_outputs declared under forget" do
    plain = chi_turn
    expect(plain[:prompt]).not_to include("forget_outputs")
    expect(plain[:saved]["llm_context"]).to be_nil

    run = chi_turn("--llm-context", "stale,forget", "--llm-context-apply", "turn_end", "--llm-context-budget", "64k", spawn: true)

    expect(run[:status]).to be_success
    expect(run[:prompt]).to include("forget_outputs")
    expect(run[:saved]["llm_context"]).to eq("strategy" => %w[stale forget], "apply" => "turn_end", "budget_tokens" => 64_000)
  end

  it "saves the flag on a --resume'd session at once, though no turn runs (-p /help, which saves nothing)" do
    server = FakeProviderServer.start
    server.default("/completion", sse: ["data: #{JSON.generate(content: "ok", stop: true)}\n\n"])
    Dir.mktmpdir do |dir|
      env = { "XDG_CONFIG_HOME" => File.join(dir, "config"), "XDG_STATE_HOME" => File.join(dir, "state"), "HOME" => dir,
              "SAMAGOTCHI_DEFAULT_MODEL" => "spec-model", "SAMAGOTCHI_MODEL_PROFILE" => nil,
              "SAMAGOTCHI_SERVER_HOST" => "127.0.0.1", "SAMAGOTCHI_SERVER_PORT" => server.port.to_s }
      chi_run = ->(*args) { fork_chi(*args, env: env, chdir: dir) }
      chi_run.call("--no-shared", "--non-interactive", "-p", "hi")
      id = File.basename(Dir.glob(File.join(dir, "state", "**", "*.json")).find { |path| File.basename(path).match?(/\A\h{8}-/) }, ".json")

      _out, err, status = chi_run.call("--no-shared", "--resume", id, "--llm-context", "stale", "--non-interactive", "-p", "/help")
      expect(status).to be_success, err
      saved = JSON.parse(File.read(Dir.glob(File.join(dir, "state", "**", "#{id}.json")).first))
      expect(saved["llm_context"]).to eq("strategy" => ["stale"])
    end
  ensure
    server&.stop
  end

  it "refuses a value that isn't one before anything starts" do
    run = chi_turn("--llm-context", "stale,summarize")

    expect(run[:status].exitstatus).to eq(1)
    expect(run[:err]).to include("Error: unknown llm_context strategy summarize (none, or a list of stale, forget)")
    expect(run[:prompt]).to be_nil
  end
end
