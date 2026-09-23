# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"
require "json"
require "support/fake_provider_server"

# Generated bool config flags are --[no-]: the ones that default to on
# (context.status, thinking.turn_preamble) are only useful switched off.
RSpec.describe "chi --[no-] bool config flags" do
  let(:chi) { File.expand_path("../bin/chi", __dir__) }

  # One --non-interactive turn against a fake llama.cpp; returns the prompt
  # chi sent (the default qwen36 profile carries the turn preamble).
  def sent_prompt(*args)
    server = FakeProviderServer.start
    server.default("/completion", sse: ["data: #{JSON.generate(content: "ok", stop: true)}\n\n"])
    Dir.mktmpdir do |dir|
      env = { "XDG_CONFIG_HOME" => File.join(dir, "config"), "XDG_STATE_HOME" => File.join(dir, "state"), "HOME" => dir,
              "SAMAGOTCHI_DEFAULT_MODEL" => "spec-model", "SAMAGOTCHI_MODEL_PROFILE" => nil,
              "SAMAGOTCHI_THINKING_TURN_PREAMBLE" => nil,
              "SAMAGOTCHI_SERVER_HOST" => "127.0.0.1", "SAMAGOTCHI_SERVER_PORT" => server.port.to_s }
      _out, err, status = Open3.capture3(env, RbConfig.ruby, chi, *args, "--non-interactive", "-p", "hi", stdin_data: "",
                                         chdir: dir)
      raise "chi failed: #{err}" unless status.success?
    end
    server.requests.find { |r| r.path == "/completion" }.json["prompt"]
  ensure
    server&.stop
  end

  it "switches a default-on setting off with --no-" do
    expect(sent_prompt).to include("Turn preamble:")
    expect(sent_prompt("--no-thinking-turn-preamble")).not_to include("Turn preamble:")
  end

  it "lists the flags as --[no-] with their default" do
    out, = Open3.capture3(RbConfig.ruby, chi, "--help", stdin_data: "")

    expect(out.lines.find { |l| l.include?("context-status ") }).to include("--[no-]context-status").and include("default on")
    expect(out.lines.find { |l| l.include?("log-disable ") }).to include("--[no-]log-disable").and include("default off")
  end
end
