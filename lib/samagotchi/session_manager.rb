
# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "securerandom"
require "rbconfig"

require_relative "session"
require_relative "terminal_ui"

module Samagotchi
  # SessionManager coordinates background session processes.
  #
  # Each session runs in its own forked Ruby process, communicating via
  # file-based IPC in the session directory.
  #
  # Directory layout per session:
  #   ~/.local/state/samagotchi/sessions/<session_id>/
  #   ├── session.json          # session metadata
  #   ├── input/                # clients (web/terminal UI) write messages here
  #   │   └── <timestamp>.txt   # one file per user message
  #   ├── output/               # agent writes responses here
  #   │   └── <timestamp>.txt   # one file per agent response
  #   └── pid                   # PID of the session process
  class SessionManager
    INPUT_DIR  = "input"
    OUTPUT_DIR = "output"
    PID_FILE   = "pid"
    SESSION_JSON = "session.json"

    # Spawn a new background session that processes the given prompt.
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
      session.status = Session::STATUS_RUNNING
      session.last_prompt = prompt
      session_dir = Session.session_dir(session.id, state_dir: sd)
      setup_session_directory(session_dir, session, state_dir: sd)

      lib_path = File.expand_path("..", __dir__)
      opts = spawn_options
      env = opts.delete(:env)
      pid = if env
              Process.spawn(
                env,
                RbConfig.ruby,
                "-I", lib_path,
                "-e", "require 'samagotchi/session_manager'; Samagotchi::SessionManager.run_session_loop('#{session.id}', state_dir: #{sd.inspect})",
                **opts
              )
            else
              Process.spawn(
                RbConfig.ruby,
                "-I", lib_path,
                "-e", "require 'samagotchi/session_manager'; Samagotchi::SessionManager.run_session_loop('#{session.id}', state_dir: #{sd.inspect})",
                **opts
              )
            end

      File.write(File.join(session_dir, PID_FILE), pid.to_s)
      session
    end

    # Build the opts hash passed to Process.spawn for a forked worker. Setting
    # opts[:env] REPLACES the child ENV rather than merging it, so explicitly
    # thread through the values a worker needs (backend, hosts, default model).
    private_class_method def self.spawn_options
      opts = { out: File::NULL, err: File::NULL }
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
    def self.resume_session(session_id, state_dir: nil)
      sd = state_dir || Session.default_state_dir
      session = Session.load(session_id, state_dir: sd)
      return session if worker_alive_for_session?(session.id, state_dir: sd)

      session.status = Session::STATUS_RUNNING
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
    def self.stop_session(session_id, state_dir: nil)
      sd = state_dir || Session.default_state_dir
      session_dir = Session.session_dir(session_id, state_dir: sd)
      pid_file = File.join(session_dir, PID_FILE)

      if File.exist?(pid_file)
        pid = File.read(pid_file).strip.to_i
        Process.kill("TERM", pid) if pid > 0
      end

      Session.mark_stopped(session_id, state_dir: sd)
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
    def self.run_session_loop(session_id, state_dir: nil)
      sd = state_dir || Session.default_state_dir
      session = Session.load(session_id, state_dir: sd)
      session_dir = Session.session_dir(session_id, state_dir: sd)
      engine = Samagotchi::Engine.new(
        mode: session.mode.to_sym,
        model_name: session.model_name,
        reminders: {
          callback: lambda { |due_names|
            # SessionManager: when a reminder is due, write a synthetic input
            # file via write_turn_input so the existing poll loop picks it up.
            self.class.write_turn_input(session_id, prompt: "[SYSTEM: Your scheduled reminders are due. Please check them.]")
          }
        }
      )
      # Start the shared idle scheduler so the worker can trigger turns when
      # reminders are due (even with no user input).
      engine.start_idle

      bridge_instance = start_bridge(engine:, state_dir: sd, session_id: session_id)

      begin
        # Process the initial prompt
        unless session.last_prompt.to_s.strip.empty?
          prompt = session.last_prompt
          session.last_prompt = ""
          session.save(state_dir: sd)

          result = engine.run_turn(session, prompt)
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
            sleep(1)
            next
          end

          input_files.sort.each do |input_file|
            claimed_file = claim_input_file(input_file)
            next unless claimed_file

            begin
              message = File.read(claimed_file).to_s
              next if message.strip.empty?

              result = engine.run_turn(session, message)
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
      pid = if env
              Process.spawn(
                env,
                RbConfig.ruby,
                "-I", lib_path,
                "-e", "require 'samagotchi/session_manager'; Samagotchi::SessionManager.run_session_loop('#{session.id}', state_dir: #{state_dir.inspect})",
                **opts
              )
            else
              Process.spawn(
                RbConfig.ruby,
                "-I", lib_path,
                "-e", "require 'samagotchi/session_manager'; Samagotchi::SessionManager.run_session_loop('#{session.id}', state_dir: #{state_dir.inspect})",
                **opts
              )
            end
      File.write(File.join(session_dir, PID_FILE), pid.to_s)
      pid
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
        engine: engine, state_dir: state_dir, session_id: session_id
      ).start
    rescue StandardError => e
      warn "Bridge: failed to start for session #{session_id}: #{e.class}: #{e.message}"
      nil
    end



    # Write a user turn into a session's input directory via the same file IPC
    # the worker polls. Reused by the bridge's POST surface so a turn is
    # fire-and-forget and never calls run_turn across the thread/process
    # boundary. @return [Boolean] true on success.
    def self.write_turn_input(session_id, prompt:, state_dir: nil)
      sd = state_dir || Session.default_state_dir
      session_dir = Session.session_dir(session_id, state_dir: sd)
      input_dir = File.join(session_dir, INPUT_DIR)
      FileUtils.mkdir_p(input_dir)

      timestamp = Time.now.strftime("%Y%m%d%H%M%S%9N")
      write_atomic(File.join(input_dir, "#{timestamp}.txt"), prompt.to_s)
      true
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

      Dir.glob(File.join(input_dir, "*.txt"))
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

    private_class_method def self.worker_alive_for_session?(session_id, state_dir:)
      pid_file = File.join(Session.session_dir(session_id, state_dir: state_dir), PID_FILE)
      return false unless File.exist?(pid_file)

      pid = File.read(pid_file).strip.to_i
      return false if pid <= 0

      Process.kill(0, pid)
      true
    rescue Errno::EPERM
      true
    rescue Errno::ESRCH
      false
    end
  end
end

