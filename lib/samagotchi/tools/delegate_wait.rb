# frozen_string_literal: true

require_relative "../session"
require_relative "output_guardrails"
require_relative "peers"

module Samagotchi
  # Loaded on first use: session_manager requires terminal_ui, which
  # requires KernelLoop and so these tools (a require cycle otherwise).
  autoload :SessionManager, File.expand_path("../session_manager", __dir__)

  module Tools
    # Waiting for a delegated session's next reply, shared by delegate and
    # delegate_result. A reply is the child's output/<timestamp>.txt file
    # (the worker writes one per turn that ended with visible text, just
    # before its idle save), so "new" means a filename past the cursor: the
    # newest one this parent was already given. The cursors live in this
    # process (a worker runs one session), keyed by parent and child; a
    # worker respawn loses them, which only repeats the newest reply once.
    module DelegateWait
      TIMEOUT_DEFAULT = 600
      POLL_INTERVAL = 0.5
      # Cut like an execute result: full up to TRUNCATE_AT bytes, else a
      # head-and-tail preview of PREVIEW bytes.
      TRUNCATE_AT_BYTES = OutputGuardrails::DEFAULT_TRUNCATE_AT_BYTES
      PREVIEW_BYTES = OutputGuardrails::DEFAULT_PREVIEW_BYTES

      module_function

      # @return [Hash{Array(String, String) => String}] [parent id, child id] → newest reply filename given
      def seen
        @seen ||= {}
      end

      # @param child_id [String] the child's full id
      # @param peers [Peers] the parent (session_id, state_dir, cancelled?)
      # @param timeout [Integer] seconds
      # @param poll_interval [Float]
      # @return [String] the tool result
      def call(child_id, peers:, timeout: TIMEOUT_DEFAULT, poll_interval: POLL_INTERVAL)
        sd = peers.state_dir || Session.default_state_dir
        key = [peers.session_id, child_id]
        cursor = seen[key]
        deadline = monotonic + timeout.to_i
        seen_running = false

        loop do
          session = Session.load(child_id, state_dir: sd)

          if (file = newest_reply(child_id, state_dir: sd)) && newer?(file, cursor)
            seen[key] = file
            return reply_result(child_id, File.read(File.join(reply_dir(child_id, state_dir: sd), file)))
          end

          case session.status
          when Session::STATUS_ERROR
            return result(child_id, "error", "the child's worker failed: #{session.last_prompt.to_s.strip}; its session shows what happened")
          when Session::STATUS_STOPPED
            return result(child_id, "stopped", "the child was stopped (chi sessions stop); delegate with session: #{child_id} starts it again with a message")
          end

          if (pending = session.pending_question)
            return result(child_id, "waiting_for_answer", waiting_text(child_id, pending))
          end

          if peers.respond_to?(:cancelled?) && peers.cancelled?
            return result(child_id, "canceled", "wait canceled; the child keeps running; delegate_result #{child_id} waits again")
          end

          if session.status == Session::STATUS_RUNNING
            seen_running = true
          elsif seen_running
            # It ran and is idle again with no new reply: canceled, failed or
            # empty. Before it was ever seen running, idle means a
            # file-delivered follow-up its worker has not picked up yet.
            return result(child_id, "no_reply", "the child's turn ended without a reply (canceled, failed or empty); its session shows what happened")
          end

          return timeout_result(child_id, timeout) if monotonic > deadline

          sleep(poll_interval)
        end
      rescue ArgumentError => e
        "Error: #{e.message}"
      end

      # @return [String, nil] the newest reply filename (sortable timestamps)
      def newest_reply(child_id, state_dir:)
        dir = reply_dir(child_id, state_dir: state_dir)
        return nil unless Dir.exist?(dir)

        Dir.children(dir).select { |f| f.end_with?(".txt") }.max
      end

      # Point the cursor at the newest reply now, so only a later one counts
      # (a follow-up sent to a child that already answered).
      def mark_seen(parent_id, child_id, state_dir:)
        seen[[parent_id, child_id]] = newest_reply(child_id, state_dir: state_dir)
      end

      def reply_dir(child_id, state_dir:)
        File.join(Session.session_dir(child_id, state_dir: state_dir), SessionManager::OUTPUT_DIR)
      end

      def newer?(file, cursor)
        cursor.nil? || file > cursor
      end

      def reply_result(child_id, text)
        "session: #{child_id}\nstatus: done\n---\n#{cut(text)}"
      end

      def result(child_id, status, text)
        "session: #{child_id}\nstatus: #{status}\n#{text}"
      end

      def timeout_result(child_id, timeout)
        result(child_id, "running",
               "no reply yet after #{timeout.to_i} s; the child keeps running. delegate_result #{child_id} waits again; " \
               "chi --attach #{child_id} shows it.")
      end

      def waiting_text(child_id, pending)
        what = pending[:kind].to_s == "approval" ? "an approval" : "a question"
        "Child #{child_id} is waiting for an answer (#{what}); attach with chi --attach #{child_id} or answer it in the web. " \
          "delegate_result #{child_id} waits again once it is answered."
      end

      def cut(text)
        text = OutputGuardrails.safe_utf8(text)
        return text if text.bytesize <= TRUNCATE_AT_BYTES

        preview = OutputGuardrails.head_tail_from_string(content: text, preview_bytes: PREVIEW_BYTES)
        [
          "truncated=true",
          "preview_strategy=head_tail",
          "reply_bytes=#{text.bytesize}",
          "returned_preview_bytes=#{preview[:returned_preview_bytes]}",
          "omitted_bytes=#{preview[:omitted_bytes]}",
          "[TRUNCATED_PREVIEW_HEAD]",
          preview[:head],
          "[... omitted #{preview[:omitted_bytes]} bytes ...]",
          "[TRUNCATED_PREVIEW_TAIL]",
          preview[:tail]
        ].join("\n")
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
