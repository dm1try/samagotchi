# frozen_string_literal: true

require "tmpdir"
require "json"
require "support/fake_provider_server"

# --profile (an alias of the generated --model-profile) overrides the prompt
# profile for every model in the process; bin/chi copies it into
# SAMAGOTCHI_MODEL_PROFILE so workers follow. One run is a real bin/chi;
# the rest fork it (ChiCli#fork_chi).
RSpec.describe "chi --profile" do
  # One --non-interactive turn against a fake llama.cpp, forked or with
  # +spawn+ a real process; returns the prompt chi sent. The name
  # "spec-model" says neither family and the fake server has no /props, so
  # without the flag it gets the default, qwen36.
  def sent_prompt(*args, spawn: false)
    server = FakeProviderServer.start
    server.default("/completion", sse: ["data: #{JSON.generate(content: "ok", stop: true)}\n\n"])
    Dir.mktmpdir do |dir|
      env = { "XDG_CONFIG_HOME" => File.join(dir, "config"), "XDG_STATE_HOME" => File.join(dir, "state"), "HOME" => dir,
              "SAMAGOTCHI_DEFAULT_MODEL" => "spec-model", "SAMAGOTCHI_MODEL_PROFILE" => nil,
              "SAMAGOTCHI_SERVER_HOST" => "127.0.0.1", "SAMAGOTCHI_SERVER_PORT" => server.port.to_s }
      _out, err, status = run_or_fork_chi(*args, "--non-interactive", "-p", "hi", spawn: spawn, env: env, chdir: dir)
      raise "chi failed: #{err}" unless status.success?
    end
    server.requests.find { |r| r.path == "/completion" }.json["prompt"]
  ensure
    server&.stop
  end

  it "sets the profile for the run, and --model-profile does too" do
    expect(sent_prompt).to start_with("<|im_start|>system")
    expect(sent_prompt("--profile", "gemma4", spawn: true)).not_to include("<|im_start|>")
    expect(sent_prompt("--model-profile", "gemma4")).not_to include("<|im_start|>")
  end

  it "refuses an unknown profile" do
    _out, err, status = fork_chi("--profile", "llama", "--help")

    expect(status.exitstatus).not_to eq(0)
    expect(err).to include("--profile llama")
  end

  it "is listed in --help" do
    out, = fork_chi("--help")

    expect(out.lines.find { |l| l.include?("--profile ") }).to include("qwen36|gemma4")
  end
end
