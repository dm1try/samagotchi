# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "samagotchi/session_commands"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/turn_flow"
require "samagotchi/terminal_ui"

# /recap on|off|default: the session's own recap.enabled, set live (the
# idle job rebuilt or dropped at once), saved by the command's host on
# changed: [:recap], and read back by a respawn.
RSpec.describe "/recap on|off|default", :recap do
  let(:registry) { Samagotchi::HostRegistry.new(hosts_config: { "box" => { name: "box", host: "box.test", port: 8081 } }) }
  let(:engine) { Samagotchi::Engine.new(host_registry: registry, model_name: "box:m") }
  let(:turn_flow) { Samagotchi::TurnFlow.new(engine: engine) }
  let(:saves) { [] }
  let(:commands) do
    Samagotchi::SessionCommands.new(engine: engine, turn_flow: turn_flow, default_model: "box:m",
                                    save: ->(session) { saves << session.id }, registry: engine.command_registry)
  end
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "box:m", working_directory: Dir.pwd) }

  before do
    allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil)
    engine.session = session
  end

  def scheduler_jobs = engine.instance_variable_get(:@idle_scheduler).jobs

  def with_config(yaml, &)
    Dir.mktmpdir("samagotchi-config") do |dir|
      FileUtils.mkdir_p(File.join(dir, "samagotchi"))
      File.write(File.join(dir, "samagotchi", "config.yml"), "default:\n  model: spec-model\n#{yaml}")
      with_env("XDG_CONFIG_HOME" => dir, &)
    end
  end

  it "turns this session's recap off and on at once, and default goes back to config.yml's" do
    old = engine.recap
    expect(old).not_to be_nil

    result = commands.run("/recap off")
    expect(result).to have_attributes(status: :ok, output: "recap: off (this session; config.yml: on)", changed: [:recap])
    expect(session.settings.core).to eq("recap.enabled" => false)
    expect(engine.recap).to be_nil
    expect(scheduler_jobs).not_to include(old)

    expect(commands.run("/recap on")).to have_attributes(output: "recap: on (this session; config.yml: on)", changed: [:recap])
    expect(session.settings.core).to eq("recap.enabled" => true)
    expect(scheduler_jobs).to include(engine.recap)

    expect(commands.run("/recap default")).to have_attributes(output: "recap: on (config.yml)", changed: [:recap])
    expect(session.settings.core).to eq({})
    expect(engine.recap).not_to be_nil
    expect(scheduler_jobs.count { |job| job.is_a?(Samagotchi::IdleRecap) }).to eq(1)
  end

  it "doesn't save itself (the worker saves a changed command), and a repeat changes nothing" do
    commands.run("/recap off")
    expect(saves).to be_empty
    expect(commands.run("/recap OFF")).to have_attributes(status: :ok, changed: [])
  end

  it "answers a slip with its usage, and never takes the bare /recap (a UI's own)" do
    expect(commands.run("/recap please")).to have_attributes(status: :error, output: "usage: /recap [on|off|default]", changed: [])
    expect(commands.run("/recap")).to be_nil
    expect(engine.command_registry.lookup_local("/recap")&.id).to eq(:recap)
    expect(engine.command_registry.lookup_local("/recap off")).to be_nil
    expect(Samagotchi::SessionCommands.ui_only_entry("/recap off")).to be_nil
  end

  it "runs mid-turn too (it toggles the idle job only)" do
    expect(engine.command_registry.mid_turn("/recap off")).to eq(:anytime)
    expect(engine.command_registry.mid_turn("/recap")).to eq(:refuse)
  end

  it "turns it on for this session under config.yml's recap: false, and names that" do
    with_config("recap: false\n") do
      expect(commands.run("/recap default").output).to eq("recap: off (config.yml)")
      expect(commands.run("/recap on").output).to eq("recap: on (this session; config.yml: off)")
      expect(engine.recap).not_to be_nil
    end
    with_env("SAMAGOTCHI_RECAP_ENABLED" => "false") do
      expect(commands.run("/recap off").output).to eq("recap: off (this session; env: off)")
    end
  end

  it "says no recap is written when its pinned host doesn't resolve" do
    with_config("recap:\n  host_ref: nowhere\n") do
      commands.run("/recap off")
      expect(commands.run("/recap on").output).to eq("recap: on (this session; config.yml: on); " \
                                                     "no recap is written: its host or model doesn't resolve (see the log)")
    end
  end

  it "is saved and read back by a respawn, still off" do
    Dir.mktmpdir do |state|
      with_env("XDG_STATE_HOME" => state) do
        commands.run("/recap off")
        session.save
        respawned = Samagotchi::Engine.new(host_registry: registry, model_name: "box:m")
        respawned.session = Samagotchi::Session.load(session.id)
        expect(respawned.recap).to be_nil
        expect(respawned.recap_override).to be(false)
      end
    end
  end

  it "lists /recap once in /help, as a command the session runs" do
    lines = commands.run("/help").output.lines.map(&:rstrip)
    recap = lines.select { |line| line.split.first == "/recap" }
    expect(recap).to eq(["  /recap              show the session's recap (in a terminal); on|off|default sets this session's own  (mid-turn too)"])
    expect(engine.command_registry.completions(:repl).count("/recap")).to eq(1)
  end

  it "saves the REPL's session when it changed, and the bare /recap then says it is off for this session" do
    ui = Samagotchi::TerminalUI.new(client: instance_double(Samagotchi::Client), surface: Class.new { def commit(*) = nil }.new)
    ui.engine.session = session
    allow(session).to receive(:save)
    ui.send(:run_input_line, session, "/recap off")
    expect(session).to have_received(:save).once
    expect(ui.engine.recap).to be_nil
    expect(ui.send(:handle_recap_command)).to eq(Samagotchi::TerminalUI::Formatting::RECAP_SESSION_OFF_TEXT)
  end
end
