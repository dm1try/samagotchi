# frozen_string_literal: true

require "tmpdir"
require "json"
require "samagotchi/session"
require "samagotchi/log_path"
require "support/fake_provider_server"

# `chi scratch`: the run options, for a session that leaves
# nothing behind (a fake model server answers the one turn). One example
# runs a real bin/chi; the rest fork it (ChiCli#fork_chi).
RSpec.describe "chi scratch" do
  # chi *args in its own temp home, forked or with +spawn+ a real process:
  # [stdout, stderr, status, the session files left, the log]. +log_until+:
  # the log is read once it matches (a detached worker's last lines can
  # come after chi exits).
  def chi_scratch(*args, server: nil, spawn: false, log_until: nil)
    Dir.mktmpdir do |dir|
      env = isolated_chi_env(dir, "SAMAGOTCHI_DEFAULT_MODEL" => "spec-model", "SAMAGOTCHI_SERVER_HOST" => "127.0.0.1",
                                  "SAMAGOTCHI_SERVER_PORT" => (server&.port || 9).to_s)
      out, err, status = run_or_fork_chi(*args, spawn: spawn, env: env, chdir: dir)
      sessions = File.join(dir, "state", "samagotchi", "sessions")
      left = Dir.exist?(sessions) ? Dir.children(sessions).reject { |name| name.start_with?(".") } : []
      log = File.join(dir, "state", "samagotchi", Samagotchi::LogPath::FILENAME)
      read_log = -> { File.exist?(log) ? File.read(log) : "" }
      wait_for("the log to match #{log_until.inspect}", seen: -> { read_log.call.lines.last(3).join }) { read_log.call.match?(log_until) } if log_until
      [out, err, status, left, read_log.call]
    end
  end

  it "runs a -p --non-interactive turn and leaves no session behind; no delegate, memories read as usual" do
    server = FakeProviderServer.start
    server.default("/completion", sse: ["data: #{JSON.generate(content: "PONG", stop: true)}\n\n"])

    out, err, status, left = chi_scratch("scratch", "-p", "Reply with exactly: PONG", "--non-interactive",
                                         "--memory", "identity", server: server, spawn: true)

    expect(status.exitstatus).to eq(0), err
    expect(err).to start_with("Scratch session: nothing is kept, it is deleted when you leave.\n")
    expect(out).to eq("PONG\n")
    expect(left).to be_empty
    prompt = server.requests.find { |r| r.path == "/completion" }.json["prompt"]
    expect(prompt).to include("**identity**", "memory_write")
    expect(prompt).not_to include("delegate_result")
    expect(prompt).not_to match(/\bdelegate\b.*child session/i)
  ensure
    server&.stop
  end

  it "runs attached without --non-interactive: a scratch worker answers, and the session and its worker go as it ends" do
    server = FakeProviderServer.start
    server.default("/completion", sse: ["data: #{JSON.generate(content: "PONG", stop: true)}\n\n"])

    # stdin is empty: the attached TUI runs the -p turn, then leaves at the
    # input's end, as Ctrl-D does.
    # The worker's last lines: chi's own delete (stop: true) waits only for
    # the worker's lock, which it frees before it logs its stop and
    # deletes the session too, so chi may exit first, and whichever
    # deletes it second finds it gone (scratch_kept, NotFound).
    gone = /scratch_deleted|scratch_kept.*NotFound/
    out, err, status, left, log = chi_scratch("scratch", "-p", "Reply with exactly: PONG", server: server, spawn: true,
                                                                                           log_until: gone)

    expect(status.exitstatus).to eq(0), err
    expect(out).to start_with("Scratch session: nothing is kept, it is deleted when you leave.\n")
    expect(out).to include("PONG")
    expect(out.lines.last).to eq("Scratch session deleted.\n")
    expect(left).to be_empty
    # A worker ran the session, stopped and went with it.
    expect(log).to match(/worker .* start cwd=/).and include("stop reason=").and match(gone)
    # The worker's Engine is a scratch one: no delegate tool, memory_write refuses.
    prompt = server.requests.find { |r| r.path == "/completion" }.json["prompt"]
    expect(prompt).not_to match(/\bdelegate\b.*child session/i)
  ensure
    server&.stop
  end

  {
    "--resume" => %w[--resume abc],
    "--attach" => %w[--attach abc]
  }.each do |flag, args|
    it "refuses #{flag}" do
      _out, err, status, left = chi_scratch("scratch", *args)

      expect(status.exitstatus).to eq(1)
      expect(err).to eq("Error: chi scratch starts a new session in this terminal and keeps nothing; it can't take #{flag}\n")
      expect(left).to be_empty
    end
  end

  %w[--resume --attach].each do |flag|
    it "refuses #{flag} on a scratch session (a killed terminal's leftover here), and keeps it for the sweep" do
      Dir.mktmpdir do |dir|
        env = { "XDG_CONFIG_HOME" => File.join(dir, "config"), "XDG_STATE_HOME" => File.join(dir, "state"), "HOME" => dir,
                "SAMAGOTCHI_SERVER_PORT" => "9" }
        state_dir = Samagotchi::Session.default_state_dir(env: env)
        leftover = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: dir, scratch: true)
        leftover.save(state_dir: state_dir)

        _out, err, status = fork_chi(flag, leftover.id[0, 8], env: env, chdir: dir)

        expect(status.exitstatus).to eq(1)
        expect(err).to eq("Error: #{Samagotchi::Session::SCRATCH_REFUSED}\n")
        expect(Samagotchi::Session.load(leftover.id, state_dir: state_dir).scratch).to be(true)
      end
    end
  end

  it "takes no other command: chi scratch web is an error" do
    _out, err, status, = chi_scratch("scratch", "web")

    expect(status.exitstatus).to eq(1)
    expect(err).to eq("Error: unexpected argument web (see chi --help)\n")
  end

  it "has one line in chi --help" do
    out, = chi_scratch("--help")

    expect(out.lines.grep(/chi scratch/)).to eq(["       chi scratch [options]            a one-time session in this terminal: nothing is kept\n"])
  end
end
