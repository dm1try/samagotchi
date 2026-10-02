# frozen_string_literal: true

require_relative "../session"
require_relative "../reply_wait"
require_relative "../parent_report"
require_relative "output_guardrails"
require_relative "peers"
require_relative "delegate_relay"

module Samagotchi
  module Tools
    # Waiting for a delegated session's next reply, shared by delegate and
    # delegate_result: ReplyWait in the tools' words, with the status words
    # `chi send --wait` and `chi answer` use (ParentReport.status), with a cursor per
    # child (the newest reply this parent was already given) and the child
    # as it was before the message went in (ReplyWait's baseline), so a turn
    # that ends before the wait's first look (a fast failure) still ends it.
    # Both live in this process (a worker runs one session), keyed by parent
    # and child; a worker respawn loses them, which only repeats the newest
    # reply once or waits for a later turn.
    module DelegateWait
      TIMEOUT_DEFAULT = 600
      POLL_INTERVAL = 0.5
      # Seconds with no worker before the child counts as gone: as long as
      # Delegate gives a starting child (its worker takes the owner lock
      # only once it has booted).
      OWNER_GRACE = 15
      # Cut like an execute result: full up to TRUNCATE_AT bytes, else a
      # head-and-tail preview of PREVIEW bytes.
      TRUNCATE_AT_BYTES = OutputGuardrails::DEFAULT_TRUNCATE_AT_BYTES
      PREVIEW_BYTES = OutputGuardrails::DEFAULT_PREVIEW_BYTES

      module_function

      # @return [Hash{Array(String, String) => String}] [parent id, child id] → newest reply filename given
      def seen
        @seen ||= {}
      end

      # @return [Hash{Array(String, String) => Hash}] [parent id, child id] → ReplyWait baseline taken before sending
      def baselines
        @baselines ||= {}
      end

      # @param child_id [String] the child's full id
      # @param peers [Peers] the parent (session_id, state_dir, cancelled?)
      # @param timeout [Integer] seconds
      # @param poll_interval [Float]
      # @param owner_grace [Numeric] seconds with no live worker before
      #   the child's worker counts as gone
      # @return [String] the tool result
      #
      # A child's approval, when this session can host a relay (Peers#relay),
      # goes to this session's user as its own approval (DelegateRelay); the
      # wait goes on after it settles, and the result gets one outcome line per relayed
      # approval. Without a relay, and for the model's and hooks' questions,
      # the question comes back to the model as before.
      def call(child_id, peers:, timeout: TIMEOUT_DEFAULT, poll_interval: POLL_INTERVAL, owner_grace: OWNER_GRACE)
        sd = peers.state_dir || Session.default_state_dir
        key = [peers.session_id, child_id]
        cancelled = -> { peers.cancelled? }
        relay = peers.respond_to?(:relay) ? peers.relay : nil
        baseline = baselines[key]
        outcomes = []
        loop do
          wait = ReplyWait.call(child_id, state_dir: sd, cursor: seen[key], timeout: timeout.to_i,
                                          poll_interval: poll_interval, cancelled: cancelled, baseline: baseline,
                                          owner_grace: owner_grace)
          unless wait.status == :waiting_for_answer && DelegateRelay.relayable?(relay, wait.question)
            return with_outcomes(finish(wait, child_id, key: key, timeout: timeout), outcomes)
          end

          outcome = DelegateRelay.call(child_id, wait.question, relay: relay, state_dir: sd)
          outcomes << outcome.line
          return with_outcomes(canceled_result(child_id), outcomes) if outcome.stopped

          # Wait on with the child as it is now: a turn that ends with no
          # reply after the relay still ends the wait, and the relayed
          # question isn't reported again.
          baseline = ReplyWait.baseline_of(Session.load(child_id, state_dir: sd), question_id: wait.question[:id])
        end
      rescue ArgumentError => e
        "Error: #{e.message}"
      end

      # The relayed approvals' outcome lines, after the status line.
      def with_outcomes(text, outcomes)
        return text if outcomes.empty?

        text.sub(/\A(session: [^\n]*\nstatus: [^\n]*\n)/) { "#{::Regexp.last_match(1)}#{outcomes.join("\n")}\n" }
      end

      def canceled_result(child_id)
        result(child_id, "running", "wait canceled; the child keeps running; delegate_result #{child_id} waits again")
      end

      # The tool result for how the wait ended.
      # @param wait [ReplyWait::Result]
      # @param key [Array(String, String)] [parent id, child id]
      # @return [String]
      def finish(wait, child_id, key:, timeout:)
        # The turn sent to is handed over: a later wait looks for a later one.
        baselines.delete(key) if %i[done no_reply].include?(wait.status)
        status = ParentReport.status(wait)
        case wait.status
        when :done
          seen[key] = wait.file
          reply_result(child_id, status, wait.text)
        when :error
          result(child_id, status, "the child's worker failed: #{wait.text}; its session shows what happened")
        when :stopped
          result(child_id, status, "the child was stopped (chi sessions stop); delegate with session: #{child_id} starts it again with a message")
        when :waiting_for_answer
          result(child_id, status, waiting_text(child_id, wait.question))
        when :canceled
          canceled_result(child_id)
        when :no_reply
          result(child_id, status, "#{no_reply_text(wait)}; its session shows what happened")
        when :worker_gone
          result(child_id, status,
                 "the child's worker is gone (it stopped or crashed); delegate with session: #{child_id} starts it again with a message")
        else
          timeout_result(child_id, timeout)
        end
      end

      # Point the cursor at the newest reply now, so only a later one counts
      # (a follow-up sent to a child that already answered), and take the
      # child's baseline before the follow-up goes in.
      # @param child [Session] the child as loaded before sending
      def mark_seen(parent_id, child, state_dir:)
        seen[[parent_id, child.id]] = ReplyWait.newest_reply(child.id, state_dir: state_dir)
        baselines[[parent_id, child.id]] = ReplyWait.baseline_of(child)
      end

      # A new child's baseline: as spawned, before its first turn ran.
      # @param child [Session] the session spawn_session returned
      def mark_started(parent_id, child)
        baselines[[parent_id, child.id]] = ReplyWait.baseline_of(child, question_id: nil)
      end

      def reply_result(child_id, status, text)
        "session: #{child_id}\nstatus: #{status}\n---\n#{cut(text)}"
      end

      # ParentReport's line for a turn that left no reply, about the child.
      def no_reply_text(wait)
        ParentReport.no_reply_line(wait).sub(/\Athe turn/, "the child's turn")
      end

      def result(child_id, status, text)
        "session: #{child_id}\nstatus: #{status}\n#{text}"
      end

      def timeout_result(child_id, timeout)
        result(child_id, "running",
               "no reply yet after #{timeout.to_i} s; the child keeps running. delegate_result #{child_id} waits again; " \
               "chi --attach #{child_id} shows it.")
      end

      # The whole question, as `chi send --wait` prints it (ParentReport):
      # its text, options and the commands that answer it.
      def waiting_text(child_id, pending)
        "Child #{child_id} is #{ParentReport.question_text(pending, session_id: child_id)}" \
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
