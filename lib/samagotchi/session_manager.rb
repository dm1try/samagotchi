
# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "securerandom"

require_relative "session"

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
    # Returns the session object with its ID.
    def self.spawn_session(prompt:, mode: "assist", working_directory: nil, model_name: nil)
      session = Session.new_session(
        mode: mode,
        model_name: model_name || Samagotchi::ModelProfile.required_model_name,
        working_directory: working_directory || Dir.pwd
      )
      session.status = Session::STATUS_RUNNING
      session.last_prompt = prompt
      session_dir = Session.session_dir(session.id)
      setup_session_directory(session_dir, session)

      lib_path = File.expand_path("../lib", __dir__)
      pid = Process.spawn(
        "ruby" => File.executable?("ruby") ? RbConfig.ruby : "ruby",
        "-I" => lib_path,
        "-e" => "Samagotchi::SessionManager.run_session_loop('#{session.id}')",
        out: File::NULL,
        err: File::NULL
      )

      File.write(File.join(session_dir, PID_FILE), pid.to_s)
      session
    end

    # List all sessions, reading status from persisted session.json files.
    def self.list_sessions
      Session.list
    end

    # Attach to a session: write a message to its input directory and read output.
    #
    # Returns an array of output lines from the session.
    def self.attach_session(session_id, message:)
      session_dir = Session.session_dir(session_id)
      input_path = File.join(session_dir, INPUT_DIR)
      FileUtils.mkdir_p(input_path)

      timestamp = Time.now.strftime("%Y%m%d%H%M%S%9N")
      input_file = File.join(input_path, "#{timestamp}.txt")
      File.write(input_file, message)

      output_path = File.join(session_dir, OUTPUT_DIR)
      responses = []
      sleep(0.1) # brief delay for the session process to process
      if Dir.exist?(output_path)
        Dir.glob(File.join(output_path, "*.txt")).sort.each do |f|
          # Only read files newer than the input file
          responses << File.read(f) if File.mtime(f) >= File.mtime(input_file)
        end
      end
      responses
    end

    # Stop a session by sending TERM to its process.
    def self.stop_session(session_id)
      session_dir = Session.session_dir(session_id)
      pid_file = File.join(session_dir, PID_FILE)
      return unless File.exist?(pid_file)

      pid = File.read(pid_file).strip.to_i
      Process.kill("TERM", pid) if pid > 0
      Session.mark_stopped(session_id)
    rescue Errno::ESRCH
      # Process already exited; still mark as stopped
      Session.mark_stopped(session_id)
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
    def self.run_session_loop(session_id)
      session = Session.load(session_id)
      session_dir = Session.session_dir(session_id)

      begin
        # Process the initial prompt
        if session.last_prompt.present?
          prompt = session.last_prompt
          session.last_prompt = ""
          session.save

          response = process_prompt(session, prompt)
          write_output(session_dir, response) if response
        end

        # Poll for new input files
        loop do
          Session.mark_stopped(session_id)
          exit(0) if session.status == Session::STATUS_STOPPED

          input_files = find_new_input_files(session_dir)
          if input_files.empty?
            sleep(1)
            next
          end

          input_files.sort.each do |input_file|
            message = File.read(input_file)
            response = process_prompt(session, message)
            write_output(session_dir, response) if response
            session.save
          end
        end
      rescue StandardError => e
        Session.mark_error(session_id, reason: e.message)
        exit(1)
      end
    end

    private_class_method def self.setup_session_directory(session_dir, session)
      FileUtils.mkdir_p(session_dir)
      FileUtils.mkdir_p(File.join(session_dir, INPUT_DIR))
      FileUtils.mkdir_p(File.join(session_dir, OUTPUT_DIR))
      session.save(state_dir: session_dir)
    end

    private_class_method def self.process_prompt(session, prompt)
      # Minimal processing: echo the prompt back (real implementation delegates to Agent/KernelLoop)
      # For now, the session process responds with a confirmation.
      session.messages << { role: "user", content: prompt }

      # In a real implementation, this would call the model.
      # For the session loop, we return a placeholder response.
      response = "[Session processed prompt: #{prompt}]"
      session.messages << { role: "model", content: response }
      response
    end

    private_class_method def self.write_output(session_dir, response)
      output_dir = File.join(session_dir, OUTPUT_DIR)
      FileUtils.mkdir_p(output_dir)
      timestamp = Time.now.strftime("%Y%m%d%H%M%S%9N")
      File.write(File.join(output_dir, "#{timestamp}.txt"), response)
    end

    private_class_method def self.find_new_input_files(session_dir)
      input_dir = File.join(session_dir, INPUT_DIR)
      return [] unless Dir.exist?(input_dir)

      Dir.glob(File.join(input_dir, "*.txt"))
    end
  end
end

