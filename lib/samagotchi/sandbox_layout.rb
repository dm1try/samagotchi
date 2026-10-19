# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "yaml"
require_relative "paths"

module Samagotchi
  # The temp folders a sandboxed chi runs in, shared by `chi bundle try`'s
  # child (BundleCommand::Try::Sandbox) and the test kit
  # (Testing::Sandbox): one realpath'd root holding config/, state/,
  # work/ and whatever else the sandbox wants, the XDG pair pointing at
  # them, and the switches every sandbox turns off. Where the environment
  # goes is each sandbox's own: try builds its child's Hash, the kit
  # changes ENV.
  class SandboxLayout
    DIRS = %w[config state work].freeze
    # No recap request and no cache warm-up request in a sandbox.
    QUIET_ENV = { "SAMAGOTCHI_RECAP_ENABLED" => "false", "SAMAGOTCHI_CACHE_WARMUP" => "off" }.freeze

    # A new temp root (Dir.mktmpdir +prefix+, its realpath) with DIRS and
    # +extra+ folders in it.
    # @return [SandboxLayout]
    def self.create(prefix, extra: [])
      root = File.realpath(Dir.mktmpdir(prefix))
      (DIRS + extra).each { |dir| FileUtils.mkdir_p(File.join(root, dir)) }
      new(root)
    rescue StandardError
      FileUtils.rm_rf(root) if root
      raise
    end

    # @return [String]
    attr_reader :root

    def initialize(root)
      @root = root
    end

    def dir(name) = File.join(root, name)

    def config_home = dir("config")

    def state_home = dir("state")

    def work_dir = dir("work")

    # XDG_CONFIG_HOME and XDG_STATE_HOME at the sandbox's, and QUIET_ENV.
    # @return [Hash{String=>String}]
    def env = { "XDG_CONFIG_HOME" => config_home, "XDG_STATE_HOME" => state_home }.merge(QUIET_ENV)

    # config.yml under +config_home+ (default the sandbox's): a Hash (as
    # YAML) or YAML text.
    # @return [String] its path
    def write_config(data, config_home: self.config_home)
      path = File.join(config_home, Paths::APP_DIR, "config.yml")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, data.is_a?(String) ? data : YAML.dump(data))
      path
    end

    def remove
      FileUtils.rm_rf(root)
    end
  end
end
