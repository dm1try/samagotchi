# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "socket"
require "yaml"
require "samagotchi/memory_bundle/system_bundle"
require "samagotchi/tools/memory"

# The host configs the effective model's settings are pinned on
# (spec/engine_effective_model_characterization_spec.rb, and the
# EffectiveModel specs after it): one config.yml holding every host, and per
# row the model a session starts on.
#
#   llama:     a native llama.cpp host (no api:), its model's models: entry
#              setting sampling, thinking, window_tokens, steer_cut_after and
#              llm_context_strategy; /props names another model_alias
#   openai:    an api: openai remote host, its declared model priced and
#              served by another id, reasoning_history on the host
#   anthropic: an api: anthropic remote host with a dialect, thinking on the host
#   down:      a native host nothing listens on, its model declared
#   alias:     model_aliases splash: main:gemma-x, started as splash
module EffectiveModelConfigs
  ROWS = {
    "llama" => "box:qwen-small",
    "openai" => "oai:gpt-x",
    "anthropic" => "ant:claude-x",
    "down" => "down:declared-m",
    "alias" => "splash"
  }.freeze

  # A port nothing listens on (taken, then let go).
  def self.closed_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  # @param server [FakeProviderServer] answers /props, /completion and the chat APIs
  # @param down_port [Integer] see .closed_port
  # @return [Hash] config.yml's content
  def self.config(server, down_port)
    {
      "default" => { "model" => "box:qwen-small" },
      "model_aliases" => { "splash" => "main:gemma-x" },
      "hosts" => {
        "box" => { "host" => "127.0.0.1", "port" => server.port, "thinking" => "high" },
        "main" => { "host" => "127.0.0.1", "port" => server.port },
        "oai" => { "url" => server.base_url, "api" => "openai", "remote" => true, "api_key_env" => "EM_OAI_KEY",
                   "reasoning_history" => "all",
                   "models" => { "gpt-x" => { "price" => { "input" => 1.5, "output" => 6 }, "served" => ["gpt-x-0613"] },
                                 "shared-m" => { "price" => { "input" => 0.5, "output" => 1 }, "served" => ["shared-m-q8"] } } },
        "ant" => { "url" => server.root_url, "api" => "anthropic", "dialect" => "fireworks", "remote" => true,
                   "api_key_env" => "EM_ANT_KEY", "thinking" => "medium", "window_tokens" => 100_000 },
        "down" => { "host" => "127.0.0.1", "port" => down_port, "models" => ["declared-m"] }
      },
      "models" => {
        "qwen-small" => { "sampling" => { "temperature" => 0.6, "top_k" => 20 }, "thinking" => "low",
                          "window_tokens" => 48_000, "steer_cut_after" => 45, "llm_context_strategy" => "stale" },
        "gpt-x" => { "sampling" => { "temperature" => 0.3 }, "thinking" => "off" },
        "claude-x" => { "steer_cut_after" => 0 },
        "splash" => { "thinking" => "off", "llm_context_strategy" => %w[stale forget] },
        "gemma-x" => { "sampling" => { "temperature" => 1.0 }, "window_tokens" => 32_000, "thinking" => "high" },
        "fast" => { "thinking" => "medium" }
      }
    }
  end

  # Writes config.yml (+edit+ may change the hash first). Its mtime moves
  # on with each write: ConfigFile.read_yaml is cached by mtime and size.
  def self.write(dir, server, down_port, &edit)
    path = File.join(dir, "samagotchi", "config.yml")
    FileUtils.mkdir_p(File.dirname(path))
    config = config(server, down_port)
    edit&.call(config)
    File.write(path, YAML.dump(config))
    @writes = (@writes || 0) + 1
    File.utime(Time.now + @writes, Time.now + @writes, path)
  end

  # llama.cpp's /props for the native hosts: a Qwen chat template (the
  # profile), a window, and a model_alias that isn't the model asked for.
  PROPS = { "chat_template" => "<|im_start|> <function=", "model_alias" => "qwen-served-q4",
            "default_generation_settings" => { "n_ctx" => 40_960 } }.freeze

  # Both chat hosts' /v1/models (the fake server has one): the openai
  # host's window from context_length; the anthropic one lists no window.
  MODELS = { "object" => "list", "has_more" => false,
             "data" => [{ "id" => "gpt-x", "object" => "model", "context_length" => 131_072 },
                        { "id" => "claude-x", "type" => "model", "display_name" => "Claude X" }] }.freeze

  # What the fake server answers when nothing is queued.
  def self.serve_defaults(server)
    server.default("/props", json: PROPS)
    server.default("/v1/models", json: MODELS)
  end

  # The text a run puts where a value differs between runs (the fake
  # server's and the dead host's ports, temp folders, the home folder,
  # session ids), so a golden compares what the code decided.
  def self.normalize(text, server:, down_port:, paths: [], ids: [])
    out = text.to_s.dup
    ids.compact.each { |id| out = out.gsub(id, "SESSION_ID").gsub("sid=#{id[0, 8]}", "sid=SID") }
    paths.compact.sort_by { |path| -path.length }.each { |path| out = out.gsub(path, "TMP") }
    out = out.gsub(Dir.home, "HOME") unless Dir.home.to_s.empty?
    out = out.gsub(%r{memories/projects/[^/\s"]+}, "memories/projects/KEY")
    out.gsub("127.0.0.1:#{server.port}", "127.0.0.1:PORT").gsub("127.0.0.1:#{down_port}", "127.0.0.1:DOWN_PORT")
  end

  def self.sha(text) = "sha256:#{Digest::SHA256.hexdigest(text)}"
end

# The fixture around a spec of these configs: config.yml in a temp
# XDG_CONFIG_HOME, a temp XDG_STATE_HOME, the cwd a plain temp folder (no
# AGENTS.md), the fake server answering /props and /v1/models, the
# goldens (spec/fixtures/effective_model, UPDATE_GOLDENS=1 writes them).
RSpec.shared_context "effective model configs" do
  let(:tmp) { File.realpath(Dir.mktmpdir("effective-model")) }
  let(:project) { File.join(tmp, "project").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:server) { FakeProviderServer.start }
  let(:down_port) { EffectiveModelConfigs.closed_port }
  let(:registry) { Samagotchi::HostRegistry.new }
  let(:sessions) { [] }

  around do |example|
    FakeProviderServer.without_webmock do
      with_config_home(File.join(tmp, "config")) do
        with_env("XDG_STATE_HOME" => File.join(tmp, "state"), "EM_OAI_KEY" => "oai-key", "EM_ANT_KEY" => "ant-key",
                 "SAMAGOTCHI_THINKING_LEVEL" => nil, "SAMAGOTCHI_DEFAULT_MODEL" => nil) do
          Dir.chdir(project) { example.run }
        end
      end
    end
  ensure
    server.stop
    FileUtils.rm_rf(tmp)
  end

  before do
    EffectiveModelConfigs.write(File.join(tmp, "config"), server, down_port)
    EffectiveModelConfigs.serve_defaults(server)
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(Samagotchi::MemoryBundle::SystemBundle).to receive(:ensure!)
  end

  def rewrite_config(&) = EffectiveModelConfigs.write(File.join(tmp, "config"), server, down_port, &)

  def normalize(text) = EffectiveModelConfigs.normalize(text, server: server, down_port: down_port, paths: [tmp],
                                                               ids: sessions.map(&:id))

  # +value+ as pretty JSON, the volatile parts normalized, against the golden
  # +name+ (written with UPDATE_GOLDENS=1).
  def expect_golden(name, value)
    actual = "#{normalize(JSON.pretty_generate(value))}\n"
    dir = File.expand_path("../fixtures/effective_model", __dir__)
    path = File.join(dir, name)
    if ENV["UPDATE_GOLDENS"] == "1"
      FileUtils.mkdir_p(dir)
      File.write(path, actual)
    end
    begin
      expect(actual).to eq(File.read(path))
    rescue RSpec::Expectations::ExpectationNotMetError => e
      # The diff stays; the hint goes first (a diff is a behaviour change).
      raise e.class, "spec/fixtures/effective_model/#{name} differs. After an intended change only, regenerate with:\n  " \
                     "UPDATE_GOLDENS=1 bundle exec rspec spec/engine_effective_model_characterization_spec.rb " \
                     "spec/web/app_session_settings_characterization_spec.rb\n#{e.message}"
    end
  end
end
