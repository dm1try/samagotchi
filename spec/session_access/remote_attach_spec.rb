# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "socket"
require "samagotchi/session"
require "samagotchi/session_manager"
require "samagotchi/worker_sidecar"
require "samagotchi/owner_lock"
require "samagotchi/launch_mode"
require "samagotchi/session_access/remote"
require_relative "../support/remote_backend"
require_relative "../support/worker_links"

# SessionAccess::Remote's calls for a remote attach (RemoteConnector,
# RemoteLink), through chi web in this process (RackTransport: the token
# gate and the LAN Host check run): the wake, the worker read, the
# feature check, and their refusals as the classes Local raises.
RSpec.describe Samagotchi::SessionAccess::Remote, "for a remote attach" do
  include WorkerLinks

  let(:state_dir) { Dir.mktmpdir("remote-attach") }
  let(:app) { RemoteBackend.app(state_dir: state_dir) }
  let(:remote) { RemoteBackend.access(state_dir: state_dir, app: app) }
  let(:servers) { [] }

  after do
    servers.each(&:close)
    FileUtils.rm_rf(state_dir)
  end

  def make(**fields)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: state_dir).tap do |made|
      fields.each { |key, value| made.public_send(:"#{key}=", value) }
      made.save(state_dir: state_dir)
    end
  end

  def dir_of(session) = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)

  def live_worker(session, epoch: "e1e1e1e1")
    server = TCPServer.new("127.0.0.1", 0).tap { |opened| servers << opened }
    Samagotchi::WorkerSidecar.new(port: server.local_address.ip_port, session_id: session.id, started_at: "2026-10-23T12:00:00.000Z",
                                  version: "9.9.9", features: %w[delivery unqueue], epoch: epoch).write(dir_of(session))
  end

  it "wakes the session's worker: its worker, that machine's default model, parent strategy and newest chi" do
    session = make
    live_worker(session)
    allow(Samagotchi::ModelProfile).to receive(:default_model_name).and_return("studio-default")

    woke = remote.attach_wake(session.id, wait: 10)

    expect(woke).to have_attributes(woke: false, default_model: "studio-default", installed: nil)
    expect(woke.worker).to include("epoch" => "e1e1e1e1", "features" => %w[delivery unqueue])
    expect(woke.strategy).to be_a(Samagotchi::Guardrails::ParentPolicy::Strategy)
  end

  it "refuses a wake as Local does: a chi REPL's session, a leftover scratch one, a late Bridge, no session" do
    repl = make
    lock = Samagotchi::OwnerLock.acquire(dir_of(repl), kind: "tui")
    expect { remote.attach_wake(repl.id, wait: 1) }
      .to raise_error(Samagotchi::SessionManager::OwnedByTUI, Samagotchi::SessionManager::OwnedByTUI.new(repl.id).message)
    lock.release

    scratch = make(scratch: true)
    expect { remote.attach_wake(scratch.id, wait: 1) }
      .to raise_error(Samagotchi::SessionAccess::Refused, Samagotchi::LaunchMode::SCRATCH_LEFTOVER) { |e| expect(e.code).to eq("scratch") }

    late = make
    allow(Samagotchi::SessionManager).to receive(:resume_session)
    allow(Samagotchi::WorkerLink).to receive(:await).and_return(none_link)
    expect { remote.attach_wake(late.id, wait: 0.1) }
      .to raise_error(Samagotchi::SessionAccess::Refused, format(Samagotchi::LaunchMode::BRIDGE_LATE, late.id))

    expect { remote.attach_wake("feedbeef00", wait: 1) }.to raise_error(ArgumentError)
  end

  it "says a worker there is leaving (its recap on leave), and the wake waits for its lock before resuming" do
    session = make
    lock = Samagotchi::OwnerLock.acquire(dir_of(session), kind: "worker")
    expect(remote.attach_worker(session.id)).to have_attributes(live: false, leaving: false, leave_seconds: nil)
    lock.mark_leaving(wait: 20)
    expect(remote.attach_worker(session.id)).to have_attributes(live: false, leaving: true, leave_seconds: be_within(2).of(20))

    calls = []
    allow(Samagotchi::OwnerLock).to receive(:await_release).and_wrap_original do |original, dir, **options|
      # The worker lets go at the wait's first look.
      calls << original.call(dir, **options, sleeper: ->(_) { lock.release })
    end
    allow(Samagotchi::SessionManager).to receive(:resume_session) { calls << :resume }
    allow(Samagotchi::WorkerLink).to receive(:await) { live_worker(session) && live_link(Samagotchi::WorkerSidecar.read(dir_of(session))) }

    expect(remote.attach_wake(session.id, wait: 1)).to have_attributes(woke: true)
    expect(calls).to eq(%i[released resume])
  ensure
    lock&.release
  end

  it "reads the worker now: live with its epoch and that machine's default model, or stopped" do
    session = make
    live_worker(session, epoch: "e2e2e2e2")
    allow(Samagotchi::ModelProfile).to receive(:default_model_name).and_return("studio-default")
    expect(remote.attach_worker(session.id)).to have_attributes(live: true, stopped: false, default_model: "studio-default")
    expect(remote.attach_worker(session.id).worker).to include("epoch" => "e2e2e2e2")

    stopped = make
    Samagotchi::Session.mark_stopped(stopped.id, state_dir: state_dir)
    expect(remote.attach_worker(stopped.id)).to have_attributes(live: false, stopped: true, worker: nil)
  end

  it "checks a feature of chi web's, in too_old_message's words without it; a refused token is AuthRefused" do
    expect { remote.require_feature!(described_class::ATTACH_FEATURE) }.not_to raise_error
    expect { remote.require_feature!("teleport") }
      .to raise_error(Samagotchi::SessionAccess::RemoteTooOld, described_class.too_old_message(remote.entry, Samagotchi::VERSION))

    refused = RemoteBackend.access(state_dir: state_dir, app: app, token: "wrong")
    expect { refused.require_feature!(described_class::ATTACH_FEATURE) }
      .to raise_error(Samagotchi::SessionAccess::AuthRefused, /the token was refused/)
    expect(Samagotchi::SessionAccess::AuthRefused.ancestors).to include(Samagotchi::SessionAccess::RemoteFailed)
  end
end
