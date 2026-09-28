# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"
require "json"
require "samagotchi/session"
require "support/fake_provider_server"

# `chi scratch`: the run options, for a plain REPL session that leaves
# nothing behind (a fake model server answers the one turn).
RSpec.describe "chi scratch" do
  let(:chi) { File.expand_path("../bin/chi", __dir__) }

  def run_chi(*args, server: nil)
    Dir.mktmpdir do |dir|
      env = { "XDG_CONFIG_HOME" => File.join(dir, "config"), "XDG_STATE_HOME" => File.join(dir, "state"), "HOME" => dir,
              "SAMAGOTCHI_DEFAULT_MODEL" => "spec-model", "SAMAGOTCHI_MODEL_PROFILE" => nil,
              "SAMAGOTCHI_SERVER_HOST" => "127.0.0.1", "SAMAGOTCHI_SERVER_PORT" => (server&.port || 9).to_s }
      out, err, status = Open3.capture3(env, RbConfig.ruby, chi, *args, stdin_data: "", chdir: dir)
      sessions = File.join(dir, "state", "samagotchi", "sessions")
      left = Dir.exist?(sessions) ? Dir.children(sessions).reject { |name| name.start_with?(".") } : []
      [out, err, status, left]
    end
  end

  it "runs a -p --non-interactive turn and leaves no session behind; no delegate, memories read as usual" do
    server = FakeProviderServer.start
    server.default("/completion", sse: ["data: #{JSON.generate(content: "PONG", stop: true)}\n\n"])

    out, err, status, left = run_chi("scratch", "-p", "Reply with exactly: PONG", "--non-interactive",
                                     "--memory", "identity", server: server)

    expect(status.exitstatus).to eq(0), err
    expect(out).to start_with("Scratch session: nothing is kept, it is deleted when you leave.\n")
    expect(out).to include("PONG")
    expect(left).to be_empty
    prompt = server.requests.find { |r| r.path == "/completion" }.json["prompt"]
    expect(prompt).to include("**identity**", "memory_write")
    expect(prompt).not_to include("delegate_result")
    expect(prompt).not_to match(/\bdelegate\b.*child session/i)
  ensure
    server&.stop
  end

  {
    "--resume" => %w[--resume abc],
    "--attach" => %w[--attach abc],
    "--shared" => %w[--shared]
  }.each do |flag, args|
    it "refuses #{flag}" do
      _out, err, status, left = run_chi("scratch", *args)

      expect(status.exitstatus).to eq(1)
      expect(err).to eq("Error: chi scratch starts a new session in this terminal and keeps nothing; it can't take #{flag}\n")
      expect(left).to be_empty
    end
  end

  %w[--resume --attach].each do |flag|
    it "refuses #{flag} on a scratch session a killed REPL left behind, and keeps it for the sweep" do
      Dir.mktmpdir do |dir|
        env = { "XDG_CONFIG_HOME" => File.join(dir, "config"), "XDG_STATE_HOME" => File.join(dir, "state"), "HOME" => dir,
                "SAMAGOTCHI_SERVER_PORT" => "9" }
        state_dir = Samagotchi::Session.default_state_dir(env: env)
        leftover = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: dir, scratch: true)
        leftover.save(state_dir: state_dir)

        _out, err, status = Open3.capture3(env, RbConfig.ruby, chi, flag, leftover.id[0, 8], stdin_data: "", chdir: dir)

        expect(status.exitstatus).to eq(1)
        expect(err).to eq("Error: that's a leftover scratch session; it is deleted at the next sweep (chi sessions clean)\n")
        expect(Samagotchi::Session.load(leftover.id, state_dir: state_dir).scratch).to be(true)
      end
    end
  end

  it "takes no other command: chi scratch web is an error" do
    _out, err, status, = run_chi("scratch", "web")

    expect(status.exitstatus).to eq(1)
    expect(err).to eq("Error: unexpected argument web (see chi --help)\n")
  end

  it "has one line in chi --help" do
    out, = run_chi("--help")

    expect(out.lines.grep(/chi scratch/)).to eq(["       chi scratch [options]            a one-time session in this terminal: nothing is kept\n"])
  end
end
