# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"
require "json"
require "support/fake_provider_server"

# --profile (an alias of the generated --model-profile) overrides the prompt
# profile for every model in the process; bin/chi copies it into
# SAMAGOTCHI_MODEL_PROFILE so workers follow.
RSpec.describe "chi --profile" do
  let(:chi) { File.expand_path("../bin/chi", __dir__) }

  # One --non-interactive turn against a fake llama.cpp; returns the prompt
  # chi sent. The name "spec-model" says neither family, so only the flag
  # can make it qwen36.
  def sent_prompt(*args)
    server = FakeProviderServer.start
    server.default("/completion", sse: ["data: #{JSON.generate(content: "ok", stop: true)}\n\n"])
    Dir.mktmpdir do |dir|
      env = { "XDG_CONFIG_HOME" => File.join(dir, "config"), "XDG_STATE_HOME" => File.join(dir, "state"), "HOME" => dir,
              "SAMAGOTCHI_DEFAULT_MODEL" => "spec-model", "SAMAGOTCHI_MODEL_PROFILE" => nil,
              "SAMAGOTCHI_SERVER_HOST" => "127.0.0.1", "SAMAGOTCHI_SERVER_PORT" => server.port.to_s }
      _out, err, status = Open3.capture3(env, RbConfig.ruby, chi, *args, "--non-interactive", "-p", "hi", stdin_data: "",
                                         chdir: dir)
      raise "chi failed: #{err}" unless status.success?
    end
    server.requests.find { |r| r.path == "/completion" }.json["prompt"]
  ensure
    server&.stop
  end

  it "sets the profile for the run, and --model-profile does too" do
    pending "W1: the Engine resolves the profile (waits for attached slice B)"
    expect(sent_prompt).not_to include("<|im_start|>")
    expect(sent_prompt("--profile", "qwen36")).to start_with("<|im_start|>system")
    expect(sent_prompt("--model-profile", "qwen36")).to start_with("<|im_start|>system")
  end

  it "refuses an unknown profile" do
    _out, err, status = Open3.capture3(RbConfig.ruby, chi, "--profile", "llama", "--help", stdin_data: "")

    expect(status.exitstatus).not_to eq(0)
    expect(err).to include("--profile llama")
  end

  it "is listed in --help" do
    out, = Open3.capture3(RbConfig.ruby, chi, "--help", stdin_data: "")

    expect(out.lines.find { |l| l.include?("--profile ") }).to include("qwen36|gemma4")
  end
end
