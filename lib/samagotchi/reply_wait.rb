# frozen_string_literal: true

require_relative "session"

module Samagotchi
  # Loaded on first use: session_manager requires terminal_ui, which
  # requires KernelLoop and so the tools that use this (a require cycle
  # otherwise).
  autoload :SessionManager, File.expand_path("session_manager", __dir__)

  # Waiting for a session's next reply. A reply is the worker's
  # output/<timestamp>.txt file (one per turn that ended with visible text,
  # written just before its idle save), so "next" means a filename past the
  # cursor the caller holds: the newest one it already has, or nil for any.
  # The delegate tools and `chi send --wait` wrap it in their own words.
  module ReplyWait
    POLL_INTERVAL = 0.5

    # @!attribute status [Symbol] :done, :waiting_for_answer, :no_reply,
    #   :error, :stopped, :canceled or :timeout
    # @!attribute text [String, nil] the reply (:done) or the worker's error
    #   (:error)
    # @!attribute file [String, nil] the reply's filename, the next cursor
    # @!attribute question [Hash, nil] the pending question
    #   (:waiting_for_answer)
    Result = Struct.new(:status, :text, :file, :question, keyword_init: true)

    module_function

    # @param id [String] the session's full id
    # @param state_dir [String]
    # @param cursor [String, nil] the newest reply filename already had
    # @param timeout [Numeric, nil] seconds; nil waits with no limit
    # @param poll_interval [Float]
    # @param cancelled [#call] true stops the wait (:canceled)
    # @return [Result]
    # @raise [ArgumentError] no such session
    def call(id, state_dir:, cursor:, timeout: nil, poll_interval: POLL_INTERVAL, cancelled: -> { false })
      deadline = timeout && (monotonic + timeout.to_f)
      seen_running = false

      loop do
        session = Session.load(id, state_dir: state_dir)

        if (file = newest_reply(id, state_dir: state_dir)) && newer?(file, cursor)
          return Result.new(status: :done, text: File.read(File.join(reply_dir(id, state_dir: state_dir), file)), file: file)
        end

        case session.status
        when Session::STATUS_ERROR
          return Result.new(status: :error, text: session.last_prompt.to_s.strip)
        when Session::STATUS_STOPPED
          return Result.new(status: :stopped)
        end

        if (pending = session.pending_question)
          return Result.new(status: :waiting_for_answer, question: pending)
        end

        return Result.new(status: :canceled) if cancelled.call

        if session.status == Session::STATUS_RUNNING
          seen_running = true
        elsif seen_running
          # It ran and is idle again with no new reply: canceled, failed or
          # empty. Before it was ever seen running, idle means a
          # file-delivered message its worker has not picked up yet.
          return Result.new(status: :no_reply)
        end

        return Result.new(status: :timeout) if deadline && monotonic > deadline

        sleep(poll_interval)
      end
    end

    # @return [String, nil] the newest reply filename (sortable timestamps)
    def newest_reply(id, state_dir:)
      dir = reply_dir(id, state_dir: state_dir)
      return nil unless Dir.exist?(dir)

      Dir.children(dir).select { |f| f.end_with?(".txt") }.max
    end

    def reply_dir(id, state_dir:)
      File.join(Session.session_dir(id, state_dir: state_dir), SessionManager::OUTPUT_DIR)
    end

    def newer?(file, cursor)
      cursor.nil? || file > cursor
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
