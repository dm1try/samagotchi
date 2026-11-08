# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "yaml"

# The precedence ladders of the model settings
# (spec/model_setting_precedence_characterization_spec.rb): per setting one
# config.yml, env and CLI with every layer set to its own value, peeled top
# down. Each step records what every surface answers ([value, label]), so a
# golden pins the order and the labels per layer, per surface.
#
# A ladder is a list of layers, top (first set wins) first. A layer is a
# Hash: name:, and any of config: (a lambda editing the config Hash), env:
# (vars), cli: (Config.reload!'s cli_overrides), session: (the session's own
# value). Step i applies layers[i..]: the first step has every layer, the
# last only the bottom one.
module ModelSettingLadders
  GOLDEN_DIR = File.expand_path("../fixtures/model_setting_precedence", __dir__)

  # The model a ladder looks up: typed as the alias +small+, which names
  # box:qwen-a (lookup names small, box:qwen-a, qwen-a).
  TYPED = "small"

  # Every env var a layer may set, cleared around each ladder.
  def self.env_names
    %w[thinking.level reasoning_history steer.cut_after context.window_tokens model.profile llm_context.strategy
       llm_context.apply llm_context.budget_tokens].map { |key| Samagotchi::Config::BY_KEY.fetch(key).env_key }
  end

  # The config every ladder starts from: one remote chat host and one native
  # host, the alias, no settings.
  def self.base_config
    {
      "default" => { "model" => "box:qwen-a" },
      "model_aliases" => { "small" => "box:qwen-a" },
      "hosts" => {
        "box" => { "url" => "http://127.0.0.1:9/v1", "api" => "openai", "remote" => true },
        "nat" => { "host" => "127.0.0.1", "port" => 9 }
      },
      "models" => {}
    }
  end

  # Writes +config+ as config.yml under +dir+; its mtime moves on with each
  # write (ConfigFile.read_yaml is cached by mtime and size).
  def self.write(dir, config)
    path = File.join(dir, "samagotchi", "config.yml")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, YAML.dump(config))
    @writes = (@writes || 0) + 1
    File.utime(Time.now + @writes, Time.now + @writes, path)
  end

  # A chat adapter that says nothing (no window, no image answer, no list):
  # remote, so nothing asks a server.
  FakeAdapter = Struct.new(:window) do
    def remote? = true
    def context_window(model: nil) = window
    def image_input(model: nil) = nil
    def list_models = []
  end

  # A native client whose /props gives +n_ctx+ (nil: no answer).
  FakeClient = Struct.new(:n_ctx) do
    def context_window(model: nil) = n_ctx
    def server_props(model: nil) = nil
    def cached_server_props(model: nil) = nil
  end

  # A saved session no worker runs, as SessionSetting and
  # LLMContextStrategy.for_session read it.
  SavedSession = Struct.new(:model_name, :model_typed, :thinking, :reasoning_history, :llm_context, :toolkit,
                            keyword_init: true)

  # +value+ in a stable JSON form: symbols as strings, Data and Structs as
  # Hashes.
  def self.plain(value)
    case value
    when Hash then value.to_h { |k, v| [k.to_s, plain(v)] }
    when Array then value.map { |v| plain(v) }
    when Symbol then value.to_s
    when Data, Struct then plain(value.to_h)
    else value
    end
  end
end

# The fixture around a ladder: a temp XDG_CONFIG_HOME and XDG_STATE_HOME,
# every layer's env var unset, the CLI settings cleared after.
RSpec.shared_context "model setting ladders" do
  let(:ladder_tmp) { File.realpath(Dir.mktmpdir("model-ladders")) }
  let(:config_dir) { File.join(ladder_tmp, "config") }

  around do |example|
    cleared = ModelSettingLadders.env_names.to_h { |name| [name, nil] }
    with_config_home(config_dir) do
      with_env(cleared.merge("XDG_STATE_HOME" => File.join(ladder_tmp, "state"), "SAMAGOTCHI_DEFAULT_MODEL" => nil,
                             "SAMAGOTCHI_SESSION_MODEL" => nil, "SAMAGOTCHI_SESSION_THINKING" => nil,
                             "SAMAGOTCHI_SESSION_REASONING_HISTORY" => nil, "SAMAGOTCHI_PARENT_SESSION" => nil)) do
        example.run
      end
    end
  ensure
    Samagotchi::Config.reload!(cli_overrides: {})
    FileUtils.rm_rf(ladder_tmp)
  end

  # A registry on the config as written now, its chat adapters the
  # FakeAdapter (+window+ its listed window) and, with +client+, every
  # target's client that one.
  def ladder_registry(window: nil, client: nil)
    Samagotchi::HostRegistry.new(client_override: client).tap do |registry|
      adapter = ModelSettingLadders::FakeAdapter.new(window)
      allow(registry).to receive(:adapter_for).and_return(adapter)
    end
  end

  def effective(registry, typed = ModelSettingLadders::TYPED)
    Samagotchi::EffectiveModel.of(registry, Samagotchi::ModelChoice.new(name: typed, typed: typed))
  end

  # Peels +layers+ top down; the block gets the session's own value (the
  # first remaining layer's session:, nil without one) and gives the
  # surfaces' answers for the step.
  # @return [Array<Hash>] {"step" => layer name, "surfaces" => ...}
  def peel(layers)
    layers.each_index.map do |i|
      active = layers[i..]
      config = ModelSettingLadders.base_config
      active.reverse_each { |layer| layer[:config]&.call(config) }
      ModelSettingLadders.write(config_dir, config)
      env = active.map { |layer| layer[:env] || {} }.reduce({}, :merge)
      cli = active.map { |layer| layer[:cli] || {} }.reduce({}, :merge)
      own = active.find { |layer| layer.key?(:session) }&.fetch(:session)
      Samagotchi::Config.reload!(cli_overrides: cli)
      surfaces = with_env(env) { yield(own) }
      { "step" => layers[i][:name], "surfaces" => ModelSettingLadders.plain(surfaces) }
    ensure
      Samagotchi::Config.reload!(cli_overrides: {})
    end
  end

  # +value+ as pretty JSON against the golden +name+
  # (spec/fixtures/model_setting_precedence/, UPDATE_GOLDENS=1 writes it).
  def expect_ladder_golden(name, value)
    actual = "#{JSON.pretty_generate(ModelSettingLadders.plain(value))}\n"
    path = File.join(ModelSettingLadders::GOLDEN_DIR, "#{name}.json")
    if ENV["UPDATE_GOLDENS"] == "1"
      FileUtils.mkdir_p(ModelSettingLadders::GOLDEN_DIR)
      File.write(path, actual)
    end
    begin
      expect(actual).to eq(File.read(path))
    rescue RSpec::Expectations::ExpectationNotMetError => e
      raise e.class, "spec/fixtures/model_setting_precedence/#{name}.json differs (a precedence or label change). " \
                     "After an intended change only, regenerate with:\n  UPDATE_GOLDENS=1 bundle exec rspec " \
                     "spec/model_setting_precedence_characterization_spec.rb\n#{e.message}"
    end
  end
end
