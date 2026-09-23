
# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "securerandom"
require "rbconfig"

require_relative "session"
require_relative "owner_lock"
require_relative "worker_idle_exit"
require_relative "debug_log"
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
  #       ├── output/             # agent writes responses here
  #       │   └── <timestamp>.txt # one file per agent response
  #       ├── pid                 # PID of the owner, written by the owner itself
  #       └── bridge.json         # Bridge sidecar (how clients reach the worker)
  class SessionManager
    INPUT_DIR  = "input"
    OUTPUT_DIR = "output"
    PID_FILE   = "pid"
    # Input-file format this worker reads (JSON with the sender's ids, and
    # plain text). Advertised in the Bridge sidecar: a worker that doesn't
    # advertise it reads only .txt, and such workers never exit.
    INPUT_FORMAT = 2
    # Origin of the synthetic turn queued when reminders are due.
    REMINDER_CLIENT_ID = "system:reminder"

    # Raised when the interactive TUI owns the session: it runs its own Engine
    # and reads no input files, so a worker must not be spawned or signalled.
    class OwnedByTUI < StandardError
      def initialize(session_id)
        super("session #{session_id} is owned by an interactive TUI")
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
      session_dir = Session.session_dir(session.id, state_dir: sd)
      setup_session_directory(session_dir, session, state_dir: sd)
      spawn_worker_for_session(session, state_dir: sd)
      session
    end

    # Build the opts hash passed to Process.spawn for a forked worker. Setting
    # opts[:env] REPLACES the child ENV rather than merging it, so explicitly
    # thread through the values a worker needs (backend, hosts, default model).
    private_class_method def self.spawn_options
      # Own process group: workers outlive `chi web`, and a Ctrl-C in its
      # terminal must not reach them.
      opts = { out: File::NULL, err: File::NULL, pgroup: true }
      child_env = {}
      child_env["SAMAGOTCHI_BACKEND"] = ENV["SAMAGOTCHI_BACKEND"] if ENV["SAMAGOTCHI_BACKEND"]
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
      opts[:env] = child_env unless child_env.empty?
      opts
    end

    # List all sessions, reading status from persisted session.json files.
    def self.list_sessions(state_dir: nil, sort: "updated_at", order: "desc", limit: nil, offset: 0)
      Session.list(state_dir: state_dir || Session.default_state_dir, sort: sort, order: order, limit: limit, offset: offset)
    end

    # Prune sessions per retention policy. Delegates to Session.prune with live-worker guard.
    def self.prune_sessions(state_dir: nil, days: nil, max_count: nil, keep_status: nil, dry_run: false, test_only: false)
      sd = state_dir || Session.default_state_dir
      days = resolve_retention_days(days)
      max_count = resolve_retention_max_count(max_count)
      keep_status = resolve_retention_keep_status(keep_status)
      Session.prune(
        state_dir: sd,
        days: days,
        max_count: max_count,
        keep_status: keep_status,
        dry_run: dry_run,
        test_only: test_only,
        alive_check: ->(sid) { worker_alive_for_session?(sid, state_dir: sd) }
      )
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
        warn "[retention] pruned #{result[:deleted].size} sessions (kept #{result[:kept].size})"
      end
      result
    rescue StandardError => e
      warn "[retention] sweep failed: #{e.class}: #{e.message}"
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

    # Attach to a session: write a message to its input directory and read output.
    #
    # Returns an array of output lines from the session.
    def self.attach_session(session_id, message:, state_dir: nil)
      return [] if message.to_s.strip.empty?

      sd = state_dir || Session.default_state_dir
      resume_session(session_id, state_dir: sd)
      session_dir = Session.session_dir(session_id, state_dir: sd)
      input_path = File.join(session_dir, INPUT_DIR)
      FileUtils.mkdir_p(input_path)

      timestamp = Time.now.strftime("%Y%m%d%H%M%S%9N")
      input_file = File.join(input_path, "#{timestamp}.txt")
      write_atomic(input_file, message)

      output_path = File.join(session_dir, OUTPUT_DIR)
      responses = []
      sleep(0.1) # brief delay for the session process to process
      if Dir.exist?(output_path)
        Dir.glob(File.join(output_path, "*.txt")).sort.each do |f|
          # Only read files newer than the input file
          responses << File.read(f) if File.mtime(f) > File.mtime(input_file)
        end
      end
      responses
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
    # @raise [OwnedByTUI] when the interactive TUI owns the session
    def self.stop_session(session_id, state_dir: nil)
      sd = state_dir || Session.default_state_dir
      owner = session_owner(session_id, state_dir: sd)
      raise OwnedByTUI, session_id if owner && owner["kind"] == "tui"

      # Mark first: a worker that has not taken the lock yet sees it and exits.
      Session.mark_stopped(session_id, state_dir: sd)
      pid = owner && owner["pid"].to_i
      Process.kill("TERM", pid) if pid && pid > 0
    rescue Errno::ESRCH
      # Process already exited; still mark as stopped
      Session.mark_stopped(session_id, state_dir: sd)
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
    # (see WorkerIdleExit). The next send wakes a new one.
    # @param idle_exit_minutes [Numeric, nil] nil: session.idle_exit_minutes
    # @param poll_interval [Numeric] seconds between input polls
    # @return [Symbol] :idle_exit
    def self.run_session_loop(session_id, state_dir: nil, owner_wait: OwnerLock::DEFAULT_WAIT,
                              idle_exit_minutes: nil, poll_interval: 1)
      sd = state_dir || Session.default_state_dir
      session_dir = Session.session_dir(session_id, state_dir: sd)
      # Kept in a class ivar so the lock's File lives as long as the worker.
      @owner_lock = OwnerLock.acquire(session_dir, kind: "worker", wait: owner_wait)
      exit(0) unless @owner_lock
      result = begin
        File.write(File.join(session_dir, PID_FILE), Process.pid.to_s)
        run_owned_session_loop(session_id, state_dir: sd, session_dir: session_dir,
                                           idle_exit_minutes: idle_exit_minutes, poll_interval: poll_interval)
      ensure
        @owner_lock.release
      end
      # Only after the release: a writer that still saw this worker as the
      # owner may have queued input since the last check. Either it finds no
      # owner after its write and wakes one, or this finds its input.
      resume_session(session_id, state_dir: sd) if result == :idle_exit && !find_new_input_files(session_dir).empty?
      result
    end

    private_class_method def self.run_owned_session_loop(session_id, state_dir:, session_dir:,
                                                         idle_exit_minutes: nil, poll_interval: 1)
      sd = state_dir
      session = Session.load(session_id, state_dir: sd)
      engine = Samagotchi::Engine.new(
        mode: session.mode.to_sym,
        model_name: session.model_name,
        reminders: {
          callback: lambda { |due_names|
            # SessionManager: when a reminder is due, write a synthetic input
            # file via write_turn_input so the existing poll loop picks it up.
            # Called directly: `self` here is SessionManager itself, so the
            # old `self.class.write_turn_input` resolved to Class and raised
            # (swallowed by IdleScheduler, latching the reminder for good).
            write_turn_input(session_id, prompt: "[SYSTEM: Your scheduled reminders are due. Please check them.]",
                                         client_id: REMINDER_CLIENT_ID, state_dir: sd)
          }
        }
      )
      # Before the Bridge serves anything: a UI joining a resumed worker's
      # stream gets the session's history and status in its snapshot, not
      # an empty session until the first turn.
      engine.session = session
      # Start the shared idle scheduler so the worker can trigger turns when
      # reminders are due (even with no user input).
      engine.start_idle

      bridge_instance = start_bridge(engine:, state_dir: sd, session_id: session_id)
      idle_exit = WorkerIdleExit.new(
        engine: engine, bridge: bridge_instance,
        timeout_minutes: idle_exit_minutes || config_idle_exit_minutes,
        input_pending: -> { !find_new_input_files(session_dir).empty? }
      )

      begin
        # Shared mid-turn steering drain: claims any input files that arrive
        # while a turn is running and hands them to the agentic loop so
        # follow-ups merge at the next iteration boundary instead of waiting
        # for this outer 1s poll. claim_input_file is atomic (rename), so a
        # file consumed mid-turn simply fails the outer loop's later claim
        # with ENOENT → nil. No double-processing risk.
        #
        # Runs on the turn thread; it announces who sent the merged input so
        # every live UI can attribute it.
        pending_input_drain = lambda do
          merged = find_new_input_files(session_dir).sort.filter_map do |input_file|
            claimed_file = claim_input_file(input_file)
            next unless claimed_file

            begin
              prompt, origin = read_input(claimed_file)
              prompt = prompt.to_s.strip
              prompt.empty? ? nil : [prompt, origin]
            ensure
              FileUtils.rm_f(claimed_file)
            end
          end
          unless merged.empty?
            engine.announce(type: :input_merged, count: merged.size, origins: merged.filter_map(&:last))
          end
          merged.map(&:first)
        end

        # Process the initial prompt. spawn_session hands it over in
        # last_prompt, but last_prompt also records every later turn's prompt
        # (and mark_error's reason), so only a session with no conversation yet
        # has one pending; a resumed session must not replay its last turn.
        # Nor may a session stopped before this worker took the lock (e.g. a
        # stop right after create) run it.
        exit(0) if stopped_on_disk?(session_id, state_dir: sd)
        if session.messages.empty? && !session.last_prompt.to_s.strip.empty?
          prompt = session.last_prompt
          session.last_prompt = ""
          session.save(state_dir: sd)

          result = engine.run_turn(session, prompt, pending_input: pending_input_drain, origin: nil)
          response = result.respond_to?(:output) ? result.output : nil
          unless response.nil? || response.strip.empty?
            write_output(session_dir, response)
          end
          session.save(state_dir: sd) unless stopped_on_disk?(session_id, state_dir: sd)
        end

        # Poll for new input files
        loop do
          # Check if the session was externally marked as stopped
          session_from_disk = Session.load(session_id, state_dir: sd)
          if session_from_disk.status == Session::STATUS_STOPPED
            exit(0)
          end

          input_files = find_new_input_files(session_dir)
          if input_files.empty?
            return :idle_exit if idle_exit.due? && leave_idle(engine, bridge_instance, idle_exit)

            sleep(poll_interval)
            next
          end

          input_files.sort.each do |input_file|
            # A stop between two queued turns leaves the rest queued.
            break if stopped_on_disk?(session_id, state_dir: sd)

            claimed_file = claim_input_file(input_file)
            next unless claimed_file

            begin
              message, origin = read_input(claimed_file)
              next if message.to_s.strip.empty?

              # Show the turn as running to readers of the file (the web's
              # session list); the Engine resets it to idle when it ends.
              session.status = Session::STATUS_RUNNING
              session.save(state_dir: sd)
              result = engine.run_turn(session, message, pending_input: pending_input_drain, origin: origin)
              response = result.respond_to?(:output) ? result.output : nil
              unless response.nil? || response.strip.empty?
                write_output(session_dir, response)
              end
              session.save(state_dir: sd) unless stopped_on_disk?(session_id, state_dir: sd)
            ensure
              FileUtils.rm_f(claimed_file)
            end
          end
        end
      rescue StandardError => e
        Session.mark_error(session_id, reason: e.message, state_dir: sd)
        exit(1)
      ensure
        bridge_instance&.stop
      end
    end

    # Check again with the event log held, which the Bridge holds while it
    # queues a POST /turn, then close the Bridge so no client can queue one
    # after the check, and stop the idle jobs (reminder callback, recap).
    # A client connecting from here on finds no worker: `chi --attach` fails
    # and the web stream answers 503 (a small window, left as is).
    # @return [Boolean] false when something came in since #due?
    private_class_method def self.leave_idle(engine, bridge, idle_exit)
      engine.synchronize_events do
        next false unless idle_exit.due?

        bridge&.stop
        engine.stop_idle
        log_idle_exit(idle_exit)
        true
      end
    end

    private_class_method def self.config_idle_exit_minutes
      Samagotchi::Config.get("session.idle_exit_minutes")
    rescue StandardError
      nil
    end

    private_class_method def self.log_idle_exit(idle_exit)
      path = begin Samagotchi::Config.get("log.file") rescue nil end
      log = DebugLog.new(path: path)
      log.write("[worker] pid #{Process.pid} idle-exits after #{idle_exit.idle_seconds.round}s unused")
      log.close
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
      opts = spawn_options
      env = opts.delete(:env)
      command = [
        RbConfig.ruby,
        "-I", lib_path,
        "-e", "require 'samagotchi/session_manager'; Samagotchi::SessionManager.run_session_loop('#{session.id}', state_dir: #{state_dir.inspect})"
      ]
      # The worker writes the pid file itself once it owns the session.
      env ? Process.spawn(env, *command, **opts) : Process.spawn(*command, **opts)
    end

    # Start the in-process Bridge transport for this worker. The bridge is
    # the single live client transport, so every worker starts it. Bridge
    # creation happens *before* the loop so the capture observer is in place
    # for the whole session; the caller stops the returned instance on exit
    # (see run_session_loop's ensure).
    #
    # @return [Samagotchi::Bridge, nil] nil when the transport failed to start
    #   (the worker degrades: turns still flow through the input-dir loop, but
    #   there is no live SSE or in-process cancel/answer).
    private_class_method def self.start_bridge(engine:, state_dir:, session_id:)
      require_relative "bridge"
      Samagotchi::Bridge.new(
        engine: engine, state_dir: state_dir, session_id: session_id, input_format: INPUT_FORMAT
      ).start
    rescue StandardError => e
      warn "Bridge: failed to start for session #{session_id}: #{e.class}: #{e.message}"
      nil
    end



    # Write a user turn into a session's input directory via the same file IPC
    # the worker polls. Reused by the bridge's POST surface so a turn is
    # fire-and-forget and never calls run_turn across the thread/process
    # boundary. The file is JSON carrying the sender's ids, unless the
    # session's live worker predates structured input (plain text then).
    # @param client_id [String, nil] the sending UI
    # @param enqueued_id [String, nil] the id its ACK / :turn_enqueued carry
    # @return [String, false] the input file's path, or false.
    def self.write_turn_input(session_id, prompt:, client_id: nil, enqueued_id: nil, state_dir: nil)
      sd = state_dir || Session.default_state_dir
      session_dir = Session.session_dir(session_id, state_dir: sd)
      input_dir = File.join(session_dir, INPUT_DIR)
      FileUtils.mkdir_p(input_dir)

      timestamp = Time.now.strftime("%Y%m%d%H%M%S%9N")
      if structured_input?(session_dir)
        path = File.join(input_dir, "#{timestamp}.json")
        record = { "prompt" => prompt.to_s, "client_id" => client_id, "enqueued_id" => enqueued_id }.compact
        write_atomic(path, JSON.generate(record))
      else
        path = File.join(input_dir, "#{timestamp}.txt")
        write_atomic(path, prompt.to_s)
      end
      path
    rescue StandardError
      false
    end

    private_class_method def self.write_output(session_dir, response)
      output_dir = File.join(session_dir, OUTPUT_DIR)
      FileUtils.mkdir_p(output_dir)
      timestamp = Time.now.strftime("%Y%m%d%H%M%S%9N")
      write_atomic(File.join(output_dir, "#{timestamp}.txt"), response.to_s)
    end

    private_class_method def self.find_new_input_files(session_dir)
      input_dir = File.join(session_dir, INPUT_DIR)
      return [] unless Dir.exist?(input_dir)

      Dir.glob(File.join(input_dir, "*.{txt,json}"))
    end

    # A worker's sidecar advertises the input format it reads; no sidecar
    # means no worker yet, and the next one (this code) reads JSON.
    private_class_method def self.structured_input?(session_dir)
      sidecar = File.join(session_dir, "bridge.json")
      return true unless File.file?(sidecar)

      JSON.parse(File.read(sidecar))["input_format"].to_i >= INPUT_FORMAT
    rescue JSON::ParserError, SystemCallError
      true
    end

    # @return [Array(String, Hash|nil)] a claimed input file's prompt and
    #   origin ({client_id:, enqueued_id:}, nil for plain text)
    private_class_method def self.read_input(claimed_file)
      raw = File.read(claimed_file).to_s
      return [raw, nil] unless claimed_file.end_with?(".json.processing")

      data = JSON.parse(raw)
      origin = { client_id: data["client_id"], enqueued_id: data["enqueued_id"] }.compact
      [data["prompt"].to_s, origin.empty? ? nil : origin]
    rescue JSON::ParserError
      [nil, nil]
    end

    private_class_method def self.claim_input_file(input_file)
      processing_path = "#{input_file}.processing"
      File.rename(input_file, processing_path)
      processing_path
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    private_class_method def self.stopped_on_disk?(session_id, state_dir:)
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

