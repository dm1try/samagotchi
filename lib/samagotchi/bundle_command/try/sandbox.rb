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
require_relative "../../owner_lock"
require_relative "../../process_group"
require_relative "../../session"
require_relative "../../session_manager"
require_relative "../../tools/task_record"
require_relative "../../tools/task_runtime"

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
        CONFIG_DENYLIST_ENV_PREFIXES = CONFIG_DENYLIST.map do |section|
          prefix = if section == "guardrails"
                     SessionManager::GUARDRAILS_ENV_PREFIX.delete_suffix("_")
                   else
                     "SAMAGOTCHI_#{section.upcase}"
                   end
          prefix
        end.freeze
        # How long a leftover worker or task gets after TERM (a worker saves
        # its session) before ProcessGroup.stop KILLs it.
        LEFTOVER_GRACE = 3.0
        LEFTOVER_POLL = 0.05
        class Error < StandardError
          attr_reader :status

          def initialize(message, status: CLI::Exit::FAILED)
            super(message)
            @status = status
          end
        end

        attr_reader :root, :config_home, :state_home, :work_dir, :manifest

        def initialize(path, bundle_settings: {}, cost_cap: 1, cost_cap_override: false)
          @path = File.realpath(path)
          @bundle_settings = bundle_settings
          @cost_cap = cost_cap
          @cost_cap_override = cost_cap_override
          read_manifest
          @root = File.realpath(Dir.mktmpdir("chi-bundle-try-"))
          @config_home = File.join(root, "config")
          @state_home = File.join(root, "state")
          @work_dir = File.join(root, "work")
          [config_home, state_home, work_dir].each { |dir| FileUtils.mkdir_p(dir) }
          @work_dir = File.realpath(@work_dir)
          write_config
          @child_env = build_child_env
        rescue StandardError
          cleanup
          raise
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
          stop_leftovers
          FileUtils.rm_rf(root) if root && File.exist?(root)
        end

        # Stops what the run started that outlives its child chi: the
        # workers of its delegates (they leave the child's process tree,
        # SessionManager.detach_from_spawner) and its tasks (a group of
        # their own each, reparented once the child exits). Found by their
        # records in the sandbox, so nothing outside it: a session's lock
        # held by a group leader, a running task's record whose pid still
        # leads its group and started when the record says (#same_process?). Workers
        # first: one may start a task as it stops.
        def stop_leftovers
          return unless root && File.directory?(root)

          leftover_workers.each { |pid| stop_group(pid) }
          leftover_tasks.each { |pid| stop_group(pid) }
        end

        private

        def write_config
          source = ConfigFile.read_yaml(env: ENV.to_h) || {}
          data = source.to_h { |key, value| [key.to_s, value] }
          # Drop bundles, hooks, guardrails, memories, append_system_prompt,
          # recap, session, log, web, update, kitty, tmux, broadcast and
          # context sources; keep model and ordinary runtime settings.
          CONFIG_DENYLIST.each { |key| data.delete(key) }
          data["context"] = data["context"].dup if data["context"].is_a?(Hash)
          data["context"]&.delete("sources")
          data["bundles"] = { "cost-cap" => { "cap" => @cost_cap } }
          data["bundles"][@manifest.name] ||= {}
          data["bundles"][@manifest.name].merge!(@bundle_settings)
          data["bundles"]["cost-cap"]["cap"] = @cost_cap if @cost_cap_override
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
        rescue Psych::Exception => e
          raise Error, "chi bundle try: manifest.yml is not valid YAML (#{e.message})"
        end

        def install_path(path)
          out, err, status = Open3.capture3(child_env, RbConfig.ruby, "-I", LIB_DIR, CHI,
                                            "bundle", "install", path, "--force", chdir: work_dir)
          return if status.success?

          message = [out, err].reject(&:empty?).join("\n").strip
          raise Error, "chi bundle try: #{message.empty? ? "bundle install failed" : message}"
        end

        def leftover_workers
          sessions = File.join(state_home, Session::STATE_SUBDIR)
          Dir.glob(File.join(sessions, "*", OwnerLock::FILE)).filter_map do |lock|
            pid = OwnerLock.owner(File.dirname(lock))&.pid
            pid if ProcessGroup.leader?(pid)
          end
        end

        def leftover_tasks
          pattern = File.join(work_dir, Tools::TaskRuntime::TASKS_DIR, "*", Tools::TaskRuntime::METADATA_FILENAME)
          Dir.glob(pattern).filter_map do |file|
            record = Tools::TaskRecord.from_file(JSON.parse(File.read(file)))
            record.pid if record&.running? && same_process?(record)
          rescue JSON::ParserError, SystemCallError
            nil
          end
        end

        # Stricter than TaskRuntime.chis_group?: a record with no start time
        # (a hand-over not adopted yet) or a start time that can't be read
        # now is skipped, never a group whose leader may reuse the pid.
        def same_process?(record)
          started = record.pid_started
          return false unless started && ProcessGroup.signalable?(record.pid)

          ProcessGroup.start_time(record.pid) == started && ProcessGroup.leader?(record.pid)
        end

        def stop_group(pid)
          ProcessGroup.stop(pid, grace: LEFTOVER_GRACE, poll: LEFTOVER_POLL)
        rescue ArgumentError, SystemCallError
          nil
        end

        def build_child_env
          env = ENV.to_h
          SessionManager::SESSION_MARKER_ENV.each { |key| env.delete(key) }
          env.delete("SAMAGOTCHI_LOG_FILE")
          env.delete("SAMAGOTCHI_LOG_DISABLE")
          env.delete("SAMAGOTCHI_SKIP_SYSTEM_BUNDLE")
          env.delete("SAMAGOTCHI_ENV") if env["SAMAGOTCHI_ENV"] == "test"
          env.delete("SAMAGOTCHI_INSTALLED_VERSION")
          env.delete_if do |key, _|
            key.start_with?(SessionManager::WORKER_ENV_PREFIX) || key == SessionManager::BOOT_FALLBACK_ENV ||
              CONFIG_DENYLIST_ENV_PREFIXES.any? { |prefix| key == prefix || key.start_with?("#{prefix}_") }
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
