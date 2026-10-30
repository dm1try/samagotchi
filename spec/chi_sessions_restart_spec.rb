# frozen_string_literal: true

require "tmpdir"
require "stringio"
require "socket"
require "rbconfig"
require "spec_helper"
require "samagotchi/session"
require "samagotchi/session_manager"
require "samagotchi/sessions_command"

RSpec.describe "chi sessions restart" do
  let(:xdg_state) { Dir.mktmpdir("chi-sessions-restart") }
  let(:state_dir) { Samagotchi::Session.default_state_dir(env: { "XDG_STATE_HOME" => xdg_state }) }
  let(:env) { { "XDG_STATE_HOME" => xdg_state } }

  after do
    @replacement_pid ||= Samagotchi::SessionManager.session_owner(@replacement_id, state_dir: state_dir)&.pid if @replacement_id
    [@replacement_pid, @unreachable_pid].compact.uniq.each do |pid|
      Process.kill("TERM", pid)
    rescue Errno::ESRCH
      nil
    end
    wait_for("the replacement worker to release its owner lock") do
      !@replacement_pid || Samagotchi::SessionManager.session_owner(@replacement_id, state_dir: state_dir)&.pid != @replacement_pid
    end
    if @unreachable_pid
      begin
        Process.wait(@unreachable_pid)
      rescue Errno::ECHILD
        nil
      end
    end
    FileUtils.rm_rf(xdg_state)
  end

  def run_restart(*ids)
    out = StringIO.new
    err = StringIO.new
    status = Samagotchi::SessionsCommand.new(["restart", *ids], stdout: out, stderr: err).run
    [out.string, err.string, status]
  end

  def saved_session
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
                       .tap { |s| s.save(state_dir: Samagotchi::Session.default_state_dir) }
  end

  # A worker that holds the session's lock and publishes a sidecar whose
  # port nothing listens on (spec/support/lock_holder.rb).
  def spawn_unreachable_worker(session)
    dir = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)
    listener = TCPServer.new("127.0.0.1", 0)
    port = listener.local_address.ip_port
    listener.close
    sidecar = <<~RUBY
      session_id, port = ARGV[1], ARGV[2]
      Samagotchi::WorkerSidecar.new(port: port.to_i, session_id: session_id, pid: Process.pid,
                                    protocol: Samagotchi::WorkerLink::PROTOCOL, epoch: "old",
                                    started_at: "old", version: "0.18.1", features: ["restart"]).write(ARGV[0])
    RUBY
    @unreachable_pid = spawn_lock_holder(dir, requires: %w[samagotchi/worker_sidecar samagotchi/worker_link],
                                              args: [session.id, port.to_s], holding: sidecar, sleep_for: 60)
    expect(Samagotchi::WorkerLink.resolve(dir, unlink: false)).to be_live
  end

  around { |example| with_env(env) { example.run } }

  it "says which chi the new worker runs" do
    session = saved_session
    allow(Samagotchi::SessionManager).to receive(:restart_session).with(session.id)
      .and_return(Samagotchi::SessionManager::Restarted.new(session_id: session.id, from_version: "0.18.1",
                                                            version: "0.19.0"))

    out, _err, status = run_restart(session.id[0, 8])

    expect(status).to eq(0)
    expect(out).to eq("Restarted session #{session.id} on chi 0.19.0 (was 0.18.1).\n")
  end

  it "says the new worker is still starting when it hadn't published its Bridge yet" do
    session = saved_session
    allow(Samagotchi::SessionManager).to receive(:restart_session)
      .and_return(Samagotchi::SessionManager::Restarted.new(session_id: session.id, from_version: "0.18.1", version: nil))

    expect(run_restart(session.id).first).to eq("Restarting session #{session.id}; its new worker is still starting.\n")
  end

  it "says why not, in words, and fails" do
    session = saved_session
    allow(Samagotchi::SessionManager).to receive(:restart_session)
      .and_raise(Samagotchi::SessionManager::RestartRefused.new(session.id, :question_pending))

    _out, err, status = run_restart(session.id)

    expect(status).to eq(1)
    expect(err).to eq("session #{session.id}: not now: a question or approval waits for an answer\n")
  end

  it "names the session once when the fallback is held or failed" do
    session = saved_session
    %i[fallback_held failed].each do |reason|
      allow(Samagotchi::SessionManager).to receive(:restart_session)
        .and_raise(Samagotchi::SessionManager::RestartRefused.new(session.id, reason, holds: [:turn_running]))

      err = run_restart(session.id)[1]

      expect(err).not_to start_with("session #{session.id}: ")
      expect(err.scan(session.id).size).to eq(reason == :fallback_held ? 2 : 1)
    end
  end

  it "says a session with no worker needs no restart (the real thing, no stubs)" do
    session = saved_session

    _out, err, status = run_restart(session.id)

    expect(status).to eq(1)
    expect(err).to eq("session #{session.id} has no running worker; the next prompt starts one on the newest chi\n")
  end

  it "TERMs an unreachable real worker and starts a successor without a stop marker" do
    session = saved_session
    @replacement_id = session.id
    spawn_unreachable_worker(session)

    out, err, status = run_chi("sessions", "restart", session.id, env: env, timeout: 20)
    expect([err, status]).to eq(["", 0])
    expect(out).to eq("Restarted session #{session.id} on chi #{Samagotchi::VERSION} (was 0.18.1).\n")
    expect(Samagotchi::Session.stopped_marker?(session.id, state_dir: state_dir)).to be(false)

    fresh = wait_for("the replacement worker to publish its Bridge") do
      link = Samagotchi::WorkerLink.resolve(Samagotchi::Session.session_dir(session.id, state_dir: state_dir), unlink: false)
      link if link.live? && link.sidecar.pid != @unreachable_pid
    end
    @replacement_pid = fresh.sidecar.pid
    expect(fresh.sidecar.version).to eq(Samagotchi::VERSION)
  end

  it "refuses a stopped (SIGSTOPped) real worker at once, saying how to continue it, and leaves it be" do
    session = saved_session
    spawn_unreachable_worker(session)
    Process.kill("STOP", @unreachable_pid)
    wait_for("the worker to be stopped") { Samagotchi::ProcessGroup.stopped?(@unreachable_pid) }

    started = SpecWaiting.mono
    _out, err, status = run_restart(session.id)

    expect(status).to eq(1)
    expect(err).to eq("session #{session.id}'s worker (pid #{@unreachable_pid}) is stopped (SIGSTOP or Ctrl-Z) and " \
                      "can't take a restart: continue it with `kill -CONT #{@unreachable_pid}`, then restart again\n")
    expect(SpecWaiting.mono - started).to be < Samagotchi::BridgeClient::READ_TIMEOUT
    expect(Samagotchi::SessionManager.session_owner(session.id, state_dir: state_dir).pid).to eq(@unreachable_pid)
  ensure
    Process.kill("CONT", @unreachable_pid) if @unreachable_pid
  end

  it "fails on an unknown session and asks for an id" do
    expect(run_restart("nope")).to match(["", /nope/, 1])
    expect(run_restart.last).to eq(2)
  end
end
