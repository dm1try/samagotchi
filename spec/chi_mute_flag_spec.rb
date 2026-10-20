# frozen_string_literal: true

require "tmpdir"
require "json"
require "support/fake_provider_server"

# --mute on the plain REPL path (--non-interactive): the muted memory is
# out of the prompt bin/chi's TerminalUI builds. The identity memory is the
# one the system bundle installs into any fresh config dir, so it is there
# to mute without a fixture. One run is a real bin/chi; the rest fork it
# (ChiCli#fork_chi).
RSpec.describe "chi --mute" do
  # One --non-interactive turn against a fake llama.cpp, forked or with
  # +spawn+ a real process: [the prompt chi sent, stderr].
  def sent_prompt(*args, spawn: false)
    server = FakeProviderServer.start
    server.default("/completion", sse: ["data: #{JSON.generate(content: "ok", stop: true)}\n\n"])
    Dir.mktmpdir do |dir|
      env = { "XDG_CONFIG_HOME" => File.join(dir, "config"), "XDG_STATE_HOME" => File.join(dir, "state"), "HOME" => dir,
              "SAMAGOTCHI_DEFAULT_MODEL" => "spec-model", "SAMAGOTCHI_MODEL_PROFILE" => nil,
              "SAMAGOTCHI_SERVER_HOST" => "127.0.0.1", "SAMAGOTCHI_SERVER_PORT" => server.port.to_s }
      _out, err, status = run_or_fork_chi(*args, "--non-interactive", "-p", "hi", spawn: spawn, env: env, chdir: dir)
      raise "chi failed: #{err}" unless status.success?

      [server.requests.find { |r| r.path == "/completion" }.json["prompt"], err]
    end
  ensure
    server&.stop
  end

  it "keeps the muted memory out of the REPL's prompt: its index line and the identity auto-load" do
    prompt, = sent_prompt
    expect(prompt).to include("**identity**")
    expect(prompt).to include("System identity (auto-loaded")

    prompt, err = sent_prompt("--mute", "identity", spawn: true)
    expect(prompt).not_to include("**identity**")
    expect(prompt).not_to include("System identity (auto-loaded")
    expect(err).not_to include("Warning")
  end

  it "warns about a --mute that matches no memory, and starts anyway" do
    _prompt, err = sent_prompt("--mute", "nope")
    expect(err).to include("Warning: --mute 'nope' matches no memory")
  end
end
