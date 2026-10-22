# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "samagotchi/engine"
require "samagotchi/terminal_ui/formatting"

# A session's own recap values (chi --set recap.enabled=false,
# config_settings): RecapSetup reads them first, and Engine#session= swaps
# the idle recap job when the bound session has its own.
RSpec.describe "a session's own recap settings", :recap do
  let(:registry) { Samagotchi::HostRegistry.new(hosts_config: { "box" => { name: "box", host: "box.test", port: 8081 } }) }

  def session_with(core)
    Samagotchi::Session.new_session(
      mode: "assist", model_name: "box:m", working_directory: Dir.pwd,
      setup: Samagotchi::SessionSetup.new(settings: Samagotchi::SessionConfig::Settings.new(core: core))
    )
  end

  def engine = Samagotchi::Engine.new(host_registry: registry, model_name: "box:m")

  def scheduler_jobs(engine) = engine.instance_variable_get(:@idle_scheduler).jobs

  it "turns the recap off when the bound session says recap.enabled=false, and the scheduler drops the job" do
    built = engine
    old = built.recap
    expect(old).not_to be_nil
    expect(scheduler_jobs(built)).to include(old)

    built.session = session_with("recap.enabled" => false)

    expect(built.recap).to be_nil
    expect(scheduler_jobs(built)).not_to include(old)
    expect(built.session_state_snapshot).to include(recap_enabled: false)
  end

  it "binds the same session twice without a second rebuild (the REPL does)" do
    built = engine
    session = session_with("recap.sentences" => "3")
    built.session = session
    rebuilt = built.recap
    expect(rebuilt.sentences).to eq([3, 3])

    built.session = session
    expect(built.recap).to equal(rebuilt)
    expect(scheduler_jobs(built).count { |job| job.is_a?(Samagotchi::IdleRecap) }).to eq(1)
  end

  it "keeps the job of a session with no recap values of its own" do
    built = engine
    old = built.recap
    built.session = session_with({})
    expect(built.recap).to equal(old)
  end

  it "keeps the continue-offer seam on a rebuilt job" do
    built = engine
    seam = -> { true }
    built.recap_awaiting_continue = seam
    built.session = session_with("recap.sentences" => "1")
    expect(built.recap.instance_variable_get(:@awaiting_continue)).to equal(seam)
  end

  it "beats SAMAGOTCHI_RECAP_ENABLED=false and config.yml's scalar recap: false with recap.enabled=true" do
    Dir.mktmpdir("samagotchi-config") do |dir|
      FileUtils.mkdir_p(File.join(dir, "samagotchi"))
      File.write(File.join(dir, "samagotchi", "config.yml"), "default:\n  model: spec-model\nrecap: false\n")
      with_env("XDG_CONFIG_HOME" => dir) do
        built = engine
        expect(built.recap).to be_nil
        built.session = session_with("recap.enabled" => true)
        expect(built.recap).not_to be_nil
        expect(scheduler_jobs(built)).to include(built.recap)
      end
    end
    with_env("SAMAGOTCHI_RECAP_ENABLED" => "false") do
      built = engine
      expect(built.recap).to be_nil
      built.session = session_with("recap.enabled" => true)
      expect(built.recap).not_to be_nil
    end
  end

  it "reads a resumed session's values at start (no rebuild needed)" do
    Dir.mktmpdir do |state|
      with_env("XDG_STATE_HOME" => state) do
        session = session_with("recap.enabled" => false)
        session.save
        built = Samagotchi::Engine.new(host_registry: registry, model_name: "box:m", session_id: session.id)
        expect(built.recap).to be_nil
        built.session = Samagotchi::Session.load(session.id)
        expect(built.recap).to be_nil
      end
    end
  end

  it "names the session's own settings in the /stats snapshot, and nothing for none" do
    allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil)
    built = engine
    expect(built.stats_snapshot).not_to have_key(:settings)
    built.session = session_with("recap.enabled" => false)
    snapshot = built.stats_snapshot
    expect(snapshot[:settings]).to eq("recap.enabled" => false)
    expect(Samagotchi::TerminalUI::Formatting.format_session_metrics(snapshot)).to include("settings:         recap.enabled=false")
  end

  it "still lets an explicit recap: false kwarg (an embedder's) win" do
    built = Samagotchi::Engine.new(host_registry: registry, model_name: "box:m", recap: false)
    built.session = session_with("recap.enabled" => true)
    expect(built.recap).to be_nil
  end
end
