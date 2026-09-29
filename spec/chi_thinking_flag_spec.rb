# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"
require "json"
require "support/fake_provider_server"

# --thinking LEVEL: the run's thinking level (thinking.level), outranking
# config.yml; bin/chi copies it into SAMAGOTCHI_THINKING_LEVEL for workers.
RSpec.describe "chi --thinking" do
  let(:chi) { File.expand_path("../bin/chi", __dir__) }

  it "refuses a value that isn't a level" do
    _out, err, status = Open3.capture3(RbConfig.ruby, chi, "--thinking", "on", "--help", stdin_data: "")

    expect(status.exitstatus).not_to eq(0)
    expect(err).to include("--thinking on")
  end

  it "is listed in --help with its levels" do
    out, = Open3.capture3(RbConfig.ruby, chi, "--help", stdin_data: "")

    expect(out).to include("--thinking LEVEL")
    expect(out).to include("off|low|medium|high|default")
  end

  # One --non-interactive turn against a fake llama.cpp; returns the prompt
  # chi sent (the default profile, qwen36).
  def sent_prompt(*args, env: {})
    server = FakeProviderServer.start
    server.default("/completion", sse: ["data: #{JSON.generate(content: "ok", stop: true)}\n\n"])
    Dir.mktmpdir do |dir|
      env = { "XDG_CONFIG_HOME" => File.join(dir, "config"), "XDG_STATE_HOME" => File.join(dir, "state"), "HOME" => dir,
              "SAMAGOTCHI_DEFAULT_MODEL" => "spec-model", "SAMAGOTCHI_MODEL_PROFILE" => nil,
              "SAMAGOTCHI_SERVER_HOST" => "127.0.0.1", "SAMAGOTCHI_SERVER_PORT" => server.port.to_s }.merge(env)
      _out, err, status = Open3.capture3(env, RbConfig.ruby, chi, *args, "--non-interactive", "-p", "hi", stdin_data: "",
                                         chdir: dir)
      raise "chi failed: #{err}" unless status.success?
    end
    server.requests.find { |r| r.path == "/completion" }.json["prompt"]
  ensure
    server&.stop
  end

  it "turns thinking off for the run: Qwen's empty thought after the cue, no turn preamble" do
    off = sent_prompt("--thinking", "off")
    expect(off).to end_with("<|im_start|>assistant\n<think>\n\n</think>\n\n")
    expect(off).not_to include("Turn preamble")

    plain = sent_prompt
    expect(plain).to end_with("<|im_start|>assistant\n")
    expect(plain).to include("Turn preamble")
  end

  it "outranks the env" do
    expect(sent_prompt("--thinking", "default", env: { "SAMAGOTCHI_THINKING_LEVEL" => "off" })).to end_with("assistant\n")
  end
end
