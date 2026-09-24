
# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "securerandom"
require "rbconfig"

require_relative "session"
require_relative "owner_lock"
require_relative "bridge_client"
require_relative "log"
require_relative "log_path"
require_relative "recap_store"
require_relative "terminal_ui"

module Samagotchi
  # SessionManager coordinates background session processes.
  #
  # Each session runs in its own forked Ruby process, communicating via
  # file-based IPC in the session directory.
  #
  # The session itself (messages + metadata) is always saved by Session at
  # <sessions dir>/<session_id>.json, for foreground chats too. A sibling
  # directory holds the owner lock (any owner, TUI included) and, for
  # background workers, their IPC files:
  #   ~/.local/state/samagotchi/sessions/
  #   ├── <session_id>.json       # the session (Session#save)
  #   └── <session_id>/
  #       ├── owner.lock          # flock held by the session's one owner (OwnerLock)
  #       ├── input/              # clients (web/terminal UI) write messages here
  #       │   └── <timestamp>.json # one file per user message: {prompt, client_id,
  #       │                        # enqueued_id} (plain <timestamp>.txt for old workers)
  #       ├── notes/              # context notes: background text the worker adds to
  #       │   └── <ts>-<rand>.json # the conversation between turns, never a turn
  #       │                        # ({text, source, from_session?, from_cwd?, created_at})
  #       ├── output/             # agent writes responses here
  #       │   └── <timestamp>.txt # one file per agent response
  #       ├── pid                 # PID of the owner, written by the owner itself
  #       └── bridge.json         # Bridge sidecar (how clients reach the worker)
  # Needed only at call time (run_session_loop); worker.rb requires this file.
  autoload :Worker, File.expand_path("worker", __dir__)

  class SessionManager
    INPUT_DIR  = "input"
    # Context notes live apart from input/, so nothing that reads input/
    # (the mid-turn drain, the idle-exit hold, the Waker) ever sees one.
    NOTES_DIR  = "notes"
    NOTE_MAX_BYTES = 16 * 1024
    OUTPUT_DIR = "output"
    PID_FILE   = "pid"
    # Input-file format this worker reads, advertised in the Bridge sidecar:
    #   2  JSON with the sender's ids (and plain text)
    #   3  images: refs too
    # A worker that doesn't advertise one reads only .txt, and such workers
    # never exit.
    INPUT_FORMAT = 3
    STRUCTURED_INPUT_FORMAT = 2
    IMAGES_INPUT_FORMAT = 3

    # A turn with images for a worker older than IMAGES_INPUT_FORMAT, which
    # would drop them.
    class ImagesUnsupported < StandardError
      def initialize(msg = "this session's worker predates images: restart it (/exit, then resume)") = super
    end
    # Origin of the synthetic turn queued when reminders are due.
    REMINDER_CLIENT_ID = "system:reminder"

    # Raised when the interactive TUI owns the session: it runs its own Engine
    # and reads no input files, so a worker must not be spawned or signalled.
    class OwnedByTUI < StandardError
      def initialize(session_id)
        super("session #{session_id} is owned by an interactive TUI")
      end
    end

    # A note (or a `chi send` message) that can't go in: empty, or over
    # NOTE_MAX_BYTES.
    class NoteRejected < ArgumentError; end

    # A delete that would pull the session from under its live worker.
    # reason: :worker_running (not asked to stop it) or :still_stopping
    # (stopped, but the worker outlived the wait).
    class DeleteRefused < StandardError
      attr_reader :session_id, :reason

      def initialize(session_id, reason)
        @session_id = session_id
        @reason = reason
        super(reason == :still_stopping ? "session #{session_id}'s worker is still shutting down" : "session #{session_id}'s worker is running")
      end
    end

    # Spawn a new background session that processes the given prompt (or,
    # with none, waits idle for input).
    #
    # Returns the session object with its ID. Every worker always starts its
    # per-session Bridge (the single live client transport), so external
    # clients can reach it once the sidecar is published.
    def self.spawn_session(prompt:, mode: "assist", working_directory: nil, model_name: nil, state_dir: nil)
      sd = state_dir || Session.default_state_dir
      session = Session.new_session(
        mode: mode,
        model_name: model_name || Samagotchi::ModelProfile.required_model_name,
        working_directory: working_directory || Dir.pwd
      )
      # With no prompt there is no first turn to run (an attaching UI sends
      # the prompts), so the session starts idle.
      session.status = prompt.to_s.strip.empty? ? Session::STATUS_IDLE : Session::STATUS_RUNNING
      session.last_prompt = prompt
      # The worker takes last_prompt and clears it, and messages are saved at
      # the turn's end: until then this is the only preview a list has.
      session.first_preview = Session.preview_of(prompt)
      session_dir = Session.session_dir(session.id, state_dir: sd)
      setup_session_directory(session_dir, session, state_dir: sd)
      spawn_worker_for_session(session, state_dir: sd)
      session
    end

    # Build the opts hash passed to Process.spawn for a forked worker. Setting
    # opts[:env] REPLACES the child ENV rather than merging it, so explicitly
    # thread through the values a worker needs (hosts, default model).
    private_class_method def self.spawn_options(session)
      # Own process group: workers outlive `chi web`, and a Ctrl-C in its
      # terminal must not reach them.
      opts = { out: File::NULL, err: File::NULL, pgroup: true }
      # The worker's tools (and `!cmd`) run in the session's directory, not
      # in the cwd of whoever woke it (`chi web`, another terminal).
      dir = session.working_directory.to_s
      if !dir.empty? && File.directory?(dir)
        opts[:chdir] = dir
      else
        Log.warn(:worker, "cwd_gone", sid: session.id, dir: dir, cwd: Dir.pwd)
      end
      child_env = {}
      # Propagate hosts config for multi-host routing
      begin
        require_relative "config"
        hosts_json = ConfigFile.hosts_json_for_env
        child_env["SAMAGOTCHI_HOSTS_JSON"] = hosts_json if hosts_json && !hosts_json.strip.empty?
      rescue StandardError
        nil
      end
      # Also propagate current default model (may be host-qualified)
      child_env["SAMAGOTCHI_DEFAULT_MODEL"] = ENV["SAMAGOTCHI_DEFAULT_MODEL"] if ENV["SAMAGOTCHI_DEFAULT_MODEL"]
      # A worker gets no CLI args: pass on an idle exit set by any layer.
      idle_exit = config_idle_exit_minutes
      child_env["SAMAGOTCHI_SESSION_IDLE_EXIT_MINUTES"] = idle_exit.to_s unless idle_exit.nil?
      # And the spawner's debug log, absolute: a relative log.file would
      # otherwise land in the worker's (the session's) directory.
      log_path = begin LogPath.resolve rescue nil end
      if log_path
        child_env["SAMAGOTCHI_LOG_FILE"] = log_path
      else
        child_env["SAMAGOTCHI_LOG_DISABLE"] = "true"
      end
      # And its level (a --log-level flag isn't in the worker's own config).
      level = begin Config.get("log.level") rescue nil end
      child_env["SAMAGOTCHI_LOG_LEVEL"] = level.to_s if level
      opts[:env] = child_env unless child_env.empty?
      opts
    end

    # List all sessions, reading status from persisted session.json files.
    def self.list_sessions(state_dir: nil, sort: "updated_at", order: "desc", limit: nil, offset: 0)
      Session.list(state_dir: state_dir || Session.default_state_dir, sort: sort, order: order, limit: limit, offset: offset)
    end

    # Prune sessions per retention policy. Delegates to Session.prune with live-worker guard.
    SUMMARY_DESC_LIMIT = 60

    # Short summaries of sessions, newest first: the picker behind
    # `chi sessions list --live --format json|tsv` (chi note from a script)
    # and the agent's list_sessions tool.
    # @param live [Boolean] only sessions a worker owns now (the owner lock,
    #   not the saved status, which a dead worker leaves at "running"); a
    #   REPL-owned session is left out: it can't take notes
    # @param cwd [String, nil] only sessions in this folder or below it
    # @param limit [Integer, nil] taken after the filters
    # @param include_tests [Boolean] false leaves out test runs
    # @param exclude [String, nil] a session id to leave out (the asker)
    # @return [Array<Hash>] {id:, short_id:, desc:, preview:, cwd:,
    #   updated_at:, status:, live:, busy:, owner:, recap:}; busy = live with
    #   a turn running, recap = the saved recap's first sentence
    def self.session_summaries(live: false, cwd: nil, limit: nil, include_tests: true, exclude: nil, state_dir: nil)
      sd = state_dir || Session.default_state_dir
      root = cwd && folder_path(cwd)
      summaries = Session.list(state_dir: sd, sort: "updated_at", order: "desc").lazy
                         .reject { |s| (!include_tests && s.test_run) || s.id == exclude }
                         .select { |s| root.nil? || in_folder?(s.working_directory, root) }
                         .filter_map do |s|
        owner = session_owner(s.id, state_dir: sd)&.fetch("kind", nil)
        owned = owner == "worker"
        next if live && !owned

        { id: s.id, short_id: s.id[0, 8], desc: summary_desc(s), preview: summary_preview(s), cwd: s.working_directory,
          updated_at: s.updated_at, status: s.status, live: owned, busy: owned && s.status == Session::STATUS_RUNNING,
          owner: owner, recap: RecapStore.preview(Session.session_dir(s.id, state_dir: sd)) }
      end
      (limit ? summaries.first(limit) : summaries.to_a)
    end

    SUMMARY_PREVIEW_LIMIT = 120

    # "<cwd basename> · <last prompt, or the first preview>", one line.
    private_class_method def self.summary_desc(session)
      desc = [File.basename(session.working_directory.to_s), summary_text(session)].reject(&:empty?).join(" · ")
      cut(desc, SUMMARY_DESC_LIMIT)
    end

    private_class_method def self.summary_preview(session)
      cut(summary_text(session), SUMMARY_PREVIEW_LIMIT)
    end

    private_class_method def self.summary_text(session)
      text = session.last_prompt.to_s.strip.empty? ? session.first_preview.to_s : session.last_prompt.to_s
      text.gsub(/\s+/, " ").strip
    end

    private_class_method def self.cut(text, limit)
      text.length > limit ? "#{text[0, limit - 1]}…" : text
    end

    private_class_method def self.folder_path(path)
      File.realpath(path)
    rescue SystemCallError
      File.expand_path(path)
    end

    private_class_method def self.in_folder?(dir, root)
      dir = dir.to_s.chomp("/")
      root = root.chomp("/")
      dir == root || dir.start_with?("#{root}/")
    end

    def self.prune_sessions(state_dir: nil, days: nil, max_count: nil, keep_status: nil, dry_run: false, test_only: false)
      sd = state_dir || Session.default_state_dir
      days = resolve_retention_days(days)
      max_count = resolve_retention_max_count(max_count)
      keep_status = resolve_retention_keep_status(keep_status)
      discard = discard_empty?
      default_model = discard ? (begin ModelProfile.required_model_name(nil) rescue nil end) : nil
      result = Session.prune(
        state_dir: sd,
        days: days,
        max_count: max_count,
        keep_status: keep_status,
        dry_run: dry_run,
        test_only: test_only,
        alive_check: ->(sid) { worker_alive_for_session?(sid, state_dir: sd) },
        empty_check: discard ? ->(sid) { left_empty?(sid, state_dir: sd, default_model: default_model) } : nil
      )
      result[:deleted].concat(prune_orphan_dirs(sd, dry_run: dry_run)) if discard && !test_only
      result
    end

    # How long a session may sit empty before the sweep takes it: its
    # worker (or a REPL) deletes it as it leaves, so the sweep only catches
    # those killed first (a reboot, kill -9).
    EMPTY_GRACE_SECONDS = 3600

    private_class_method def self.left_empty?(session_id, state_dir:, default_model:)
      path = File.join(state_dir, "#{session_id}#{Session::FILE_EXT}")
      Time.now - File.mtime(path) > EMPTY_GRACE_SECONDS &&
        empty_session?(session_id, state_dir: state_dir, default_model: default_model)
    rescue SystemCallError
      false
    end

    # Directories with no session file and nothing but the skeleton, nobody
    # owning them: a REPL killed before its first save, or a worker woken
    # just as its session was discarded.
    # @return [Array<String>] their ids
    private_class_method def self.prune_orphan_dirs(state_dir, dry_run:)
      return [] unless Dir.exist?(state_dir)

      Dir.children(state_dir).filter_map do |name|
        dir = File.join(state_dir, name)
        next unless name.match?(/\A[\w-]+\z/) && File.directory?(dir)
        next if File.exist?(File.join(state_dir, "#{name}#{Session::FILE_EXT}"))
        next unless Time.now - File.mtime(dir) > EMPTY_GRACE_SECONDS && empty_session_dir?(dir)
        next if session_owner(name, state_dir: state_dir)

        FileUtils.rm_rf(dir) unless dry_run
        name
      rescue SystemCallError
        nil
      end
    end

    # Lazy sweep guard: runs prune at most once per RETENTION_SWEEP_INTERVAL_HOURS.
    RETENTION_MARKER = ".last_retention"
    RETENTION_SWEEP_INTERVAL_HOURS = 24

    def self.retention_sweep_if_due(state_dir: nil)
      sd = state_dir || Session.default_state_dir
      return unless Dir.exist?(sd)

      cfg_interval = begin Samagotchi::Config.get("session.sweep_interval_hours") rescue nil end
      interval = if cfg_interval && cfg_interval.to_i.positive?
                   cfg_interval.to_i * 3600
                 else
                   (ENV.fetch("SAMAGOTCHI_SESSION_SWEEP_INTERVAL_HOURS", RETENTION_SWEEP_INTERVAL_HOURS.to_s).to_i * 3600)
                 end
      marker = File.join(sd, RETENTION_MARKER)
      if File.exist?(marker)
        age = Time.now - File.mtime(marker)
        return if age < interval
      end
      result = prune_sessions(state_dir: sd)
      FileUtils.touch(marker)
      if result[:deleted].any?
        Log.info(:worker, "retention_pruned", echo: "[retention] pruned #{result[:deleted].size} sessions (kept #{result[:kept].size})", deleted: result[:deleted].size, kept: result[:kept].size)
      end
      result
    rescue StandardError => e
      Log.warn(:worker, "retention_failed", echo: "[retention] sweep failed: #{e.class}: #{e.message}", error: e.class.name)
      nil
    end

    private_class_method def self.resolve_retention_days(val)
      return val.to_i if !val.nil? && val.to_s.strip != ""
      cfg = begin Samagotchi::Config.get("session.retention_days") rescue nil end
      return cfg.to_i if cfg && !cfg.to_s.strip.empty?
      env = ENV["SAMAGOTCHI_SESSION_RETENTION_DAYS"]
      return env.to_i if env && !env.strip.empty?
      Session::DEFAULT_RETENTION_DAYS
    end

    private_class_method def self.resolve_retention_max_count(val)
      return val.to_i if !val.nil? && val.to_s.strip != ""
      cfg = begin Samagotchi::Config.get("session.max_count") rescue nil end
      return cfg.to_i if cfg && !cfg.to_s.strip.empty?
      env = ENV["SAMAGOTCHI_SESSION_MAX_COUNT"]
      return env.to_i if env && !env.strip.empty?
      Session::DEFAULT_MAX_COUNT
    end

    private_class_method def self.resolve_retention_keep_status(val)
      raw = if !val.nil? && val.to_s.strip != ""
              val.to_s
            else
              cfg = begin Samagotchi::Config.get("session.keep_status") rescue nil end
              cfg && !cfg.to_s.strip.empty? ? cfg.to_s : (ENV["SAMAGOTCHI_SESSION_KEEP_STATUS"] || ENV["SAMAGOTCHI_SESSION_RETENTION_KEEP_STATUS"])
            end
      return Session::DEFAULT_KEEP_STATUS if raw.nil? || raw.strip.empty?
      raw.split(",").map(&:strip).reject(&:empty?)
    end

    # Ensure an existing session has a live worker process.
    # Returns the loaded session after state reconciliation.
    # @raise [OwnedByTUI] when the interactive TUI owns the session
    def self.resume_session(session_id, state_dir: nil)
      sd = state_dir || Session.default_state_dir
      session = Session.load(session_id, state_dir: sd)
      owner = session_owner(session.id, state_dir: sd)
      raise OwnedByTUI, session.id if owner && owner["kind"] == "tui"
      return session if owner

      # status is turn state, not liveness: a new worker runs no turn yet,
      # and must not find the session stopped (it would exit).
      session.status = Session::STATUS_IDLE
      session.save(state_dir: sd)
      spawn_worker_for_session(session, state_dir: sd)
      session
    end

    # Read any new output files from a session directory.
    # Optionally filters to only files newer than `since_time`.
    def self.read_responses(session_id, since_time: nil, state_dir: nil)
      session_dir = Session.session_dir(session_id, state_dir: state_dir || Session.default_state_dir)
      output_path = File.join(session_dir, OUTPUT_DIR)
      responses = []
      return responses unless Dir.exist?(output_path)

      Dir.glob(File.join(output_path, "*.txt")).sort.each do |f|
        if since_time.nil? || File.mtime(f) > since_time
          responses << File.read(f)
        end
      end
      responses
    end

    # Stop a session by sending TERM to its process.
    # With +wait+ (seconds), also wait for the owner to let go of the session,
    # so a resume right after spawns a fresh worker instead of finding the
    # dying one.
    # @return [Boolean, nil] with +wait+: whether the owner was gone in time
    # @raise [OwnedByTUI] when the interactive TUI owns the session
    def self.stop_session(session_id, state_dir: nil, wait: nil)
      sd = state_dir || Session.default_state_dir
      owner = session_owner(session_id, state_dir: sd)
      raise OwnedByTUI, session_id if owner && owner["kind"] == "tui"

      # Mark first: a worker that has not taken the lock yet sees it and exits.
      Session.mark_stopped(session_id, state_dir: sd)
      pid = owner && owner["pid"].to_i
      begin
        Process.kill("TERM", pid) if pid && pid > 0
      rescue Errno::ESRCH
        nil # already exited
      end
      wait_for_owner_release(session_id, timeout: wait, state_dir: sd) if wait
    end

    # What a session's directory holds before anything happened in it. Any
    # other entry (or a file in one of the EMPTY_DIRS) is something the
    # session keeps.
    EMPTY_SKELETON_FILES = %w[pid owner.lock bridge.json analytics.json].freeze
    EMPTY_DIRS = [INPUT_DIR, NOTES_DIR, "images"].freeze
    EMPTY_SKELETON_DIRS = (EMPTY_DIRS + [OUTPUT_DIR]).freeze

    # session.keep_empty off: sessions left with nothing in them are deleted
    # (the worker as it exits, the TUI at /exit, the retention sweep).
    def self.discard_empty?
      Samagotchi::Config.get("session.keep_empty") != true
    rescue StandardError
      false
    end

    # A session nothing happened in: no conversation, no turn tried (a failed
    # one leaves no messages but a last_prompt and analytics turns), nothing
    # queued or attached, and the model and mode a new session gets. A
    # session prepared for later (/model, --model, a note, an image, memory)
    # is not empty. Anything unreadable or unknown counts as not empty.
    # @param default_model [String, nil] what a new session starts on
    def self.empty_session?(session_id, state_dir: nil, default_model: nil)
      sd = state_dir || Session.default_state_dir
      session = Session.load(session_id, state_dir: sd)
      return false unless no_conversation?(session.messages) && session.pending_question.nil? && session.used_memory_names.empty?
      return false unless session.last_prompt.to_s.strip.empty? && session.first_preview.to_s.strip.empty?
      return false unless session.mode.to_s == "assist" && !default_model.nil? && session.model_name.to_s == default_model.to_s

      empty_session_dir?(Session.session_dir(session_id, state_dir: sd))
    rescue ArgumentError, SystemCallError, JSON::ParserError
      false
    end

    # Only the system prompt (the REPL seeds one, a saved session keeps
    # it); a context note is a system message too, but with its kind.
    def self.no_conversation?(messages)
      Array(messages).all? do |msg|
        (msg[:role] || msg["role"]).to_s == "system" && (msg[:kind] || msg["kind"]).nil?
      end
    end

    # @return [Boolean] whether a session's directory holds only the skeleton
    def self.empty_session_dir?(dir)
      return true unless Dir.exist?(dir)

      Dir.children(dir).all? do |name|
        path = File.join(dir, name)
        if EMPTY_SKELETON_DIRS.include?(name)
          File.directory?(path) && (!EMPTY_DIRS.include?(name) || Dir.children(path).empty?)
        elsif name == "analytics.json"
          JSON.parse(File.read(path))["turns"].to_i.zero?
        else
          EMPTY_SKELETON_FILES.include?(name)
        end
      end
    end

    # Delete one session: its <id>.json and the whole <id>/ directory
    # (history sidecars, input, output, notes, images). The CLI, the TUI's
    # /exit --delete and the web all come here.
    # @param id_or_prefix [String] a session id or a unique prefix of one
    # @param stop [Boolean] stop a live worker first (waits +wait+ seconds)
    # @return [Hash] {id:, removed: [paths], stopped: whether a worker was stopped}
    # @raise [ArgumentError] unknown id (Session::AmbiguousId for a prefix of several)
    # @raise [OwnedByTUI] a chi REPL owns it (never stopped from here)
    # @raise [DeleteRefused] a worker owns it and +stop+ is false, or it
    #   outlived the wait
    def self.delete_session(id_or_prefix, state_dir: nil, stop: false, wait: 10)
      sd = state_dir || Session.default_state_dir
      given = id_or_prefix.to_s
      # Only a plain id: anything else could name a path outside the state dir.
      raise ArgumentError, "no session #{given}" unless given.match?(/\A[\w-]+\z/)

      id = Session.resolve_id(given, state_dir: sd)
      path = File.join(sd, "#{id}#{Session::FILE_EXT}")
      dir = Session.session_dir(id, state_dir: sd)
      raise ArgumentError, "no session #{given}" unless File.exist?(path) || Dir.exist?(dir)

      owner = session_owner(id, state_dir: sd)
      if owner
        raise OwnedByTUI, id if owner["kind"] == "tui"
        raise DeleteRefused.new(id, :worker_running) unless stop
        raise DeleteRefused.new(id, :still_stopping) unless stop_session(id, state_dir: sd, wait: wait)
      end

      removed = []
      if File.exist?(path)
        FileUtils.rm_f(path)
        removed << path
      end
      if Dir.exist?(dir)
        FileUtils.rm_rf(dir)
        removed << dir
      end
      { id: id, removed: removed, stopped: !owner.nil? }
    end

    # @return [Boolean] whether the session had no owner within +timeout+ seconds
    def self.wait_for_owner_release(session_id, timeout:, state_dir:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout.to_f
      while session_owner(session_id, state_dir: state_dir)
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep(OwnerLock::RETRY_INTERVAL)
      end
      true
    end

    # Wait for a session to reach a terminal state (completed, error, stopped).
    # Returns true if the session finished, false if the timeout elapsed.
    def self.wait_for_session(session_id, timeout: 30, state_dir: nil)
      sd = state_dir || Session.default_state_dir
      elapsed = 0
      while elapsed < timeout
        session = Session.load(session_id, state_dir: sd)
        return true if %w[completed error stopped].include?(session.status)

        sleep(0.5)
        elapsed += 0.5
      end
      false
    end

    # Run the session loop inside the forked process.
    # This is the entry point called by Process.spawn.
    #
    # Every worker starts its per-session Bridge (the single live client
    # transport) on a port bound to 127.0.0.1 before the loop and stops it on
    # exit. If the bridge fails to start the worker degrades: turns still flow
    # through the input-dir loop, but there is no live SSE or in-process
    # cancel/answer.
    #
    # The worker first takes the session's OwnerLock; when another owner holds
    # it (a racing resume spawned two workers, or the TUI has the session) it
    # exits quietly.
    #
    # A worker nobody uses returns once session.idle_exit_minutes have passed
    # (see WorkerIdleExit), and one a client asked to exit (Bridge POST /exit)
    # returns as soon as nothing keeps it. The next send wakes a new one.
    # @param idle_exit_minutes [Numeric, nil] nil: session.idle_exit_minutes
    # @param poll_interval [Numeric, nil] seconds between the loop's fallback
    #   ticks (nil: Worker::FALLBACK_TICK_SECONDS); queued turns wake it at once
    # @return [Symbol] :idle_exit or :exit_requested
    def self.run_session_loop(session_id, state_dir: nil, owner_wait: OwnerLock::DEFAULT_WAIT,
                              idle_exit_minutes: nil, poll_interval: nil)
      sd = state_dir || Session.default_state_dir
      # The spawner passed the file and level through ENV; a worker's stderr
      # is /dev/null, so warnings only reach the file.
      Log.configure(stderr: false)
      Log.session_id = session_id
      session_dir = Session.session_dir(session_id, state_dir: sd)
      # Kept in a class ivar so the lock's File lives as long as the worker.
      @owner_lock = OwnerLock.acquire(session_dir, kind: "worker", wait: owner_wait)
      exit(0) unless @owner_lock
      Log.info(:worker, "start", cwd: Dir.pwd)
      worker = Worker.new(session_id: session_id, state_dir: sd, session_dir: session_dir,
                          idle_exit_minutes: idle_exit_minutes, poll_interval: poll_interval)
      result = begin
        File.write(File.join(session_dir, PID_FILE), Process.pid.to_s)
        worker.run
      rescue StandardError, ScriptError => e
        # The worker's stderr is /dev/null: the log is the only trace.
        Log.exception(:worker, "crashed", e)
        raise
      ensure
        @owner_lock.release
      end
      Log.info(:worker, "stop", reason: result)
      # Only after the release: a writer that still saw this worker as the
      # owner may have queued input since the last check. Either it finds no
      # owner after its write and wakes one, or this finds its input.
      if %i[idle_exit exit_requested].include?(result) && !find_new_input_files(session_dir).empty?
        resume_session(session_id, state_dir: sd)
      elsif worker.discard?
        discard_left_session(session_id, state_dir: sd, default_model: worker.default_model)
      end
      result
    end

    # Delete a session its worker left empty. Checked again now the lock is
    # free: a note or input may have come in since the worker looked, and a
    # worker woken meanwhile owns it (delete_session refuses). A `chi send`
    # landing between this check and the delete fails with "no session"
    # (a window of an empty session's last moments, left as is).
    private_class_method def self.discard_left_session(session_id, state_dir:, default_model:)
      return unless empty_session?(session_id, state_dir: state_dir, default_model: default_model)

      delete_session(session_id, state_dir: state_dir)
      Log.info(:worker, "discarded_empty", sid: session_id)
    rescue DeleteRefused, OwnedByTUI, ArgumentError, SystemCallError => e
      Log.info(:worker, "kept_session", sid: session_id, error: e.class.name, msg: e.message)
    end

    def self.config_idle_exit_minutes
      Samagotchi::Config.get("session.idle_exit_minutes")
    rescue StandardError
      nil
    end

    private_class_method def self.setup_session_directory(session_dir, session, state_dir:)
      FileUtils.mkdir_p(session_dir)
      FileUtils.mkdir_p(File.join(session_dir, INPUT_DIR))
      FileUtils.mkdir_p(File.join(session_dir, OUTPUT_DIR))
      session.save(state_dir: state_dir)
    end

    private_class_method def self.spawn_worker_for_session(session, state_dir:)
      session_dir = Session.session_dir(session.id, state_dir: state_dir)
      FileUtils.mkdir_p(session_dir)
      FileUtils.mkdir_p(File.join(session_dir, INPUT_DIR))
      FileUtils.mkdir_p(File.join(session_dir, OUTPUT_DIR))

      lib_path = File.expand_path("..", __dir__)
      opts = spawn_options(session)
      env = opts.delete(:env)
      command = [
        RbConfig.ruby,
        "-I", lib_path,
        "-e", "require 'samagotchi/session_manager'; Samagotchi::SessionManager.run_session_loop('#{session.id}', state_dir: #{state_dir.inspect})"
      ]
      # The worker writes the pid file itself once it owns the session.
      pid = env ? Process.spawn(env, *command, **opts) : Process.spawn(*command, **opts)
      Log.info(:worker, "spawn", sid: session.id, child_pid: pid)
      pid
    end

    # Start the in-process Bridge transport for this worker. The bridge is
    # the single live client transport, so every worker starts it. Bridge
    # creation happens *before* the loop so the capture observer is in place
    # for the whole session; the caller stops the returned instance on exit
    # (see Worker#run's ensure).
    #
    # @return [Samagotchi::Bridge, nil] nil when the transport failed to start
    #   (the worker degrades: turns still flow through the input-dir loop, but
    #   there is no live SSE or in-process cancel/answer).
    # @param on_input [#call, nil] called after the Bridge queues a turn
    def self.start_bridge(engine:, state_dir:, session_id:, on_input: nil, on_command: nil, on_exit_request: nil,
                          exit_discards: nil)
      require_relative "bridge"
      Samagotchi::Bridge.new(
        engine: engine, state_dir: state_dir, session_id: session_id, input_format: INPUT_FORMAT,
        on_input: on_input, on_command: on_command, on_exit_request: on_exit_request, exit_discards: exit_discards
      ).start
    rescue StandardError => e
      Log.error(:bridge, "start_failed", echo: "Bridge: failed to start for session #{session_id}: #{e.class}: #{e.message}", sid: session_id, error: e.class.name)
      nil
    end



    # Write a user turn into a session's input directory via the same file IPC
    # the worker polls. Reused by the bridge's POST surface so a turn is
    # fire-and-forget and never calls run_turn across the thread/process
    # boundary. The file is JSON carrying the sender's ids, unless the
    # session's live worker predates structured input (plain text then).
    # @param client_id [String, nil] the sending UI
    # @param enqueued_id [String, nil] the id its ACK / :turn_enqueued carry
    # @param images [Array<Hash>] image refs ({file:, name:}) in the
    #   session's images/ (raises ImagesUnsupported for an older worker)
    # @return [String, false] the input file's path, or false.
    def self.write_turn_input(session_id, prompt:, client_id: nil, enqueued_id: nil, no_interrupt: false, state_dir: nil,
                              images: [])
      sd = state_dir || Session.default_state_dir
      session_dir = Session.session_dir(session_id, state_dir: sd)
      images = Array(images)
      raise ImagesUnsupported if !images.empty? && !images_input?(session_dir)

      write_input_file(session_dir, prompt, client_id, enqueued_id, no_interrupt, images)
    end

    # How long a turn waits for the Bridge of a worker a resume just spawned.
    TURN_BRIDGE_WAIT = 5.0

    # Hand a user message to the session the way a UI does, for the web
    # composer and `chi send` alike: wakes the worker when none runs, posts
    # through its Bridge so every live UI sees :turn_enqueued, and falls back
    # to the input file when the Bridge is gone (a worker closing it on idle
    # exit). Race-safe against a TUI taking the session, or the worker
    # exiting, between the resume and the write.
    # @param images [Array<Hash>] refs ({file:, name:}) already in images/
    # @param manager [#resume_session, #write_turn_input] this class, or a
    #   stand-in (the web's specs); #session_owner is optional
    # @param bridge [#call, nil] returns the BridgeClient or nil; defaults to
    #   the session's sidecar, waiting TURN_BRIDGE_WAIT for a new worker's
    # @return [Hash] {status: :accepted, ack: Hash} (the Bridge's reply, or
    #   {status:, enqueued_id:, session_id:} for a file), {status: :refused,
    #   code:, ack:} when the Bridge refused the images, or {status: :failed}
    #   when the input file couldn't be written
    # @raise [OwnedByTUI] a chi REPL owns the session
    # @raise [ImagesUnsupported] images for a worker that predates them
    # @raise [ArgumentError] no such session
    def self.deliver_turn(session_id, prompt:, client_id: nil, images: [], state_dir: nil, manager: self, bridge: nil)
      session_dir = Session.session_dir(session_id, state_dir: state_dir || Session.default_state_dir)
      bridge ||= -> { BridgeClient.wait_for(session_id, session_dir: session_dir, timeout: TURN_BRIDGE_WAIT) }
      manager.resume_session(session_id, state_dir: state_dir) if manager.respond_to?(:resume_session)
      # A worker that predates images would drop them (its Bridge ignores
      # them): refuse, so the sender keeps the chips and the text.
      raise ImagesUnsupported if images.any? && !images_input?(session_dir)

      if (client = bridge.call)
        begin
          options = { prompt: prompt, client_id: client_id }
          options[:images] = images unless images.empty?
          reply = client.post_turn(**options)
          ack = reply.json
          return { status: :accepted, ack: ack } if reply.status == 202 && ack.is_a?(Hash)
          if ack.is_a?(Hash) && %w[bad_images images_unsupported].include?(ack["error"])
            return { status: :refused, code: reply.status, ack: ack }
          end
        rescue SystemCallError, IOError
          nil # the worker closed its Bridge on the way out: queue the file
        end
      end
      enqueued_id = SecureRandom.uuid
      input = { prompt: prompt, client_id: client_id, enqueued_id: enqueued_id, state_dir: state_dir }
      input[:images] = images unless images.empty?
      path = manager.write_turn_input(session_id, **input)
      return { status: :failed } unless path

      owner = delivery_owner(manager, session_id, state_dir)
      # A TUI that took the session between the resume and the write never
      # reads input files; a later worker would replay this one.
      if owner&.fetch("kind", nil) == "tui"
        FileUtils.rm_f(path) if path.is_a?(String)
        raise OwnedByTUI, session_id
      end
      # A worker that idle-exited since the resume never reads it either:
      # wake a new one. (The exiting worker also looks for input it left.)
      if owner.nil? && manager.respond_to?(:session_owner) && manager.respond_to?(:resume_session)
        manager.resume_session(session_id, state_dir: state_dir)
      end
      { status: :accepted, ack: { status: "accepted", enqueued_id: enqueued_id, session_id: session_id } }
    end

    private_class_method def self.delivery_owner(manager, session_id, state_dir)
      return nil unless manager.respond_to?(:session_owner)

      manager.session_owner(session_id, state_dir: state_dir)
    rescue StandardError
      nil
    end

    private_class_method def self.write_input_file(session_dir, prompt, client_id, enqueued_id, no_interrupt, images)
      input_dir = File.join(session_dir, INPUT_DIR)
      FileUtils.mkdir_p(input_dir)

      timestamp = Time.now.strftime("%Y%m%d%H%M%S%9N")
      if structured_input?(session_dir)
        path = File.join(input_dir, "#{timestamp}.json")
        record = { "prompt" => prompt.to_s, "client_id" => client_id, "enqueued_id" => enqueued_id,
                   "no_interrupt" => (no_interrupt ? true : nil),
                   "images" => (images.empty? ? nil : images.map { |image| image.transform_keys(&:to_s) }) }.compact
        write_atomic(path, JSON.generate(record))
      else
        path = File.join(input_dir, "#{timestamp}.txt")
        write_atomic(path, prompt.to_s)
      end
      path
    rescue StandardError
      false
    end

    # Queue a context note for a session: background text its worker adds
    # to the conversation between turns. It never starts a turn.
    # @param source [String] where it came from ("cli", "slack", "session")
    # @param from_session [String, nil] the sending session, for a peer's note
    # @return [String] the note file's path
    # @raise [NoteRejected] for an empty note or one over 16 KiB (never cut)
    def self.write_note(session_id, text:, source: "cli", from_session: nil, from_cwd: nil, state_dir: nil)
      body = checked_text(text)
      sd = state_dir || Session.default_state_dir
      notes_dir = File.join(Session.session_dir(session_id, state_dir: sd), NOTES_DIR)
      FileUtils.mkdir_p(notes_dir)

      # The random part keeps two writers in one nanosecond apart; the
      # timestamp keeps the names in arrival order.
      name = "#{Time.now.strftime("%Y%m%d%H%M%S%9N")}-#{SecureRandom.hex(3)}.json"
      path = File.join(notes_dir, name)
      record = { "text" => body, "source" => source.to_s, "from_session" => from_session,
                 "from_cwd" => from_cwd, "created_at" => Time.now.iso8601 }.compact
      write_atomic(path, JSON.generate(record))
      path
    end

    # The same empty and 16 KiB checks for a note and a sent message.
    # @param noun [String] what the errors call the text
    # @return [String] the stripped text
    # @raise [NoteRejected]
    def self.checked_text(text, noun: "note")
      body = text.to_s.strip
      raise NoteRejected, "the #{noun} is empty" if body.empty?
      if body.bytesize > NOTE_MAX_BYTES
        raise NoteRejected, "the #{noun} is #{body.bytesize} bytes; the limit is 16 KiB (#{NOTE_MAX_BYTES} bytes)"
      end

      body
    end

    # Queued notes, oldest first, plus any a crashed worker claimed and left
    # (the absorber skips a note id the conversation already holds).
    def self.find_new_note_files(session_dir)
      notes_dir = File.join(session_dir, NOTES_DIR)
      return [] unless Dir.exist?(notes_dir)

      Dir.glob(File.join(notes_dir, "*.{json,json.processing}")).sort_by { |p| File.basename(p) }
    end

    # @return [String, nil] the claimed path, or nil when another claimed it
    def self.claim_note_file(note_file)
      return note_file if note_file.end_with?(".processing")

      claim_input_file(note_file)
    end

    # @return [Hash, nil] {note_id:, text:, source:, from_session:, from_cwd:,
    #   created_at:}, or nil for a file that holds no usable note
    def self.read_note(note_file)
      data = JSON.parse(File.read(note_file))
      text = data["text"].to_s.strip
      return nil if text.empty?

      { note_id: File.basename(note_file).sub(/\.json(\.processing)?\z/, ""), text: text,
        source: data["source"].to_s.empty? ? "cli" : data["source"].to_s,
        from_session: data["from_session"], from_cwd: data["from_cwd"], created_at: data["created_at"] }
    rescue JSON::ParserError, SystemCallError, NoMethodError, TypeError
      nil
    end

    def self.write_output(session_dir, response)
      output_dir = File.join(session_dir, OUTPUT_DIR)
      FileUtils.mkdir_p(output_dir)
      timestamp = Time.now.strftime("%Y%m%d%H%M%S%9N")
      write_atomic(File.join(output_dir, "#{timestamp}.txt"), response.to_s)
    end

    def self.find_new_input_files(session_dir)
      input_dir = File.join(session_dir, INPUT_DIR)
      return [] unless Dir.exist?(input_dir)

      Dir.glob(File.join(input_dir, "*.{txt,json}"))
    end

    # A worker's sidecar advertises the input format it reads; no sidecar
    # means no worker yet, and the next one (this code) reads JSON.
    private_class_method def self.structured_input?(session_dir)
      worker_input_format(session_dir) >= STRUCTURED_INPUT_FORMAT
    end

    # Whether the session's worker (or the next one) reads images: refs.
    def self.images_input?(session_dir)
      worker_input_format(session_dir) >= IMAGES_INPUT_FORMAT
    end

    # The input format the session's worker advertises; no sidecar means no
    # worker yet, and the next one (this code) reads INPUT_FORMAT.
    private_class_method def self.worker_input_format(session_dir)
      sidecar = File.join(session_dir, "bridge.json")
      return INPUT_FORMAT unless File.file?(sidecar)

      JSON.parse(File.read(sidecar))["input_format"].to_i
    rescue JSON::ParserError, SystemCallError
      INPUT_FORMAT
    end

    # @return [Array(String, Hash|nil, Boolean, Array<Hash>)] a claimed input
    #   file's prompt, origin ({client_id:, enqueued_id:}, nil for plain
    #   text), whether its turn runs with the raised iteration limit
    #   (--no-interrupt), and its image refs ({file:, name:})
    def self.read_input(claimed_file)
      raw = File.read(claimed_file).to_s
      return [raw, nil, false, []] unless claimed_file.end_with?(".json.processing")

      data = JSON.parse(raw)
      origin = { client_id: data["client_id"], enqueued_id: data["enqueued_id"] }.compact
      images = Array(data["images"]).select { |image| image.is_a?(Hash) }.map { |image| image.transform_keys(&:to_sym) }
      [data["prompt"].to_s, origin.empty? ? nil : origin, data["no_interrupt"] == true, images]
    rescue JSON::ParserError
      [nil, nil, false, []]
    end

    # Whether an unclaimed input file carries images (a mid-turn drain
    # leaves it for its own turn).
    def self.input_has_images?(input_file)
      return false unless input_file.end_with?(".json")

      data = JSON.parse(File.read(input_file))
      data.is_a?(Hash) && Array(data["images"]).any?
    rescue JSON::ParserError, SystemCallError
      false
    end

    def self.claim_input_file(input_file)
      processing_path = "#{input_file}.processing"
      File.rename(input_file, processing_path)
      processing_path
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def self.stopped_on_disk?(session_id, state_dir:)
      Session.load(session_id, state_dir: state_dir).status == Session::STATUS_STOPPED
    rescue ArgumentError
      false
    end

    private_class_method def self.write_atomic(path, content)
      temp_path = "#{path}.tmp"
      File.write(temp_path, content)
      File.rename(temp_path, path)
    end

    # The session's live owner: the OwnerLock holder, or a live pid-only
    # worker started before the lock existed (such workers never exit).
    # @return [Hash, nil] {"pid", "kind" ("worker"/"tui"), ...} or nil
    def self.session_owner(session_id, state_dir: nil)
      session_dir = Session.session_dir(session_id, state_dir: state_dir || Session.default_state_dir)
      return OwnerLock.owner(session_dir) if OwnerLock.lock_file?(session_dir)

      pid = legacy_worker_pid(session_dir)
      pid && { "pid" => pid, "kind" => "worker" }
    end

    private_class_method def self.worker_alive_for_session?(session_id, state_dir:)
      !session_owner(session_id, state_dir: state_dir).nil?
    end

    private_class_method def self.legacy_worker_pid(session_dir)
      pid_file = File.join(session_dir, PID_FILE)
      return nil unless File.exist?(pid_file)

      pid = File.read(pid_file).strip.to_i
      return nil if pid <= 0

      Process.kill(0, pid)
      pid
    rescue Errno::EPERM
      pid
    rescue Errno::ESRCH
      nil
    end
  end
end

