# frozen_string_literal: true

require "tmpdir"
require "stringio"
require "spec_helper"
require "samagotchi/session"
require "samagotchi/session_manager"
require "samagotchi/sessions_command"

RSpec.describe "chi sessions restart" do
  let(:xdg_state) { Dir.mktmpdir("chi-sessions-restart") }
  let(:state_dir) { Samagotchi::Session.default_state_dir(env: { "XDG_STATE_HOME" => xdg_state }) }
  let(:env) { { "XDG_STATE_HOME" => xdg_state } }

  after { FileUtils.rm_rf(xdg_state) }

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

  it "says a session with no worker needs no restart (the real thing, no stubs)" do
    session = saved_session

    _out, err, status = run_restart(session.id)

    expect(status).to eq(1)
    expect(err).to eq("session #{session.id} has no running worker; the next prompt starts one on the newest chi\n")
  end

  it "fails on an unknown session and asks for an id" do
    expect(run_restart("nope")).to match(["", /nope/, 1])
    expect(run_restart.last).to eq(2)
  end
end
