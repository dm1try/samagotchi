# frozen_string_literal: true

require "json"
require "rack/mock"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/worker"
require "samagotchi/queued_command"
require "samagotchi/web/app"
require_relative "../support/fake_provider_server"
require_relative "../support/effective_model_configs"

# The per-session settings' chips as the web shows them, pinned on the code
# as it was before SessionSetting (characterization; the goldens are in
# spec/fixtures/effective_model/): a saved session's (no worker: Web::App
# resolves them from the session file), a worker's snapshot's (present,
# nil-valued, absent: llm_context and thinking fall back with ||,
# reasoning_history and toolkit with key?), the start page's per-model
# chips, and the worker's :command_ran fields per changed setting.
#
# Regenerate only after an intended behaviour change:
#   UPDATE_GOLDENS=1 bundle exec rspec spec/web/app_session_settings_characterization_spec.rb
RSpec.describe "Session settings chips (characterization)" do
  include_context "effective model configs"

  let(:state_dir) { File.join(tmp, "state", "samagotchi", "sessions").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:app) { Samagotchi::Web::App.new(state_dir: state_dir, bridge_wait_timeout: 0, registry: registry, models_wait_timeout: 5) }

  def chip_keys = %w[llm_context thinking reasoning_history toolkit]

  def env_for(path) = Rack::MockRequest.env_for(path, "HTTP_HOST" => "127.0.0.1", method: "GET")

  def chips(session)
    payload = JSON.parse(app.call(env_for("/api/sessions/#{session.id}"))[2].first)
    payload.fetch("session").slice(*chip_keys)
  end

  # A saved session on +model+ (its ref, and the name typed when that
  # differs), with the session's own levels when +own+.
  def saved_session(model, own:)
    engine = Samagotchi::Engine.new(host_registry: registry, model_name: model, plugins: false)
    session = Samagotchi::Session.new_session(mode: "assist", model_name: model, working_directory: project)
    engine.store_model!(session)
    if own
      session.thinking = :medium
      session.reasoning_history = :drop
      session.llm_context = Samagotchi::LLMContextOverride.new(strategy: [:stale])
      session.toolkit = Samagotchi::Toolkit.new(name: "lean", add: ["delegate"])
    end
    session.save(state_dir: state_dir)
    sessions << session
    session
  end

  def live(session_state)
    { "snapshot" => { "messages" => [], "event_seq" => 3 },
      "session_state_snapshot" => { "status" => "idle", "event_seq" => 3 }.merge(session_state) }
  end

  it "pins each config's saved-session chips, and a worker's snapshot chips present, nil-valued and absent" do
    values = EffectiveModelConfigs::ROWS.to_h do |row, model|
      plain = saved_session(model, own: false)
      own = saved_session(model, own: true)
      [row, { saved: chips(plain), saved_own: chips(own) }]
    end
    session = sessions.first
    present = { "llm_context" => { "strategy" => "none" }, "thinking" => { "level" => "high" },
                "reasoning_history" => { "level" => "all" }, "toolkit" => { "name" => "lean" } }
    snapshots = { present: present, nil_valued: chip_keys.to_h { |key| [key, nil] }, absent: {} }
    values[:snapshot] = snapshots.transform_values do |state|
      allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(live(state))
      chips(session)
    end

    expect_golden("web_session_chips.json", values)
  end

  it "pins the start page's per-model sampling, thinking and LLM context chips" do
    payload = JSON.parse(app.call(env_for("/api/models"))[2].first)
    models = payload.fetch("models").map { |model| model.slice("name", "sampling", "thinking", "llm_context") }

    expect_golden("web_models.json", models.sort_by { |model| model["name"] })
  end

  describe "the worker's :command_ran" do
    let(:events) { [] }

    def command_ran(engine, changed)
      worker = Samagotchi::Worker.allocate
      worker.instance_variable_set(:@engine, engine)
      allow(engine).to receive(:announce) { |event| events << event }
      command = Samagotchi::QueuedCommand.new(command_id: "c1", line: "/x")
      worker.send(:announce_command, command, status: "ok", output: "done", changed: changed)
      events.last.except(:type, :command_id, :client_id, :line, :status, :output)
    end

    it "carries each changed setting's chip, per config" do
      values = EffectiveModelConfigs::ROWS.to_h do |row, model|
        engine = Samagotchi::Engine.new(host_registry: registry, model_name: model, plugins: false)
        engine.session = Samagotchi::Session.new_session(mode: "assist", model_name: model, working_directory: project)
        sessions << engine.session
        changes = [[:model], [:thinking], [:reasoning_history], [:llm_context], [:toolkit], %i[thinking toolkit], []]
        [row, changes.to_h { |changed| [changed.join("+"), command_ran(engine, changed)] }]
      end

      expect_golden("worker_command_ran.json", values)
    end
  end
end
