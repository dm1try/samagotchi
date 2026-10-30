# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/engine"
require "samagotchi/bridge"
require "samagotchi/session"
require "samagotchi/worker_link"
require "samagotchi/terminal_ui"
require "samagotchi/terminal_ui/attached_loop"
require "support/test_kernel"
require "support/worker_fixtures"
require_relative "../support/recording_surface"

# The default attached TUI against a real worker Bridge, in this process: a
# real Bridge on a test Engine (its kernel stubbed, no Worker), a BridgeClient
# from the session's sidecar, and an AttachedLoop drawing on a
# RecordingSurface. A turn the Engine runs reaches the loop's rendering
# through the Bridge's SSE, so a field renamed on either side fails here.
# The one test of the mechanism; the variants are the units' (the
# attached_loop_* specs on a BridgeClient double, bridge_spec, the
# bridge_client specs).
RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "on a real Bridge" do
  include WorkerFixtures

  let(:state_dir) { Dir.mktmpdir("attached-loop-bridge") }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: state_dir)
                       .tap { |s| s.save(state_dir: state_dir) }
  end
  let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: state_dir) }
  let(:kernel) { test_kernel }
  let(:engine) do
    Samagotchi::Engine.new(client: test_client, kernel: kernel).tap do |made|
      made.session_state_dir = state_dir
      made.session = session
    end
  end
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:typed) { Queue.new }

  before do
    WebMock.allow_net_connect! if defined?(WebMock)
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    hold_worker(session_dir)
    @bridge = Samagotchi::Bridge.new(engine: engine, state_dir: state_dir, session_id: session.id, heartbeat_interval: 5).start
  end

  after do
    typed << nil
    join!(@thread, "the attached loop") if @thread
    @bridge&.stop
    WebMock.disable_net_connect! if defined?(WebMock)
    FileUtils.rm_rf(state_dir)
  end

  def plain_lines = screen.lines.map { |line| line.gsub(/\e\[[\d;]*m/, "") }

  it "joins with the snapshot, then draws another client's turn: its prompt line and the answer" do
    allow(kernel).to receive(:run).and_return(
      Samagotchi::LLM::ModelResult.new(text: "the answer from the bridge", conversation: [], exhausted: false,
                                       pending_tool_calls: false, tool_activity: [], canceled: false)
    )
    client = Samagotchi::WorkerLink.client(session.id, session_dir: session_dir)
    attached = described_class.new(client: client, screen: screen, client_id: "tui:1@spec", state_dir: state_dir,
                                   installed_version: -> {})
    @thread = Thread.new { attached.run(input: ->(_prompt, _prefill) { typed.pop }) }
    wait_for("the loop's stream to join") { @bridge.open_streams_except(nil).positive? }

    engine.run_turn(session, "hello from the web", origin: { client_id: "web:tab1", enqueued_id: "e1" })

    wait_for("the turn's answer on the screen", seen: -> { plain_lines }) do
      plain_lines.include?("the answer from the bridge")
    end
    expect(plain_lines).to include("web> hello from the web")
    expect(plain_lines.index("web> hello from the web")).to be < plain_lines.index("the answer from the bridge")
    wait_for("the turn to end in the loop") { !attached.running? }

    typed << nil
    expect(join!(@thread, "the attached loop").value).to eq(:detached)
  end
end
