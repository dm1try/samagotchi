# frozen_string_literal: true

require_relative "../chi_home"
require_relative "../child_env"
require_relative "../config"
require_relative "../installed_gem"
require_relative "../log"
require_relative "../log_path"
require_relative "../model_profile"
require_relative "../paths"

module Samagotchi
  class SessionManager
    # CROSS-VERSION CONTRACT: this boot string, the entry it names
    # (WorkerBoot.run_session_loop(id, state_dir:)), the env keys
    # spawn_options sets and the input/ file format are read by a NEWER chi
    # than the one writing them. Change them only additively
    # (spec/worker_contract_spec.rb).
    BOOT_FALLBACK_ENV = "SAMAGOTCHI_BOOT_FALLBACK"
    # "1" in a worker spawn_options started: it traps signals (WorkerSignals).
    # WorkerBoot.run_session_loop deletes it from ENV as it reads it.
    WORKER_PROCESS_ENV = "SAMAGOTCHI_WORKER_PROCESS"
    # "1" in a worker spawn_options started: WorkerBoot.run_session_loop
    # leaves the spawner's process tree first (detach_from_spawner); deleted
    # from ENV as it is read, so an rspec run by the worker's execute never
    # forks.
    WORKER_DETACH_ENV = "SAMAGOTCHI_WORKER_DETACH"

    # The boot string's rescue under a chi home: one line in the spawner's
    # log file (SAMAGOTCHI_LOG_FILE, set by spawn_options), LogLine's shape,
    # then exit. Single-quoted: the #{} run in the worker. SID is replaced.
    # rubocop:disable-next Lint/InterpolationCheck -- the worker interpolates these, not this process
    HOME_BOOT_FAILED = 'rescue ScriptError, StandardError => e; f = ENV["SAMAGOTCHI_LOG_FILE"].to_s; begin; ' \
                       'File.open(f, "a") { |io| io.puts(Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ") + ' \
                       '" ERROR worker pid=#{Process.pid} sid=SID boot_failed ruby=#{RbConfig.ruby.inspect} error=" + ' \
                       "e.message.lines.first.to_s.strip.inspect) } unless f.empty?; rescue SystemCallError; end; exit 1"

    # WorkerCommand: the worker's command line and env (CROSS-VERSION
    # CONTRACT: spec/worker_contract_spec.rb); the worker process itself is
    # WorkerBoot (worker_boot.rb), which the boot command loads directly.
    # Calls no other part. Meant to be loaded through
    # samagotchi/session_manager.
    module WorkerCommandPart
      # Build the opts hash passed to Process.spawn for a forked worker. The
      # child inherits this process's ENV and reads config.yml itself (as it
      # is when the worker starts); opts[:env] adds to it (merged, not
      # replaced) what it can't read there: this `chi`'s CLI settings
      # (Config.cli_env) and the absolute log file. It unsets
      # what ChildEnv lists (SAMAGOTCHI_GUARDRAILS_*, the session markers).
      # XDG_CONFIG_HOME passes: whoever starts or
      # wakes the worker picks which config.yml it reads (docs/guardrails.md).
      # XDG_STATE_HOME and XDG_CONFIG_HOME, when set, pass made absolute
      # (Paths): the worker starts in the session's directory.
      private def spawn_options(session)
        # Own process group: workers outlive `chi web`, and a Ctrl-C in its
        # terminal must not reach them (the worker then leaves the process
        # tree too: WORKER_DETACH_ENV).
        opts = { out: File::NULL, err: File::NULL, pgroup: true }
        # The worker's tools (and `!cmd`) run in the session's directory, not
        # in the cwd of whoever woke it (`chi web`, another terminal).
        dir = session.working_directory.to_s
        if !dir.empty? && File.directory?(dir)
          opts[:chdir] = dir
        else
          Log.warn(:worker, "cwd_gone", sid: session.id, dir: dir, cwd: Dir.pwd)
        end
        # (A chi a session's tool runs took that session's project env out at
        # its start: bin/chi, ProjectEnv.take_orig!.)
        child_env = {}
        # A worker gets no CLI args: --model, --thinking, --log-level and the
        # other flags this chi was started with.
        child_env.merge!(Config.cli_env)
        child_env[ModelProfile::MODEL_FROM_CLI_ENV] = "1" if child_env.key?(ModelProfile::MODEL_ENV)
        # And the spawner's debug log, absolute: a relative log.file would
        # otherwise land in the worker's (the session's) directory.
        log_path = begin LogPath.resolve rescue nil end # degrade-ok: no log to say it in; the worker's is off (below)
        if log_path
          child_env["SAMAGOTCHI_LOG_FILE"] = log_path
        else
          child_env["SAMAGOTCHI_LOG_DISABLE"] = "true"
        end
        # And the spawner's XDG dirs, absolute: a relative XDG_STATE_HOME or
        # XDG_CONFIG_HOME would otherwise be read from the session's directory.
        child_env.merge!(Paths.absolute_xdg)
        # Unset (Process.spawn unsets a key mapped to nil) what no child chi
        # takes from its spawner (ChildEnv): the spawner's guardrails settings
        # (a parent agent starting or waking a session; config.yml no longer
        # reads them, this keeps an older or future env-exposed one out as
        # well); the session markers, a session's own (a worker started from
        # its commands, chi send, is another session: its execute and tasks
        # set its own; nothing else it runs has one); and a smoke's fake
        # "newest installed", for this process's notices only.
        child_env.merge!(ChildEnv.unset)
        # A worker process: WorkerBoot.run_session_loop traps signals, and
        # leaves this process's tree.
        child_env[WORKER_PROCESS_ENV] = "1"
        child_env[WORKER_DETACH_ENV] = "1"
        # A gem-mode worker activates the newest installed chi itself: under
        # `bundle exec` (a Gemfile that has samagotchi) Bundler's RUBYOPT would
        # hold it to the bundle's version, and its badge would never clear.
        child_env.merge!(ChildEnv.unbundled)
        opts[:env] = child_env unless child_env.empty?
        opts
      end

      # The worker's command line. Run from an installed gem, the worker
      # activates the newest installed samagotchi (`>= 0.a`, prereleases
      # count), whoever spawns it: an old chi web, chi send or --attach then
      # starts new workers on the newest chi rather than on its own. Activating
      # the gem also makes its dependencies resolve as its gemspec pins them
      # (reline ~> 0.6.3). Should that fail (a broken newest install), the
      # worker falls back to the spawner's own version and logs why.
      #
      # A source checkout (bin/chi, bundle exec; InstalledGem.spec is nil
      # there) keeps the plain -I lib: a worktree's bin/chi spawns its own code.
      def worker_command(session_id, state_dir:, gem_spec: InstalledGem.spec,
                         home: ChiHome.current(gem_spec: gem_spec))
        boot = "require 'samagotchi/worker_boot'; " \
               "Samagotchi::WorkerBoot.run_session_loop('#{session_id}', state_dir: #{state_dir.inspect})"
        return [RbConfig.ruby, "-I", File.expand_path("../..", __dir__), "-e", boot] unless gem_spec
        return home_worker_command(session_id, state_dir: state_dir, gem_spec: gem_spec, home: home) if home

        activate = "begin; gem 'samagotchi', '>= 0.a'; rescue LoadError => e; " \
                   "ENV['#{BOOT_FALLBACK_ENV}'] = e.message; gem 'samagotchi', '= #{gem_spec.version}'; end"
        [RbConfig.ruby, "-e", "#{activate}; #{boot}"]
      end

      # With a chi home (ChiHome.current, docs/architecture.md "How chi
      # launches itself"): the home's ruby, `Gem.paths` set to its gems in the
      # boot string (no GEM_* in the worker's env), the newest chi there, else
      # the fallback pin (ChiHome.fallback_version). A home that still can't
      # load chi (a broken install) logs HOME_BOOT_FAILED and exits: never a
      # silent spawn timeout.
      private def home_worker_command(session_id, state_dir:, gem_spec:, home:)
        newest = home.newest_version
        if newest && newest < Gem::Version.new(gem_spec.version.to_s)
          ChiHome.warn_once(:older_than_spawner, home: newest.to_s, spawner: gem_spec.version.to_s)
        end
        fallback = ChiHome.fallback_version(home, gem_spec)
        activate = if fallback
                     "begin; gem 'samagotchi', '>= 0.a'; rescue LoadError => e; " \
                       "ENV['#{BOOT_FALLBACK_ENV}'] = e.message; gem 'samagotchi', '= #{fallback}'; end"
                   else
                     "gem 'samagotchi', '>= 0.a'"
                   end
        home.boot_argv(run: "begin; #{activate}; require 'samagotchi/worker_boot'; " \
                             "#{HOME_BOOT_FAILED.sub("SID", session_id)}; end; " \
                             "Samagotchi::WorkerBoot.run_session_loop('#{session_id}', state_dir: #{state_dir.inspect})")
      end
    end

    extend WorkerCommandPart
  end
end
