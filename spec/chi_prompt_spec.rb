# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/session"
require "support/fake_provider_server"

# `chi -p … --non-interactive` as a script or a parent agent runs it: stdout
# holds the answer alone, everything else goes to stderr, and the exit
# status says how the turn ended (a fake model server answers).
RSpec.describe "chi -p --non-interactive" do
  def run_chi(*args, server: nil, env: {})
    Dir.mktmpdir do |dir|
      env = isolated_chi_env(dir, "SAMAGOTCHI_DEFAULT_MODEL" => "spec-model", "SAMAGOTCHI_SERVER_HOST" => "127.0.0.1",
                                  "SAMAGOTCHI_SERVER_PORT" => (server&.port || 9).to_s, "SAMAGOTCHI_RETRY_MAX" => "0")
                         .merge(env)
      out, err, status = super(*args, env: env, chdir: dir)
      sessions = File.join(dir, "state", "samagotchi", "sessions")
      kept = Dir.exist?(sessions) ? Dir.children(sessions).reject { |name| name.start_with?(".") } : []
      [out, err, status, kept]
    end
  end

  def answer(text)
    ["data: #{JSON.generate(content: text, stop: true)}\n\n"]
  end

  it "exits 1 with a line on stderr when the answer is empty" do
    server = FakeProviderServer.start
    server.default("/completion", sse: answer(""))

    _out, err, status, = run_chi("-p", "hi", "--non-interactive", server: server)

    expect(status.exitstatus).to eq(1), err
    expect(err).to include("chi: the model gave an empty answer\n")
  ensure
    server&.stop
  end
end
