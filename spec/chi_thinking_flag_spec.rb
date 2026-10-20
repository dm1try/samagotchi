# frozen_string_literal: true

require "tmpdir"
require "json"
require "support/fake_provider_server"

# --thinking LEVEL on a session-starting run: the session's own level
# (saved in its file), first in the order, above SAMAGOTCHI_THINKING_LEVEL.
# chi web's is a default for its workers instead (thinking.level). One
# example runs a real bin/chi; the rest fork it (ChiCli#fork_chi).
RSpec.describe "chi --thinking" do
  it "refuses a value that isn't a level" do
    _out, err, status = fork_chi("--thinking", "on", "--help")

    expect(status.exitstatus).not_to eq(0)
    expect(err).to include("--thinking on")
  end

  it "is listed in --help with its levels" do
    out, = fork_chi("--help")

    expect(out).to include("--thinking LEVEL")
    expect(out).to include("off|low|medium|high|default")
  end

  # One --non-interactive turn against a fake llama.cpp, forked or with
  # +spawn+ a real process; returns the prompt chi sent (the default
  # profile, qwen36).
  def sent_prompt(*args, env: {}, saved: nil, spawn: false)
    server = FakeProviderServer.start
    server.default("/completion", sse: ["data: #{JSON.generate(content: "ok", stop: true)}\n\n"])
    Dir.mktmpdir do |dir|
      env = { "XDG_CONFIG_HOME" => File.join(dir, "config"), "XDG_STATE_HOME" => File.join(dir, "state"), "HOME" => dir,
              "SAMAGOTCHI_DEFAULT_MODEL" => "spec-model", "SAMAGOTCHI_MODEL_PROFILE" => nil,
              "SAMAGOTCHI_SERVER_HOST" => "127.0.0.1", "SAMAGOTCHI_SERVER_PORT" => server.port.to_s }.merge(env)
      _out, err, status = run_or_fork_chi(*args, "--non-interactive", "-p", "hi", spawn: spawn, env: env, chdir: dir)
      raise "chi failed: #{err}" unless status.success?

      files = Dir.glob(File.join(dir, "state", "**", "*.json")).select { |path| File.basename(path, ".json").match?(/\A\h{8}-/) }
      saved&.replace(files.map { |path| JSON.parse(File.read(path)) })
    end
    server.requests.find { |r| r.path == "/completion" }.json["prompt"]
  ensure
    server&.stop
  end

  it "turns thinking off for the run: Qwen's empty thought after the cue, no turn preamble" do
    off = sent_prompt("--thinking", "off", spawn: true)
    expect(off).to end_with("<|im_start|>assistant\n<think>\n\n</think>\n\n")
    expect(off).not_to include("Turn preamble")

    plain = sent_prompt
    expect(plain).to end_with("<|im_start|>assistant\n")
    expect(plain).to include("Turn preamble")
  end

  it "is the session's own level: saved in its file, and above the env" do
    saved = []
    expect(sent_prompt("--thinking", "low", env: { "SAMAGOTCHI_THINKING_LEVEL" => "off" }, saved: saved)).to end_with("assistant\n")
    expect(saved.map { |data| data["thinking"] }).to eq(["low"])
  end

  it "leaves the session without a level of its own for default: the env's then holds" do
    saved = []
    expect(sent_prompt("--thinking", "default", env: { "SAMAGOTCHI_THINKING_LEVEL" => "off" }, saved: saved))
      .to end_with("<think>\n\n</think>\n\n")
    expect(saved.map { |data| data["thinking"] }).to eq([nil])
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
      path = Dir.glob(File.join(dir, "state", "**", "*.json")).find { |p| File.basename(p).match?(/\A\h{8}-/) }

      _out, err, status = chi_run.call("--no-shared", "--resume", File.basename(path, ".json"), "--thinking", "high",
                                       "--non-interactive", "-p", "/help")
      expect(status).to be_success, err
      expect(JSON.parse(File.read(path))["thinking"]).to eq("high")
    end
  ensure
    server&.stop
  end
end
