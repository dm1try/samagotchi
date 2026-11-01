# frozen_string_literal: true

require "tmpdir"
require "yaml"
require "samagotchi/engine"
require "support/test_kernel"

# Bundles' judgments as the Engine wires them: config.yml's settings, its Runs
# on disk, its session and its contention. The API itself is judgments_spec.rb's.
RSpec.describe "Bundles' judgments on the Engine" do
  let(:dir) { Dir.mktmpdir("judgments-engine") }
  let(:answer) { Samagotchi::SystemOne::Answer.new(id: "q", type: :noul, noul: 0.9) }
  let(:engine) do
    client = test_client
    Samagotchi::Engine.new(client: client, kernel: test_kernel(client: client), model_name: "Gemma-4B-it").tap do |e|
      e.instance_variable_set(:@session_state_dir, File.join(dir, "sessions"))
    end
  end
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: dir) }
  let(:ctx) { Samagotchi::Plugin::Context.new(bundle: "probe", label: "plugin.rb (bundle probe)", settings: {}, host: engine.send(:plugin_host)) }

  around do |example|
    with_config_home(dir) { example.run }
  ensure
    FileUtils.rm_rf(dir)
  end

  after { engine.shutdown }

  def config(data)
    FileUtils.mkdir_p(File.join(dir, "samagotchi"))
    File.write(File.join(dir, "samagotchi", "config.yml"), YAML.dump({ "default" => { "model" => "spec-model" } }.merge(data)))
  end

  before do
    config({})
    engine
  end

  def declare
    engine.instance_variable_get(:@judgments).declare(
      Samagotchi::SystemOne::Judgments::Declaration.build(bundle: "probe", name: "x", questions: { "q" => { type: "noul", instructions: "i" } })
    )
    engine.session = session
  end

  def runs
    Dir[File.join(dir, "system_one", "runs", "probe.x", "2*.jsonl")].flat_map { |path| File.readlines(path, chomp: true).map { |line| JSON.parse(line) } }
  end

  def backend_answers
    allow_any_instance_of(Samagotchi::SystemOne::HttpBackend).to receive(:ask).and_return({ "q" => answer })
  end

  it "is off until the user sets a mode, whatever the shared host says" do
    config({ "system_one" => { "host" => "judge" } })
    declare
    expect(Samagotchi::SystemOne::HttpBackend).not_to receive(:new)
    expect(ctx.judge("x", state: "s")).to have_attributes(reason: :off, run_id: nil)
    expect(runs).to be_empty
  end

  it "asks the shared host and model once a mode is set, an unquoted on among them, and saves the run in the state dir" do
    config({ "system_one" => { "host" => "judge", "model" => "shared-model", "timeout_ms" => 1500, "judgments" => { "probe.x" => { "mode" => true } } } })
    declare
    expect(Samagotchi::SystemOne::HttpBackend).to receive(:new).with(hash_including(host: "judge", model: "shared-model", timeout_ms: 1500)).and_call_original
    backend_answers
    result = ctx.judge("x", state: "the state")
    expect(result.p).to eq(0.9)
    expect(result.audit?).to be(false)
    expect(runs.last).to include("id" => result.run_id, "mode" => "on", "host" => "judge", "model" => "shared-model", "state" => "the state",
                                 "session_id" => session.id, "session_model" => engine.effective_model_name)
  end

  it "takes a judgment's own host and model" do
    config({ "system_one" => { "host" => "judge", "model" => "shared-model", "judgments" => { "probe.x" => { "mode" => "audit", "host" => "own", "model" => "own-model" } } } })
    declare
    expect(Samagotchi::SystemOne::HttpBackend).to receive(:new).with(hash_including(host: "own", model: "own-model")).and_call_original
    backend_answers
    expect(ctx.judge("x", state: "s")).to have_attributes(audit?: true)
    expect(runs.last).to include("host" => "own", "model" => "own-model", "mode" => "audit")
  end

  it "on a host of its own with no model of its own, asks that host's first, not the shared host's model" do
    config({ "system_one" => { "host" => "judge", "model" => "shared-model", "judgments" => { "probe.x" => { "mode" => "on", "host" => "own" } } } })
    declare
    expect(Samagotchi::SystemOne::HttpBackend).to receive(:new).with(hash_including(host: "own", model: nil)).and_call_original
    backend_answers
    ctx.judge("x", state: "s")
  end

  it "says no host with no system_one.host, and saves nothing" do
    config({ "system_one" => { "judgments" => { "probe.x" => { "mode" => "on" } } } })
    declare
    expect(ctx.judge("x", state: "s")).to have_attributes(reason: :no_host, run_id: nil)
    expect(runs).to be_empty
  end

  it "says no judgment for a host that doesn't exist, with a failed run" do
    config({ "system_one" => { "host" => "nowhere", "judgments" => { "probe.x" => { "mode" => "on" } } } })
    declare
    expect(ctx.judge("x", state: "s")).to have_attributes(reason: :failed, no_judgment?: true)
    expect(runs.last).to include("failure" => "Samagotchi::SystemOne::UnsupportedHost", "asked" => true)
  end

  it "says no session before one is bound" do
    config({ "system_one" => { "host" => "judge", "judgments" => { "probe.x" => { "mode" => "on" } } } })
    engine.instance_variable_get(:@judgments).declare(
      Samagotchi::SystemOne::Judgments::Declaration.build(bundle: "probe", name: "x", questions: { "q" => { type: "noul", instructions: "i" } })
    )
    expect(ctx.judge("x", state: "s")).to have_attributes(reason: :no_session)
  end

  describe "with System 1 on the model's own local host, during a turn" do
    before do
      config({ "system_one" => { "host" => "judge", "judgments" => { "probe.x" => { "mode" => "on" } } } })
      backend_answers
      allow(engine.instance_variable_get(:@host_registry)).to receive(:host_for_model)
        .and_return([Samagotchi::HostRegistry::HostEntry.new(name: "judge", host: "127.0.0.1", port: 8080, client: test_client), nil])
      allow(engine).to receive(:turn_running?).and_return(true)
      declare
    end

    it "ctx.judge asks" do
      result = ctx.judge("x", state: "s")
      expect(result.p).to eq(0.9)
      expect(runs.last).to include("id" => result.run_id, "asked" => true)
    end

    it "ctx.judge_later asks" do
      got = Queue.new
      id = ctx.judge_later("x", state: "s") { |result| got << result }
      expect(pop!(got, "the block's result")).to have_attributes(run_id: id, reason: nil)
      join!(engine.instance_variable_get(:@side_judgments).thread("probe.x"), "the ask")
      expect(runs.last).to include("id" => id, "asked" => true)
    end
  end

  it "asks a judge_later on the Engine's side judgments, its kind the full name" do
    config({ "system_one" => { "host" => "judge", "judgments" => { "probe.x" => { "mode" => "on" } } } })
    declare
    backend_answers
    got = Queue.new
    id = ctx.judge_later("x", state: "s") { |result| got << result }
    expect(engine.instance_variable_get(:@side_judgments).thread("probe.x")).to be_a(Thread)
    expect(got.pop(timeout: 5)).to have_attributes(run_id: id)
    join!(engine.instance_variable_get(:@side_judgments).thread("probe.x"), "the ask")
    expect(runs.last).to include("id" => id, "asked" => true)
  end

  it "saves nothing for a scratch session, and no later line" do
    config({ "system_one" => { "host" => "judge", "judgments" => { "probe.x" => { "mode" => "on" } } } })
    declare
    session.scratch = true
    backend_answers
    result = ctx.judge("x", state: "s")
    expect(result).to have_attributes(no_judgment?: false, run_id: nil)
    expect(runs).to be_empty
    expect(ctx.judgments.label("probe.x/#{SecureRandom.uuid}", "v")).to be(false)
    expect(Dir.exist?(File.join(dir, "system_one"))).to be(false)
  end

  it "saves nothing in a participant's turn" do
    config({ "system_one" => { "host" => "judge", "judgments" => { "probe.x" => { "mode" => "on" } } } })
    declare
    allow(engine).to receive(:turn_author).and_return("p:p_0123abcd")
    backend_answers
    expect(ctx.judge("x", state: "their text")).to have_attributes(no_judgment?: false, run_id: nil)
    expect(runs).to be_empty
  end

  it "labels on disk, and a session's delete purges the bundle's runs and labels" do
    config({ "system_one" => { "host" => "judge", "judgments" => { "probe.x" => { "mode" => "on" } } } })
    declare
    backend_answers
    id = ctx.judge("x", state: "s").run_id
    expect(ctx.judgments.label(id, "keep_going", strength: "weak")).to be(true)
    expect(runs.last).to include("kind" => "label", "run_id" => id, "value" => "keep_going", "by" => "probe", "strength" => "weak")
    Samagotchi::SystemOne::Runs.purge_session(session.id, sessions_dir: File.join(dir, "sessions"))
    expect(runs).to be_empty
  end

  it "says once, in a notice held for every UI, which system_one.judgments name no bundle declares; not a declared one's, not core's" do
    config({ "system_one" => { "judgments" => { "probe.x" => { "mode" => "on" }, "probe.typo" => { "mode" => "on" }, "approvals.allow" => { "mode" => "on" } } } })
    engine.instance_variable_get(:@judgments).declare(
      Samagotchi::SystemOne::Judgments::Declaration.build(bundle: "probe", name: "x", questions: { "q" => { type: "noul", instructions: "i" } })
    )
    held = engine.instance_variable_get(:@extension_load)
    registries = Samagotchi::Plugin::Registries.new
    allow(Samagotchi::Plugin::Loader).to receive(:load_installed).and_return([])
    held.load_plugins(registries, failures: nil) { engine.send(:warn_undeclared_judgments) }
    notices = held.held_events.select { |event| event.to_s.include?("system_one.judgments") }
    expect(notices.size).to eq(1)
    expect(notices.first.to_s).to include("system_one.judgments.probe.typo", "no loaded bundle declares it")
  end

  # D2: Record and Similar are model-blind (Record#initialize filters by rule
  # only), so a per-judgment model swap would let a new model inherit approvals'
  # clean record and auto-allow. Overrides are for bundles only.
  describe "core's judgments have no host, model or mode of their own" do
    let(:swapped) { { "mode" => "on", "host" => "other-host", "model" => "swapped-model" } }

    before do
      config({ "guardrails" => { "system_one" => { "mode" => "audit" } },
               "system_one" => { "host" => "judge", "model" => "judge-model",
                                 "judgments" => %w[approvals.allow toolkit.suggest context.candidate].to_h { |name| [name, swapped.dup] } } })
    end

    it "approvals' client takes the shared host and model and its own mode key, whatever system_one.judgments says" do
      client = engine.send(:build_guardrail_wiring).instance_variable_get(:@system_one).call
      expect(client).to have_attributes(host: "judge", model: "judge-model", mode: "audit")
    end

    it "a bare from_config (what toolkit's and context's sites call) reads no entry" do
      client = Samagotchi::SystemOne::Client.from_config(host_registry: Samagotchi::HostRegistry.new, mode: "on", tag: :toolkit)
      expect(client).to have_attributes(host: "judge", model: "judge-model")
    end

    it "only the bundles' layer passes a host or a model to from_config" do
      source = File.read(File.expand_path("../../../lib/samagotchi/engine.rb", __dir__))
      calls = source.scan(/SystemOne::Client\.from_config\(.*?\)/m)
      with_own = calls.select { |call| call.match?(/\b(host|model):/) }
      expect(calls.size).to be >= 4
      expect(with_own.size).to eq(1)
      expect(with_own.first).to include("settings.host", "settings.client_model")
    end

    it "no bundle can declare one, or reach one through ctx" do
      declaration = Samagotchi::SystemOne::Judgments::Declaration
      expect { declaration.build(bundle: "approvals", name: "allow", questions: { "q" => { type: "noul", instructions: "i" } }) }
        .to raise_error(ArgumentError, /first word/)
      engine.session = session
      expect { ctx.judge("approvals.allow", state: "s") }.to raise_error(ArgumentError, /no judgment probe.approvals.allow/)
      expect { ctx.judgments.label("approvals.allow/abc", "v") }.to raise_error(ArgumentError, /not a run of bundle probe's/)
    end
  end
end
