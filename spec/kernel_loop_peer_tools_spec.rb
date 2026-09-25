# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/engine"
require "samagotchi/kernel_loop"

RSpec.describe "list_sessions and send_note in the loops" do
  let(:tmpdir) { Dir.mktmpdir("kernel-peers") }
  let(:me) { Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/work/me").tap { |s| s.save(state_dir: tmpdir) } }
  let(:other) { Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/work/other").tap { |s| s.save(state_dir: tmpdir) } }

  after { FileUtils.rm_rf(tmpdir) }

  it "KernelLoop dispatches send_note with its peers, and labels the activity" do
    kernel = Samagotchi::KernelLoop.new(client: instance_double(Samagotchi::Client), profile: :gemma4)
    kernel.peers = Samagotchi::Tools::Peers.new(session_id: me.id, cwd: "/work/me", state_dir: tmpdir)

    result = kernel.dispatch_tool_call(name: "send_note", content: "api moved", session: other.id[0, 8])

    expect(result[:output]).to start_with("[send_note]\nQueued a note for session #{other.id[0, 8]}")
    expect(result[:activity]).to include(action: "sending a note", tool: "send_note", status: "ok")
    expect(result[:activity][:params]).to eq("session=#{other.id[0, 8].inspect} text=\"api moved\"")
    listed = kernel.dispatch_tool_call(name: "list_sessions", content: "")
    expect(listed[:output]).to include(other.id[0, 8])
    expect(listed[:activity]).to include(action: "listing sessions")
  end

  it "Engine tells its kernel which session it runs and where sessions live" do
    engine = Samagotchi::Engine.new(mode: :assist, client: instance_double(Samagotchi::Client), profile: "gemma4")
    engine.guardrail_state_dir = tmpdir
    engine.session = me

    peers = engine.instance_variable_get(:@kernel).peers

    expect([peers.session_id, peers.cwd, peers.state_dir]).to eq([me.id, "/work/me", tmpdir])
  end

  it "the Engine's peers see the running turn's cancel, so a waiting tool can return" do
    engine = Samagotchi::Engine.new(mode: :assist, client: instance_double(Samagotchi::Client), profile: "gemma4")
    peers = engine.instance_variable_get(:@kernel).peers
    expect(peers.cancelled?).to be(false)

    ctrl = Samagotchi::CancellationController.new
    engine.instance_variable_set(:@active_cancel_controller, ctrl)
    expect(peers.cancelled?).to be(false)
    ctrl.cancel!
    expect(peers.cancelled?).to be(true)

    plain = Samagotchi::Tools::Peers.new(session_id: me.id, cwd: "/work/me", state_dir: tmpdir)
    expect(plain.cancelled?).to be(false)
    flag = false
    lazy = Samagotchi::Tools::Peers.new(session_id: me.id, cwd: "/work/me", state_dir: tmpdir, cancelled: -> { flag })
    expect(lazy.cancelled?).to be(false)
    flag = true
    expect(lazy.cancelled?).to be(true)
  end
end
