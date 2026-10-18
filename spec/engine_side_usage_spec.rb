# frozen_string_literal: true

require "tmpdir"
require "samagotchi/engine"
require "samagotchi/side_usage"

# Engine#note_side_usage: the one entry point a side request's usage (a
# recap, a plugin's ctx.ask_model) comes in by. It folds it into the
# metrics' side block and announces :side_usage under the event lock, then
# saves analytics.json between turns (a running turn's end saves it).
RSpec.describe "Engine#note_side_usage" do
  let(:state_dir) { Dir.mktmpdir }
  let(:registry) { Samagotchi::HostRegistry.new(hosts_config: { "box" => { name: "box", host: "box.test", port: 8081 } }) }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "box:m", working_directory: Dir.pwd).tap do |s|
      s.save(state_dir: state_dir)
    end
  end
  let(:engine) do
    Samagotchi::Engine.new(host_registry: registry, model_name: "box:m").tap do |e|
      e.session_state_dir = state_dir
      e.session = session
    end
  end
  let(:events) { [] }
  let(:analytics) { Samagotchi::AnalyticsFile.path(Samagotchi::Session.session_dir(session.id, state_dir: state_dir)) }

  def usage(kind = "btw", cost: 0.002) = Samagotchi::SideUsage.new(kind: kind, model: "m", prompt_tokens: 100, completion_tokens: 5, cost: cost)

  before { engine.subscribe(observer: ->(event) { events << event }) }

  it "announces :side_usage with the kind and the side block the metrics now have" do
    engine.note_side_usage(usage("recap", cost: nil))
    engine.note_side_usage(usage("btw"))

    side_events = events.select { |e| e[:type] == :side_usage }
    expect(side_events.map { |e| e[:kind] }).to eq(%w[recap btw])
    expect(side_events.last[:side]).to eq(engine.metrics.snapshot[:side])
    expect(side_events.last[:side]).to include(requests: 2, cost_sum: 0.002)
  end

  it "saves analytics.json at once between turns" do
    engine.note_side_usage(usage)

    expect(JSON.parse(File.read(analytics))["side"]).to include("requests" => 1, "cost_sum" => 0.002)
  end

  it "doesn't save while a turn runs (the turn's end does)" do
    allow(engine).to receive(:turn_running?).and_return(true)
    engine.note_side_usage(usage)

    expect(File.exist?(analytics)).to be(false)
    expect(engine.metrics.snapshot[:side]).to include(requests: 1)
  end

  it "doesn't recreate a deleted session's folder" do
    dir = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)
    engine # built before the delete
    FileUtils.rm_rf(dir)
    FileUtils.rm_f(Samagotchi::Session.session_file(session.id, state_dir: state_dir))
    engine.note_side_usage(usage)

    expect(File.exist?(dir)).to be(false)
    expect(engine.metrics.snapshot[:side]).to include(requests: 1)
  end

  it "checks the metrics session file when the current session has changed" do
    old_dir = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)
    engine
    new_session = Samagotchi::Session.new_session(mode: "assist", model_name: "box:m", working_directory: Dir.pwd)
    new_session.save(state_dir: state_dir)
    engine.session = new_session
    FileUtils.rm_rf(old_dir)
    FileUtils.rm_f(Samagotchi::Session.session_file(session.id, state_dir: state_dir))

    engine.note_side_usage(usage)

    expect(File.exist?(old_dir)).to be(false)
    expect(engine.metrics.snapshot[:side]).to include(requests: 1)
  end

  it "counts without a session, saving nothing" do
    bare = Samagotchi::Engine.new(host_registry: registry, model_name: "box:m")
    bare.session_state_dir = state_dir

    expect { bare.note_side_usage(usage) }.not_to raise_error
    expect(bare.metrics.snapshot[:side]).to include(requests: 1)
  end
end
