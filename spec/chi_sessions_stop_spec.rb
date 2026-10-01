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
    super("sessions", *args, env: env)
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

  it "stops every id given, in order, and fails on an unknown one" do
    first = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
    first.save(state_dir: state_dir)
    second = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
    second.save(state_dir: state_dir)

    out, err, status = Open3.capture3(env, "#{RbConfig.ruby} #{chi} sessions stop #{first.id} nope #{second.id} 2>&1")

    expect(status.exitstatus).to eq(1), err
    lines = out.lines.map(&:strip).reject(&:empty?)
    expect(lines[0]).to include("Stopped session #{first.id}")
    expect(lines[1]).to include("nope")
    expect(lines[2]).to include("Stopped session #{second.id}")
    [first, second].each do |session|
      expect(Samagotchi::Session.load(session.id, state_dir: state_dir).status)
        .to eq(Samagotchi::Session::STATUS_STOPPED)
    end
  end

  it "fails on an unknown session" do
    _out, err, status = run_chi("stop", "nope")

    expect(status.exitstatus).to eq(1)
    expect(err).to include("nope")
  end

  it "asks for an id" do
    _out, err, status = run_chi("stop")

    expect(status.exitstatus).to eq(2)
    expect(err).to include("Usage: chi sessions stop ID...")
  end

  it "lists stop in the help" do
    out, _err, _status = run_chi("--help")

    expect(out).to include("stop ID")
  end
end
