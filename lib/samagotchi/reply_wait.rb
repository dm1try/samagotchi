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
    #   :error, :stopped, :canceled, :timeout or :worker_gone
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
    # @param baseline [Hash, nil] {messages:, question_id:} as the session
    #   was before the message went in. With it, a turn that grew the
    #   messages (a failed, canceled or empty one leaves its note) and went
    #   idle again ends the wait even if it was never seen running, and a
    #   question already pending then is not the answer's. A nil
    #   messages: skips the count.
    # @param owner_grace [Numeric, nil] seconds with no live worker before
    #   :worker_gone (one that died before its rescue leaves it running)
    # @return [Result]
    # @raise [ArgumentError] no such session
    def call(id, state_dir:, cursor:, timeout: nil, poll_interval: POLL_INTERVAL, cancelled: -> { false },
             baseline: nil, owner_grace: nil)
      deadline = timeout && (monotonic + timeout.to_f)
      seen_running = false
      gone_since = nil

      loop do
        session = Session.load(id, state_dir: state_dir)

        if (reply = reply_past(id, state_dir: state_dir, cursor: cursor))
          return reply
        end

        case session.status
        when Session::STATUS_ERROR
          return Result.new(status: :error, text: session.last_prompt.to_s.strip)
        when Session::STATUS_STOPPED
          return Result.new(status: :stopped)
        end

        pending = session.pending_question
        if pending && !(baseline && pending[:id] == baseline[:question_id])
          return Result.new(status: :waiting_for_answer, question: pending)
        end

        return Result.new(status: :canceled) if cancelled.call

        if session.status == Session::STATUS_RUNNING
          seen_running = true
        elsif seen_running || (baseline&.dig(:messages) && session.messages.size > baseline[:messages])
          # It ran and is idle again with no new reply: canceled, failed or
          # empty. Before it was ever seen running, idle means a
          # file-delivered message its worker has not picked up yet.
          # The worker writes the reply before its idle save, so the read
          # above has it; one more look costs nothing should that change.
          return reply_past(id, state_dir: state_dir, cursor: cursor) || Result.new(status: :no_reply)
        end

        if owner_grace
          if SessionManager.session_owner(id, state_dir: state_dir)
            gone_since = nil
          elsif monotonic - (gone_since ||= monotonic) > owner_grace
            return Result.new(status: :worker_gone)
          end
        end

        return Result.new(status: :timeout) if deadline && monotonic > deadline

        sleep(poll_interval)
      end
    end

    # @return [Result, nil] :done with the newest reply past the cursor
    def reply_past(id, state_dir:, cursor:)
      file = newest_reply(id, state_dir: state_dir)
      return nil unless file && newer?(file, cursor)

      Result.new(status: :done, text: File.read(File.join(reply_dir(id, state_dir: state_dir), file)), file: file)
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
