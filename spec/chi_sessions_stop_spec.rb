# frozen_string_literal: true

require "open3"
require "stringio"
require "rbconfig"
require "tmpdir"
require "spec_helper"
require "samagotchi/session"
require "samagotchi/sessions_command"
require "samagotchi/session_access/local"
require_relative "support/remote_backend"

# The run that reads stdout and stderr interleaved (2>&1) is a real bin/chi;
# the rest fork it (ChiCli#fork_chi).
RSpec.describe "chi sessions stop" do
  let(:chi) { File.expand_path("../bin/chi", __dir__) }
  let(:xdg_state) { Dir.mktmpdir("chi-sessions-stop") }
  let(:state_dir) { Samagotchi::Session.default_state_dir(env: { "XDG_STATE_HOME" => xdg_state }) }
  let(:env) { { "XDG_STATE_HOME" => xdg_state } }

  after { FileUtils.rm_rf(xdg_state) }

  # chi sessions *args, forked.
  def chi_sessions(*args)
    fork_chi("sessions", *args, env: env)
  end

  it "stops the session and says a resume starts a fresh worker" do
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
    session.save(state_dir: state_dir)

    out, err, status = chi_sessions("stop", session.id)

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
    _out, err, status = chi_sessions("stop", "nope")

    expect(status.exitstatus).to eq(1)
    expect(err).to include("nope")
  end

  it "asks for an id" do
    _out, err, status = chi_sessions("stop")

    expect(status.exitstatus).to eq(2)
    expect(err).to include("Usage: chi sessions stop ID...")
  end

  it "lists stop in the help" do
    out, _err, _status = chi_sessions("--help")

    expect(out).to include("stop ID")
  end

  describe "what it says of the worker, on either backend" do
    let(:out) { StringIO.new }
    let(:err) { StringIO.new }

    def stop(*ids)
      access = backend_access(state_dir) || Samagotchi::SessionAccess::Local.new(state_dir: state_dir)
      Samagotchi::SessionsCommand.new(["stop", *ids], stdout: out, stderr: err, access: access).run
    end

    RemoteBackend.both(self) do
      let(:session) do
        Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap { |s| s.save(state_dir: state_dir) }
      end

      it "says the worker let go, or that it is still shutting down, in the same words (chi --remote NAME --resume remotely)" do
        allow(Samagotchi::SessionManager).to receive(:stop_session).and_return(true)
        expect(stop(session.id)).to eq(0)
        expect(out.string).to eq("Stopped session #{session.id}. #{via.resume(session.id)} starts a fresh worker.\n")

        allow(Samagotchi::SessionManager).to receive(:stop_session).and_return(false)
        expect(stop(session.id)).to eq(0)
        expect(err.string).to eq("Stopped session #{session.id}, but its worker is still shutting down; " \
                                 "try #{via.resume(session.id)} in a moment.\n")
      end
    end
  end
end
