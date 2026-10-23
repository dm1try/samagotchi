# frozen_string_literal: true

require "timeout"
require "tmpdir"
require "spec_helper"
require "samagotchi/engine"
require "samagotchi/bridge"
require "samagotchi/owner_lock"
require "samagotchi/session"
require "samagotchi/session_manager"
require "samagotchi/web/app"
require "samagotchi/session_access/remote"
require "samagotchi/session_access/web_bridge_client"
require "support/test_kernel"
require_relative "support/web_server"

# A remote attach's event stream end to end, in this process: a real
# worker Bridge (on a test Engine, no turn loop), chi web's App on WEBrick
# at 127.0.0.1:0, and a WebBridgeClient following through it. The one test
# of the shared mechanism; the variants are the units' (EventStream's
# options, WebBridgeClient's mapper, chi web's routes).
#
# It runs over loopback, so chi web's LAN token gate is skipped here (a
# 127.0.0.1 peer needs no token); the gate on the stream route is
# spec/web/lan_auth_spec.rb's.
RSpec.describe "a remote attach's stream through chi web" do
  let(:tmpdir) { Dir.mktmpdir("remote-attach-stream") }
  let(:events) { Queue.new }
  let(:bridges) { [] }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: tmpdir).tap do |made|
      made.save(state_dir: tmpdir)
    end
  end
  let(:app) { Samagotchi::Web::App.new(manager: Samagotchi::SessionManager, state_dir: tmpdir, bridge_wait_timeout: 2) }
  let(:remote) do
    Samagotchi::SessionAccess::Remote.new(Samagotchi::Remotes::Entry.new(name: "studio", url: @web.url, token: nil))
  end

  around do |example|
    # chi web's one-shots go over Net::HTTP for real.
    WebMock.allow_net_connect! if defined?(WebMock)
    example.run
  ensure
    WebMock.disable_net_connect! if defined?(WebMock)
  end

  before do
    # A worker owns the session: chi web's /turn resumes nothing.
    @lock = Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), kind: "worker")
    @web = WebServer.start(app)
  end

  after do
    @stream&.close
    bridges.each(&:stop)
    @web&.stop
    @lock&.release
    FileUtils.rm_rf(tmpdir)
  end

  # A worker's Bridge for the session (a new one is a restart: a new epoch).
  def start_worker
    engine = Samagotchi::Engine.new(client: test_client, kernel: test_kernel)
    Samagotchi::Bridge.new(engine: engine, state_dir: tmpdir, session_id: session.id, heartbeat_interval: 5,
                           input_format: Samagotchi::SessionInbox::INPUT_FORMAT).tap do |bridge|
      bridge.start
      bridges << bridge
    end
  end

  # What GET …/worker says, as rediscovery: the live worker's epoch, or
  # gone with the reason once the session was stopped.
  def rediscover_for(client)
    lambda do
      json = remote.route_request(:get, "/api/sessions/#{session.id}/worker").json
      next [:gone, "stopped"] if json["stopped"]
      next [nil, nil] unless json["live"]

      client.worker_key = json.dig("worker", "epoch")
      client
    end
  end

  def next_event(type)
    Timeout.timeout(10) do
      loop do
        event = events.pop
        return event if event["type"] == type
      end
    end
  end

  def follow(client)
    @stream = client.follow(client_id: "tui:1@spec", rediscover: rediscover_for(client),
                            reconnect_delays: Array.new(20, 0.1)) { |event| events << event }
  end

  it "joins with a snapshot, carries a posted turn's events, follows a restarted worker, and closes once stopped" do
    first = start_worker
    woken = remote.route_request(:post, "/api/sessions/#{session.id}/wake", body: {}).json
    expect(woken).to include("woke" => false, "worker" => include("epoch" => first.epoch))

    client = remote.attach_client(session.id, worker: woken["worker"])
    follow(client)
    expect(next_event("snapshot")).to be_a(Hash)

    ack = client.post_turn(prompt: "hello", client_id: "tui:1@spec", no_interrupt: true)
    expect(ack.status).to eq(202)
    enqueued = next_event("turn_enqueued")
    expect(enqueued.dig("origin", "enqueued_id") || enqueued["enqueued_id"]).to eq(ack.json["enqueued_id"])

    # A restart: the old Bridge goes, a new one (another epoch) comes.
    first.stop
    second = start_worker
    expect(second.epoch).not_to eq(first.epoch)

    moved = next_event("worker_changed")
    expect(moved).to include("port" => nil, "epoch" => second.epoch)
    expect(next_event("reset")).to be_a(Hash)
    expect(client.worker_key).to eq(second.epoch)
    expect(@stream.instance_variable_get(:@client)).to be(client)

    # Stopped there: no worker is coming.
    Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
    second.stop
    expect(next_event("stream_closed")).to eq({ "type" => "stream_closed", "reason" => "stopped" })
  end
end
