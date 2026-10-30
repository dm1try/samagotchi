# frozen_string_literal: true

require "json"
require "open3"
require_relative "chi_home"
require_relative "chi_shim"
require_relative "config"
require_relative "log"
require_relative "log_line"
require_relative "log_path"
require_relative "paths"

module Samagotchi
  # Tools follow the project: a spawned worker computes its session folder's
  # `mise env` once, at boot (#compute), and the commands it starts for the
  # session (execute, task_create, `!cmd`, MCP servers, context sources) get
  # it merged into their env (#current's Overlay#env), so they see the
  # project's Ruby, node, … whoever started the worker (a terminal on another
  # Ruby, chi web, the macOS helper under launchd). The worker's own process
  # never takes it: its ENV stays the spawner's, so the project can't reach
  # chi's own settings, keys, proxies or dirs (LLM calls, HostKeys, Config,
  # Paths, hooks, plugins). A pair turn's tools don't get it either. A
  # mise.toml edit reaches a session at its next worker (`chi sessions
  # restart`). The REPL modes run no worker and keep the shell's env.
  # docs/sessions.md (Project env).
  #
  # And `chi` inside those tools stays the chi home's (ChiShim): the project's
  # PATH would otherwise find the project Ruby's chi (an old one, or none).
  module ProjectEnv
    # What the worker computed, for `chi self` (it runs in a tool, not in
    # the worker): "mise:<ruby realpath>" or "none:<reason>". Tools only;
    # never a child worker's (ChildEnv).
    MARKER_ENV = "SAMAGOTCHI_PROJECT_ENV"
    # The mise a worker runs, and only that path when set (specs point it at
    # a missing file: the developer's own mise is never asked).
    MISE_CLI_ENV = "SAMAGOTCHI_MISE_CLI"
    # In the tools' env: the worker's own value (or null for unset) of each
    # key the overlay changes, JSON. A chi a tool runs (bin/chi, through the
    # shim or not) takes those values back first thing (#take_orig!), so
    # its own process (API keys, proxies) and the workers it starts (`chi
    # send --new --dir B`) never run on project A's env. A forged one can
    # only set what that tool could set on chi itself; #restore_env never
    # sets a reserved key or a loader variable (RESTORE_NEVER).
    ORIG_ENV = "SAMAGOTCHI_PROJECT_ENV_ORIG"
    # mise's own shell-session state (and any other __MISE_*): never passed
    # to `mise env`, never taken from its answer, unset in the tools' env
    # (they describe the shell mise was activated in).
    MISE_STATE = %w[__MISE_DIFF __MISE_SESSION __MISE_ORIG_PATH MISE_SHELL].freeze
    GEM_KEYS = %w[GEM_HOME GEM_PATH].freeze
    # Keys the tools' overlay never sets: a `chi` a tool runs (the shim's)
    # reads its config, state and log dirs, its settings and the machine its
    # session commands go to (CHI_REMOTE) from them, and the test-run flags.
    # And TMPDIR: the guardrails judge a tool's `$TMPDIR/x` and its tmp dirs
    # (Guardrails::PathResolve.tmp_roots) by the worker's own TMPDIR, so the
    # tools must run on that one too. Dropped, with one warning.
    RESERVED_KEYS = %w[HOME TMPDIR RACK_ENV CI CHI_REMOTE].freeze
    RESERVED_PREFIXES = %w[XDG_ SAMAGOTCHI_].freeze
    # Never set from an ORIG_ENV record (a tool can write it), only unset:
    # loader and Bundler variables.
    RESTORE_NEVER = /\A(?:DYLD_|LD_|RUBYOPT\z|RUBYLIB\z|RUBYGEMS_|BUNDLE)/
    # Never passed to `mise env`: MISE_YES answers its trust prompt (it
    # would trust, and remember, an untrusted repo's mise.toml); CI too.
    MISE_UNSET = %w[MISE_YES CI].freeze
    TIMEOUT = 5
    # What execute and tasks set themselves (Tools::TaskRuntime's
    # sanitized env): never taken from the project's.
    TOOLS_DROP = %w[RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLER_VERSION].freeze

    # What #compute found: +env+ the tools' overlay ({key => value, or nil
    # to unset}; frozen, with the marker and the ORIG_ENV record),
    # +applied+ whether mise answered, +reason+ why not (a short token, the
    # marker's and the warning's), +ruby+ the first `ruby` on the tools'
    # PATH (realpath) or nil.
    Overlay = Data.define(:env, :applied, :reason, :ruby) do
      def marker = applied ? "mise:#{ruby || "no ruby"}" : "none:#{reason}"
    end
    # No project env: specs, the REPL modes, a worker before #install!.
    NONE = Overlay.new(env: {}.freeze, applied: false, reason: "none", ruby: nil)

    class Failed < StandardError; end

    # chi home doctor's row when session.project_env is mise and no mise is found.
    NO_MISE = "project env: no mise found (home.json's, PATH, /opt/homebrew/bin, /usr/local/bin, ~/.local/bin): " \
              "tools run in the env of whoever starts the worker; install mise, or set session.project_env: off"
    # How much of the debug log's end chi home doctor reads (#last_warning,
    # HomeDoctor's boot row).
    LOG_TAIL_BYTES = 4 * 1024 * 1024

    # A worker's `project_env` warning from the debug log (#last_warning).
    Warning = Data.define(:ts, :sid, :dir, :reason, :error) do
      # chi home doctor's row: what failed and what to run.
      def message
        detail = error.to_s.start_with?("#{reason}:") ? error : [reason, error].compact.reject(&:empty?).join(": ")
        fix = error.to_s.include?("mise trust") || error.to_s.include?("not trusted") ? "mise trust in #{dir}" : "fix that"
        restart = sid ? "chi sessions restart #{sid}" : "chi sessions restart ID"
        "the last worker in #{dir} (#{ts}) got no project env (#{detail}): #{fix}, then #{restart}"
      end
    end

    @current = NONE

    module_function

    # The overlay this process's tools get: the worker's, set once at boot
    # (#install!); NONE elsewhere.
    # @return [Overlay]
    def current = @current

    # Only from SessionManager.run_session_loop, in a spawned worker.
    def install!(overlay) = @current = overlay

    # #current's env for a tool's spawn, less what every tool runs without
    # (Tools::TaskRuntime::SANITIZED_ENV_KEYS: RUBYOPT, RUBYLIB, Bundler's).
    # @return [Hash{String=>String, nil}]
    def tools_env = current.env.except(*TOOLS_DROP)

    # Specs: back to NONE.
    def reset! = @current = NONE

    # The tools' overlay for the session folder +dir+, from +env+ (the
    # worker's ENV, read, never written).
    # @param dir [String] the session's working_directory
    # @param mode [String] session.project_env: "mise" or "off"
    # @param home [ChiHome::Record, nil] the chi home (the shim's)
    # @param runner [#call] (env, argv, timeout:) → stdout (+env+ is the child's whole env); raises Failed
    # @return [Overlay]
    def compute(dir, env: ENV, mode: configured_mode, home: ChiHome.current, cwd: Dir.pwd,
                runner: method(:run_mise), shim_dir: ChiShim.dir(env: env), timeout: TIMEOUT)
      base = env.to_h.dup
      tools = base.dup
      applied, reason = mise_overlay(dir, tools, mode: mode, cwd: cwd, runner: runner, timeout: timeout)
      prepend_shim(tools, home: home, shim_dir: shim_dir)
      overlay = Overlay.new(env: {}, applied: applied, reason: reason, ruby: applied ? ruby_on(tools["PATH"]) : nil)
      changes = diff(base, tools)
      changes[ORIG_ENV] = JSON.generate(changes.keys.to_h { |key| [key, base[key]] }) unless changes.empty?
      changes[MARKER_ENV] = overlay.marker
      overlay.with(env: changes.freeze)
    end

    # Applies the mise env to +tools+ (a copy of the worker's env).
    # @return [Array(Boolean, String)] applied, reason
    def mise_overlay(dir, tools, mode:, cwd:, runner:, timeout:)
      return skipped("off") if mode == "off"
      return skipped("no_dir") if dir.to_s.empty?
      return skipped("cwd_mismatch", warn: { dir: dir, cwd: cwd }) unless same_dir?(dir, cwd)

      mise = find_mise(env: tools)
      return skipped("no_mise") unless mise

      answer = parse(runner.call(mise_env(tools), [mise, "env", "-C", dir, "--json"], timeout: timeout))
      answer = without_reserved(answer, dir)
      before = ruby_on(tools["PATH"])
      tools.delete_if { |key, _| mise_state?(key) }
      tools.update(answer)
      drop_gem_env(tools, answer, before, ruby_on(tools["PATH"]))
      [true, nil]
    rescue Failed => e
      skipped(e.message.split(":", 2).first, warn: { dir: dir, error: e.message })
    end

    # {key => new value, or nil for a removed key} between +before+ and +after+.
    def diff(before, after)
      changed = (before.keys | after.keys).reject { |key| before[key] == after[key] }
      changed.to_h { |key| [key, after[key]] }
    end

    # #ORIG_ENV of +env+: {key => value or nil}; {} without one (or one that
    # isn't its shape). Reserved keys never come back; a RESTORE_NEVER key
    # only as an unset (project A's LD_LIBRARY_PATH goes, nothing comes).
    # @return [Hash{String=>String, nil}]
    def restore_env(env = ENV)
      data = JSON.parse(env[ORIG_ENV].to_s)
      return {} unless data.is_a?(Hash)

      data.select do |key, value|
        next false unless key.is_a?(String) && !reserved?(key)

        value.nil? || (value.is_a?(String) && !key.match?(RESTORE_NEVER))
      end
    rescue JSON::ParserError
      {}
    end

    # bin/chi, before anything reads config: +env+ back to the worker's
    # values (#restore_env), the record taken out. The marker stays (chi
    # self reads it).
    def take_orig!(env = ENV)
      restore_env(env).each { |key, value| value.nil? ? env.delete(key) : env[key] = value }
      env.delete(ORIG_ENV)
    end

    def reserved?(key) = RESERVED_KEYS.include?(key) || key.start_with?(*RESERVED_PREFIXES)

    # +answer+ without RESERVED_KEYS/RESERVED_PREFIXES, warned once by name.
    def without_reserved(answer, dir)
      dropped = answer.keys.select { |key| reserved?(key) }
      Log.warn(:worker, "project_env_reserved", dir: dir, keys: dropped.sort.join(",")) unless dropped.empty?
      answer.except(*dropped)
    end

    # The first one found: SAMAGOTCHI_MISE_CLI when set (that path only),
    # else home.json's mise, else PATH and the usual dirs (ChiHome.find_mise).
    # @return [String, nil]
    def find_mise(env: ENV)
      cli = env[MISE_CLI_ENV].to_s
      return (executable?(cli) ? cli : nil) unless cli.empty?

      home_mise = home_json_mise(env)
      return home_mise if home_mise && executable?(home_mise)

      ChiHome.find_mise(env: env)
    end

    # The GEM_* rule: the spawner's GEM_HOME/GEM_PATH are its Ruby's; when
    # the project env moves `ruby` to another one (or exactly one of the two
    # is a mise shim) they are dropped, unless mise sets them itself. Neither
    # resolving keeps them.
    def drop_gem_env(env, answer, before, after)
      return if before.nil? && after.nil?
      return unless before != after || (mise_shim?(before) ^ mise_shim?(after))

      GEM_KEYS.each { |key| env.delete(key) unless answer.key?(key) }
    end

    # The realpath of the first executable `ruby` on +path+, or nil.
    def ruby_on(path)
      path.to_s.split(File::PATH_SEPARATOR).each do |dir|
        next if dir.empty?

        file = File.join(dir, "ruby")
        return File.realpath(file) if File.file?(file) && File.executable?(file)
      rescue SystemCallError
        next
      end
      nil
    end

    def mise_shim?(real) = !real.nil? && File.basename(real) == "mise"

    # PATH with the shim's dir first (once), when there is a home to shim.
    def prepend_shim(env, home:, shim_dir:)
      return unless home && ChiShim.ensure!(home, dir: shim_dir)

      dirs = env["PATH"].to_s.split(File::PATH_SEPARATOR).reject { |dir| dir.empty? || dir == shim_dir }
      env["PATH"] = [shim_dir, *dirs].join(File::PATH_SEPARATOR)
    end

    # @return [Hash{String=>String}]
    # @raise [Failed]
    def parse(stdout)
      data = JSON.parse(stdout.to_s)
      raise Failed, "bad_json: not an object" unless data.is_a?(Hash)

      data.select { |key, value| key.is_a?(String) && value.is_a?(String) && !mise_state?(key) }
    rescue JSON::ParserError => e
      raise Failed, "bad_json: #{e.message.lines.first.to_s.strip[0, 120]}"
    end

    # The whole env `mise env` runs with (nothing else inherited): the
    # worker's, less mise's shell state (an activated shell's __MISE_DIFF
    # would make it answer relative to that shell) and MISE_UNSET (its
    # MISE_TRUSTED_CONFIG_PATHS stays: the user's own trust list).
    def mise_env(env) = env.to_h.reject { |key, _| mise_state?(key) || MISE_UNSET.include?(key) }

    def mise_state?(key) = key.start_with?("__MISE_") || MISE_STATE.include?(key)

    # @return [String] stdout
    # @raise [Failed]
    def run_mise(child_env, argv, timeout:)
      Open3.popen3(child_env, *argv, pgroup: true, unsetenv_others: true) do |stdin, out, err, wait|
        stdin.close
        readers = [out, err].map { |io| Thread.new { io.read }.tap { |t| t.report_on_exception = false } }
        unless wait.join(timeout)
          kill_group(wait.pid)
          wait.join(1)
          readers.each { |reader| reader.join(1) }
          raise Failed, "mise_timeout: no answer in #{timeout} s"
        end
        readers.each { |reader| reader.join(1) }
        stdout, stderr = readers.map { |reader| reader.alive? ? "" : reader.value.to_s }
        status = wait.value
        raise Failed, "mise_failed: exit #{status.exitstatus}: #{brief(stderr)}" unless status.success?

        stdout
      end
    rescue SystemCallError => e
      raise Failed, "mise_failed: #{e.message}"
    end

    def kill_group(pid)
      Process.kill("KILL", -pid)
    rescue SystemCallError
      nil
    end

    # mise's stderr in one line, without its noise ("mise ERROR Config files
    # in … are not trusted. / Trust them with `mise trust`…").
    MISE_NOISE = /\AVersion:|--verbose|MISE_VERBOSE/
    def brief(text)
      text.to_s.lines.map { |line| line.strip.delete_prefix("mise ERROR ").strip }
          .reject { |line| line.empty? || line.match?(MISE_NOISE) }.join(" / ")[0, 600]
    end

    # @return [Array(false, String)]
    def skipped(reason, warn: nil)
      Log.warn(:worker, "project_env", reason: reason, **warn) if warn
      [false, reason]
    end

    def same_dir?(dir, cwd)
      !dir.to_s.empty? && ChiHome.real(dir) == ChiHome.real(cwd)
    end

    def executable?(file) = File.file?(file) && File.executable?(file)

    def home_json_mise(env)
      ChiHome.read(path: ChiHome.path(env: env))&.mise
    rescue ChiHome::Invalid
      nil
    end

    # The newest worker record in the debug log for one of the folders
    # +dirs+ (a folder and the ones above it in its project), when it is a
    # `project_env` warning (an untrusted mise.toml, a timeout); nil when
    # the newest is `project_env_applied`, there is none, or the log can't
    # be read. Reads the log's last LOG_TAIL_BYTES only.
    # @return [Warning, nil]
    def last_warning(dirs, log_path: LogPath.resolve)
      return nil unless log_path && File.file?(log_path)

      want = Array(dirs).map { |dir| ChiHome.real(dir) }
      newest = {}
      LogLine.each_tail_record(log_path, bytes: LOG_TAIL_BYTES) do |record|
        next unless record.tag == "worker" && %w[project_env project_env_applied].include?(record.event)

        dir = record.fields["dir"]
        newest[ChiHome.real(dir)] = record if dir && want.include?(ChiHome.real(dir))
      end
      found = newest.values.select { |record| record.event == "project_env" }.max_by(&:ts)
      return nil unless found

      Warning.new(ts: found.ts, sid: found.sid, dir: Paths.tilde(found.fields["dir"]),
                  reason: found.fields["reason"], error: found.fields["error"])
    rescue SystemCallError
      nil
    end

    def configured_mode
      Config.get("session.project_env").to_s
    rescue StandardError
      "mise"
    end
  end
end
