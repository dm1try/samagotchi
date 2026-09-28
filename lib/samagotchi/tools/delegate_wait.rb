# frozen_string_literal: true

require_relative "../session"
require_relative "../reply_wait"
require_relative "output_guardrails"
require_relative "peers"

module Samagotchi
  module Tools
    # Waiting for a delegated session's next reply, shared by delegate and
    # delegate_result: ReplyWait in the tools' words, with a cursor per
    # child (the newest reply this parent was already given). The cursors
    # live in this process (a worker runs one session), keyed by parent and
    # child; a worker respawn loses them, which only repeats the newest reply
    # once.
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
        cancelled = -> { peers.respond_to?(:cancelled?) && peers.cancelled? }
        wait = ReplyWait.call(child_id, state_dir: sd, cursor: seen[key], timeout: timeout.to_i,
                                        poll_interval: poll_interval, cancelled: cancelled)
        case wait.status
        when :done
          seen[key] = wait.file
          reply_result(child_id, wait.text)
        when :error
          result(child_id, "error", "the child's worker failed: #{wait.text}; its session shows what happened")
        when :stopped
          result(child_id, "stopped", "the child was stopped (chi sessions stop); delegate with session: #{child_id} starts it again with a message")
        when :waiting_for_answer
          result(child_id, "waiting_for_answer", waiting_text(child_id, wait.question))
        when :canceled
          result(child_id, "canceled", "wait canceled; the child keeps running; delegate_result #{child_id} waits again")
        when :no_reply
          result(child_id, "no_reply", "the child's turn ended without a reply (canceled, failed or empty); its session shows what happened")
        else
          timeout_result(child_id, timeout)
        end
      rescue ArgumentError => e
        "Error: #{e.message}"
      end

      # Point the cursor at the newest reply now, so only a later one counts
      # (a follow-up sent to a child that already answered).
      def mark_seen(parent_id, child_id, state_dir:)
        seen[[parent_id, child_id]] = ReplyWait.newest_reply(child_id, state_dir: state_dir)
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

    end
  end
end
