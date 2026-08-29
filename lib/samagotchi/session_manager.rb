
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
  #   ├── input/                # dashboard writes messages here
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
    # Returns the session object with its ID. When +bridge:+ is true the worker
    # is launched with the SSE/HTTP transport opt-in (an env var threaded
    # through Process.spawn) so an external client can reach it.
    def self.spawn_session(prompt:, mode: "assist", working_directory: nil, model_name: nil, state_dir: nil, bridge: false)
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
      opts = spawn_options(bridge: bridge)
      pid = Process.spawn(
        RbConfig.ruby,
        "-I", lib_path,
        "-e", "require 'samagotchi/session_manager'; Samagotchi::SessionManager.run_session_loop('#{session.id}', state_dir: #{sd.inspect})",
        **opts
      )

      File.write(File.join(session_dir, PID_FILE), pid.to_s)
      session
    end

    # Build the opts hash passed to Process.spawn for a forked worker. Without an
    # explicit opts[:env], Process.spawn inherits the parent's ENV verbatim; but
    # setting opts[:env] REPLACES the child ENV — so the bridge path (which set
    # SAMAGOTCHI_ENABLE_BRIDGE) would silently drop SAMAGOTCHI_BACKEND. Merge both
    # here so a bridge worker still honors the selected backend (Phase 4).
    private_class_method def self.spawn_options(bridge:)
      opts = { out: File::NULL, err: File::NULL }
      child_env = {}
      child_env["SAMAGOTCHI_ENABLE_BRIDGE"] = "1" if bridge
      child_env["SAMAGOTCHI_BACKEND"] = ENV["SAMAGOTCHI_BACKEND"] if ENV["SAMAGOTCHI_BACKEND"]
      opts[:env] = child_env unless child_env.empty?
      opts
    end

    # List all sessions, reading status from persisted session.json files.
    def self.list_sessions(state_dir: nil)
      Session.list(state_dir: state_dir || Session.default_state_dir)
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
    # When the bridge is enabled (opt-in via the +bridge:+ keyword or the
    # SAMAGOTCHI_ENABLE_BRIDGE env var threaded through Process.spawn) an
    # in-process SSE/HTTP transport is started on a per-session port bound to
    # 127.0.0.1 before the loop and stopped on exit. Never changes default
    # behaviour: the bridge is off unless explicitly engaged.
    def self.run_session_loop(session_id, state_dir: nil, bridge: nil)
      sd = state_dir || Session.default_state_dir
      session = Session.load(session_id, state_dir: sd)
      session_dir = Session.session_dir(session_id, state_dir: sd)
      engine = Samagotchi::Engine.new(mode: session.mode.to_sym, model_name: session.model_name)

      bridge_instance = start_bridge_if_enabled(
        engine:, state_dir: sd, session_id: session_id, enabled: bridge
      )

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

    private_class_method def self.spawn_worker_for_session(session, state_dir:, bridge: false)
      session_dir = Session.session_dir(session.id, state_dir: state_dir)
      FileUtils.mkdir_p(session_dir)
      FileUtils.mkdir_p(File.join(session_dir, INPUT_DIR))
      FileUtils.mkdir_p(File.join(session_dir, OUTPUT_DIR))

      lib_path = File.expand_path("..", __dir__)
      opts = spawn_options(bridge: bridge)
      pid = Process.spawn(
        RbConfig.ruby,
        "-I", lib_path,
        "-e", "require 'samagotchi/session_manager'; Samagotchi::SessionManager.run_session_loop('#{session.id}', state_dir: #{state_dir.inspect})",
        **opts
      )
      File.write(File.join(session_dir, PID_FILE), pid.to_s)
      pid
    end

    # Start an in-process bridge/transport for this worker when enabled.
    #
    # Opt-in via the +bridge:+ keyword (preferred) or the
    # SAMAGOTCHI_ENABLE_BRIDGE env var threaded through Process.spawn. When
    # disabled (the default) this is a no-op and nothing is loaded or bound.
    # Bridge creation happens *before* the loop so the capture observer is in
    # place for the whole session; the caller stops the returned instance on
    # exit (see run_session_loop's ensure).
    #
    # @return [Samagotchi::Bridge, nil]
    private_class_method def self.start_bridge_if_enabled(engine:, state_dir:, session_id:, enabled:)
      return nil unless enabled_bridge?(enabled)

      Samagotchi::Bridge.new(
        engine: engine, state_dir: state_dir, session_id: session_id
      ).start
    rescue StandardError => e
      warn "Bridge: failed to start for session #{session_id}: #{e.class}: #{e.message}"
      nil
    end

    # Resolve whether the transport is enabled: the +enabled:+ keyword wins;
    # otherwise fall back to the SAMAGOTCHI_ENABLE_BRIDGE env var.
    private_class_method def self.enabled_bridge?(enabled)
      return enabled unless enabled.nil?

      value = ENV.fetch("SAMAGOTCHI_ENABLE_BRIDGE", "").to_s.downcase
      !value.empty? && !%w[0 false no off].include?(value)
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

