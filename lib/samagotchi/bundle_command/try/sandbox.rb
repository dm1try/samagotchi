# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"
require_relative "../../config"
require_relative "../../child_env"
require_relative "../../cli/exit"
require_relative "../../memory_bundle/system_bundle"
require_relative "../../memory_bundle"
require_relative "../../memory_bundle/shas"
require_relative "../../owner_lock"
require_relative "../../process_group"
require_relative "../../sandbox_layout"
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
        # The config.yml sections the sandbox drops (and their SAMAGOTCHI_<SECTION>_* env forms); context:
        # loses only its sources: (#write_config).
        CONFIG_DENYLIST = %w[
          bundles hooks guardrails memories append_system_prompt recap session log web update kitty tmux broadcast
        ].freeze
        CONFIG_DENYLIST_ENV_PREFIXES = CONFIG_DENYLIST.map do |section|
          prefix = if section == "guardrails"
                     ChildEnv::GUARDRAILS_PREFIX.delete_suffix("_")
                   else
                     "SAMAGOTCHI_#{section.upcase}"
                   end
          prefix
        end.freeze
        # `chi bundle install PATH --force` for each PATH in ARGV, in one
        # process (bin/chi's start, once): an install that fails prints
        # what it printed and exits with its status; the ones before it
        # print nothing. A config chi stops at (RemovedApi, as bin/chi
        # does) prints its one line.
        INSTALL_SCRIPT = <<~RUBY
          require "stringio"
          require "samagotchi/utf8_default"
          Samagotchi::Utf8Default.apply!
          require "samagotchi/config"
          begin
            Samagotchi::ConfigFile.load!
          rescue Samagotchi::ConfigFile::RemovedApi => e
            warn e.message
            exit 1
          end
          require "samagotchi"
          require "samagotchi/bundle_command"
          ARGV.each do |path|
            out = StringIO.new
            err = StringIO.new
            status = Samagotchi::BundleCommand.new(["install", path, "--force"], stdout: out, stderr: err).run
            next if status.zero?

            $stdout.write(out.string)
            $stderr.write(err.string)
            exit(status)
          end
        RUBY
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

        attr_reader :root, :config_home, :state_home, :work_dir

        def initialize(path, bundle_settings: {}, cost_cap: 1, cost_cap_override: false)
          @path = File.realpath(path)
          @bundle_settings = bundle_settings
          @cost_cap = cost_cap
          @cost_cap_override = cost_cap_override
          read_manifest
          @layout = SandboxLayout.create("chi-bundle-try-")
          @root = @layout.root
          @config_home = @layout.config_home
          @state_home = @layout.state_home
          @work_dir = @layout.work_dir
          write_config
          @child_env = build_child_env
        rescue StandardError
          cleanup
          raise
        end

        def child_env = @child_env.dup

        # Installs the tried bundle, then the shipped guardrails and
        # cost-cap (unless it is one of them), each as `chi bundle install
        # PATH --force` in one child chi with the sandbox's environment.
        # @return [MemoryBundle::Manifest]
        # @raise [Error] what the first install that failed printed
        def install
          paths = [@path] + %w[guardrails cost-cap].reject { |name| @manifest.name == name }
                                                     .map { |name| File.join(SHIPPED_DIR, name) }
          out, err, status = Open3.capture3(child_env, RbConfig.ruby, "-I", LIB_DIR, "-e", INSTALL_SCRIPT, *paths,
                                            chdir: work_dir)
          unless status.success?
            message = [out, err].reject(&:empty?).join("\n").strip
            raise Error, "chi bundle try: #{message.empty? ? "bundle install failed" : message}"
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
          @layout.write_config(data)
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

        # The user's environment (their hosts and keys) minus what no child
        # chi takes from its spawner (ChildEnv), the worker markers, this
        # chi's log and test settings, and the env forms of the config
        # sections the sandbox drops.
        def build_child_env
          env = ChildEnv.scrub(ENV.to_h)
          env.delete("SAMAGOTCHI_LOG_FILE")
          env.delete("SAMAGOTCHI_LOG_DISABLE")
          env.delete(MemoryBundle::SystemBundle::SKIP_ENV)
          env.delete("SAMAGOTCHI_ENV") if env["SAMAGOTCHI_ENV"] == "test"
          env.delete_if do |key, _|
            key.start_with?(ChildEnv::WORKER_PREFIX) || key == SessionManager::BOOT_FALLBACK_ENV ||
              CONFIG_DENYLIST_ENV_PREFIXES.any? { |prefix| key == prefix || key.start_with?("#{prefix}_") }
          end
          env.merge!(
            "HOME" => Dir.home,
            "SAMAGOTCHI_KEYCHAIN" => "on",
            **@layout.env
          )
          env.merge!(ChildEnv.unbundled(env))
          env
        end
      end
    end
  end
end
