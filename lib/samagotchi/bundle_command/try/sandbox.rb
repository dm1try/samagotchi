# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"
require_relative "../../config"
require_relative "../../cli/exit"
require_relative "../../installed_gem"
require_relative "../../memory_bundle"
require_relative "../../memory_bundle/shas"

module Samagotchi
  class BundleCommand
    module Try
      class Sandbox
        LIB_DIR = File.expand_path("../../..", __dir__)
        CHI = File.expand_path("../../../../bin/chi", __dir__)
        SHIPPED_DIR = MemoryBundle::SourceNormalizer::SHIPPED_DIR
        CONFIG_DENYLIST = %w[
          bundles hooks guardrails memories append_system_prompt recap session log web update kitty tmux broadcast
          context_sources
        ].freeze
        SESSION_MARKER_ENV = %w[
          SAMAGOTCHI_PARENT_SESSION SAMAGOTCHI_SESSION_MODEL SAMAGOTCHI_SESSION_THINKING
          SAMAGOTCHI_SESSION_REASONING_HISTORY
        ].freeze
        WORKER_ENV = %w[SAMAGOTCHI_WORKER_PROCESS SAMAGOTCHI_WORKER_DETACH SAMAGOTCHI_BOOT_FALLBACK].freeze

        class Error < StandardError
          attr_reader :status

          def initialize(message, status: CLI::Exit::FAILED)
            super(message)
            @status = status
          end
        end

        attr_reader :root, :config_home, :state_home, :work_dir, :manifest

        def initialize(path, bundle_settings: {}, cost_cap: 1)
          @path = File.realpath(path)
          @bundle_settings = bundle_settings
          @cost_cap = cost_cap
          read_manifest
          @root = File.realpath(Dir.mktmpdir("chi-bundle-try-"))
          @config_home = File.join(root, "config")
          @state_home = File.join(root, "state")
          @work_dir = File.join(root, "work")
          [config_home, state_home, work_dir].each { |dir| FileUtils.mkdir_p(dir) }
          @work_dir = File.realpath(@work_dir)
          write_config
          @child_env = build_child_env
        end

        def child_env = @child_env.dup

        def install
          install_path(@path)
          %w[guardrails cost-cap].each do |name|
            next if @manifest.name == name

            install_path(File.join(SHIPPED_DIR, name))
          end
          @manifest
        end

        def cleanup
          FileUtils.rm_rf(root) if root && File.exist?(root)
        end

        private

        def write_config
          source = ConfigFile.read_yaml(env: ENV.to_h) || {}
          data = source.to_h { |key, value| [key.to_s, value] }
          # Keep the user's model and runtime settings, but never load their
          # code, memory, or session policy into an isolated bundle try.
          CONFIG_DENYLIST.each { |key| data.delete(key) }
          data["context"] = data["context"].dup if data["context"].is_a?(Hash)
          data["context"]&.delete("sources")
          data["bundles"] = {}
          data["bundles"][@manifest.name] = @bundle_settings unless @bundle_settings.empty?
          data["bundles"]["cost-cap"] = { "cap" => @cost_cap }
          path = File.join(config_home, "samagotchi", "config.yml")
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, YAML.dump(data))
        end

        def read_manifest
          file = File.join(@path, "manifest.yml")
          raise Error.new("chi bundle try: not a bundle: #{@path} (chi bundle new NAME)", status: CLI::Exit::USAGE) unless File.file?(file)

          text = File.read(file)
          stale = MemoryBundle::Shas.stale(@path, text)
          unless stale.empty?
            raise Error, "chi bundle try: stale or placeholder sha256 in manifest.yml; run chi bundle check --fix"
          end

          @manifest = MemoryBundle::Manifest.read(dir: @path)
          if @manifest.meta?
            raise Error.new("chi bundle try: profile bundles cannot be tried directly", status: CLI::Exit::USAGE)
          end

          @manifest
        rescue MemoryBundle::Manifest::ValidationError => e
          raise Error, "chi bundle try: #{e.message}"
        rescue MemoryBundle::Shas::Error => e
          raise Error, "chi bundle try: #{e.message}"
        end

        def install_path(path)
          out, err, status = Open3.capture3(child_env, RbConfig.ruby, "-I", LIB_DIR, CHI,
                                            "bundle", "install", path, "--force", chdir: work_dir)
          return if status.success?

          message = [out, err].reject(&:empty?).join("\n").strip
          raise Error, "chi bundle try: #{message.empty? ? "bundle install failed" : message}"
        end

        def build_child_env
          env = ENV.to_h
          SESSION_MARKER_ENV.each { |key| env.delete(key) }
          WORKER_ENV.each { |key| env.delete(key) }
          env.delete("SAMAGOTCHI_LOG_FILE")
          env.delete("SAMAGOTCHI_LOG_DISABLE")
          env.delete("SAMAGOTCHI_SKIP_SYSTEM_BUNDLE")
          env.delete("SAMAGOTCHI_SESSION_SHARED")
          env.delete("SAMAGOTCHI_ENV") if env["SAMAGOTCHI_ENV"] == "test"
          env.delete("SAMAGOTCHI_INSTALLED_VERSION")
          env.delete_if do |key, _|
            key.start_with?("SAMAGOTCHI_GUARDRAILS_", "SAMAGOTCHI_WORKER_") || key == "SAMAGOTCHI_BOOT_FALLBACK"
          end
          env.merge!(
            "HOME" => Dir.home,
            "SAMAGOTCHI_KEYCHAIN" => "on",
            "XDG_CONFIG_HOME" => config_home,
            "XDG_STATE_HOME" => state_home,
            "SAMAGOTCHI_RECAP_ENABLED" => "false",
            "SAMAGOTCHI_CACHE_WARMUP" => "off"
          )
          env.merge!(InstalledGem.unbundled_env_changes(env)) if InstalledGem.spec
          env
        end
      end
    end
  end
end
