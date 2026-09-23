# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"
require "spec_helper"
require "samagotchi/session"

RSpec.describe "chi sessions stop" do
  let(:chi) { File.expand_path("../bin/chi", __dir__) }
  let(:xdg_state) { Dir.mktmpdir("chi-sessions-stop") }
  let(:state_dir) { Samagotchi::Session.default_state_dir(env: { "XDG_STATE_HOME" => xdg_state }) }
  let(:env) { { "XDG_STATE_HOME" => xdg_state } }

  after { FileUtils.rm_rf(xdg_state) }

  def run_chi(*args)
    Open3.capture3(env, RbConfig.ruby, chi, "sessions", *args, stdin_data: "")
  end

  it "stops the session and says a resume starts a fresh worker" do
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
    session.save(state_dir: state_dir)

    out, err, status = run_chi("stop", session.id)

    expect(status.exitstatus).to eq(0), err
    expect(out).to include("Stopped session #{session.id}")
    expect(Samagotchi::Session.load(session.id, state_dir: state_dir).status)
      .to eq(Samagotchi::Session::STATUS_STOPPED)
  end

  it "fails on an unknown session" do
    _out, err, status = run_chi("stop", "nope")

    expect(status.exitstatus).to eq(1)
    expect(err).to include("nope")
  end

  it "asks for an id" do
    _out, err, status = run_chi("stop")

    expect(status.exitstatus).to eq(1)
    expect(err).to include("Usage: chi sessions stop ID")
  end

  it "lists stop in the help" do
    out, _err, _status = run_chi("--help")

    expect(out).to include("stop ID")
  end
end
