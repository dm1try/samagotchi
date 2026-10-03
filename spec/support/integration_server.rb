# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "yaml"

# The live model server :integration examples talk to, from env vars read
# once when this file loads (spec_helper loads it before it clears the
# SAMAGOTCHI_* environment):
#
#   SAMAGOTCHI_INTEGRATION_HOST   server host           (default localhost)
#   SAMAGOTCHI_INTEGRATION_PORT   server port           (default 8080)
#   SAMAGOTCHI_INTEGRATION_MODEL  served model id       (required)
#   SAMAGOTCHI_INTEGRATION_API    "openai" for the chat loop (default: none,
#                                 the native completion loop)
#   SAMAGOTCHI_INTEGRATION_TRANSPORT  llama_cpp, mlx or omlx (default: none,
#                                 chi's default, llama_cpp)
#
# :integration examples run under a fixture config built from these alone
# (IntegrationServer.write_config_home), never the developer's ~/.config/samagotchi:
# no aliases, memories, hooks, guardrails or other hosts of theirs. See
# docs/testing.md.
module IntegrationServer
  ENV_PREFIX = "SAMAGOTCHI_INTEGRATION_"
  DEFAULT_HOST = "localhost"
  DEFAULT_PORT = 8080
  # The hosts: entry the fixture config defines.
  HOST_NAME = "integration"

  Settings = Data.define(:host, :port, :model, :api, :transport) do
    def root_url = "http://#{host}:#{port}"
    def openai_base_url = "#{root_url}/v1"
    def model? = !model.empty?

    # The fixture config.yml: the default model on the one host, as
    # server.* (a bare Client) and as hosts.integration (HostRegistry).
    def config_yaml
      entry = { "host" => host, "port" => port }
      server = { "host" => host, "port" => port }
      server["transport"] = transport unless transport.empty?
      entry["api"] = api unless api.empty?
      entry["transport"] = transport unless transport.empty?
      YAML.dump(
        "default" => { "model" => model },
        "server" => server,
        "hosts" => { HOST_NAME => entry }
      )
    end
  end

  # @param env [Hash] the environment to read SAMAGOTCHI_INTEGRATION_* from
  def self.settings_from(env)
    port = env["#{ENV_PREFIX}PORT"].to_s.strip
    Settings.new(host: env["#{ENV_PREFIX}HOST"].to_s.strip.then { |h| h.empty? ? DEFAULT_HOST : h },
                 port: port.empty? ? DEFAULT_PORT : Integer(port, 10),
                 model: env["#{ENV_PREFIX}MODEL"].to_s.strip,
                 api: env["#{ENV_PREFIX}API"].to_s.strip,
                 transport: env["#{ENV_PREFIX}TRANSPORT"].to_s.strip)
  end

  # Writes the fixture config under a fresh temp dir and returns that dir,
  # for XDG_CONFIG_HOME. The caller removes it.
  def self.write_config_home(settings, parent: Dir.tmpdir)
    home = Dir.mktmpdir("samagotchi-integration-config", parent)
    FileUtils.mkdir_p(File.join(home, "samagotchi"))
    File.write(File.join(home, "samagotchi", "config.yml"), settings.config_yaml)
    home
  end

  SETTINGS = settings_from(ENV)

  def self.settings = SETTINGS
  def self.host = SETTINGS.host
  def self.port = SETTINGS.port
  def self.model = SETTINGS.model
  def self.openai_base_url = SETTINGS.openai_base_url
end
