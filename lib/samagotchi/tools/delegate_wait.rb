# frozen_string_literal: true

require_relative "../session"
require_relative "../reply_wait"
require_relative "../parent_report"
require_relative "output_guardrails"
require_relative "peers"
require_relative "delegate_relay"
require_relative "delegate_cursor"

module Samagotchi
  # Loaded on first use: child_reports requires this file (a circular
  # require otherwise).
  autoload :ChildRing, File.expand_path("../child_reports", __dir__)

  module Tools
    # Waiting for a delegated session's next reply, shared by delegate and
    # delegate_result: ReplyWait in the tools' words, with the status words
    # `chi send --wait` and `chi answer` use (ParentReport.status), with a
    # DelegateCursor per child: the newest reply this parent was already
    # given, and the child as it was when the parent last heard from it or
    # sent it a message (ReplyWait's baseline), so a turn that ends before
    # the wait's first look (a fast failure) still ends it. The cursors are
    # on disk (DelegateCursors), so a respawned worker doesn't repeat a reply.
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

      # @return [Hash{Array(String, String) => Array<String>}] [parent id,
      #   child id] → outcome lines of that child's approvals relayed while
      #   the parent waited on another child, for its next result
      def relayed_outcomes
        @relayed_outcomes ||= {}
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
      # wait goes on after it settles, with the time it was open not counted
      # against +timeout+, and the result gets one outcome line per relayed
      # approval. Without a relay, and for the model's and hooks' questions,
      # the question comes back to the model as before.
      def call(child_id, peers:, timeout: TIMEOUT_DEFAULT, poll_interval: POLL_INTERVAL, owner_grace: OWNER_GRACE)
        sd = peers.state_dir || Session.default_state_dir
        key = [peers.session_id, child_id]
        cancelled = -> { peers.cancelled? }
        relay = peers.respond_to?(:relay) ? peers.relay : nil
        reports = reports_mode(peers)
        others = relay && others_for(peers.session_id, child_id, relay, sd)
        cursor = DelegateCursors.get(peers.session_id, child_id, state_dir: sd)
        baseline = cursor.baseline
        left = timeout.to_i
        outcomes = relayed_outcomes.delete(key) || []
        loop do
          started = monotonic
          wait = ReplyWait.call(child_id, state_dir: sd, cursor: cursor.reply_file, timeout: [left, 0].max,
                                          poll_interval: poll_interval, cancelled: cancelled, baseline: baseline,
                                          owner_grace: owner_grace, interject: others && -> { others.poll })
          left -= monotonic - started
          unless wait.status == :waiting_for_answer && DelegateRelay.relayable?(relay, wait.question)
            outcomes.concat(relayed_outcomes.delete(key) || [])
            advance(peers.session_id, child_id, wait, state_dir: sd)
            return with_outcomes(finish(wait, child_id, timeout: timeout, reports: reports), outcomes)
          end

          outcome = DelegateRelay.call(child_id, wait.question, relay: relay, state_dir: sd, more: others&.count.to_i)
          outcomes << outcome.line
          return with_outcomes(canceled_result(child_id, reports: reports), outcomes) if outcome.stopped

          # Wait on from the child as it was before the relay (read when it
          # asked), the relayed question no longer reported: a turn that
          # ends with no reply during the relay's POST or after it still
          # ends the wait.
          baseline = ReplyWait.baseline_of(wait.session, question_id: wait.question[:id])
        end
      rescue ArgumentError => e
        "Error: #{e.message}"
      end

      # The parent's other children whose approvals a wait relays too, their
      # outcomes kept for their own next result.
      def others_for(parent_id, child_id, relay, state_dir)
        DelegateRelay::Others.new(parent_id: parent_id, except: child_id, relay: relay, state_dir: state_dir,
                                  on_outcome: lambda { |other, outcome|
                                    (relayed_outcomes[[parent_id, other]] ||= []) << outcome.line
                                  })
      end

      # The relayed approvals' outcome lines, after the status line.
      def with_outcomes(text, outcomes)
        return text if outcomes.empty?

        text.sub(/\A(session: [^\n]*\nstatus: [^\n]*\n)/) { "#{::Regexp.last_match(1)}#{outcomes.join("\n")}\n" }
      end

      # How a child's reply reaches this parent when no wait takes it:
      # "wake" (a delegate report, a turn of its own when idle), "queue" (a
      # report at its next step or turn, no wake) or "off" (only
      # delegate_result). Only a worker's session reads its children's rings
      # (its Engine gives a relay); a REPL, a -p run or a scratch session
      # never gets a report.
      # @param peers [Peers]
      # @return [String] "wake", "queue" or "off"
      def reports_mode(peers)
        return "off" unless peers.respond_to?(:relay) && peers.relay

        ChildRing.mode
      end

      def canceled_result(child_id, reports: "off")
        if reports == "off"
          return result(child_id, "running", "wait canceled; the child keeps running; delegate_result #{child_id} waits again")
        end

        result(child_id, "running", "wait canceled; the child keeps running; chi brings its reply as a delegate report")
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      REPORT_NEXT_REPLY = "chi brings the child's next reply here by itself; don't wait for it with delegate_result."

      # Outcomes that tell the parent something about the child's state.
      REPORTED = %i[done no_reply error stopped waiting_for_answer worker_gone].freeze

      # Move the parent's cursor past what +wait+ reported: the reply it
      # gave, and the child as that same look loaded it (a fresh load could
      # swallow a turn that ended in between), so a later wait looks for a
      # later turn and a question already reported isn't reported again.
      # Nothing moves on a timeout or a cancel.
      # @param wait [ReplyWait::Result]
      # @return [DelegateCursor, nil] the new cursor
      def advance(parent_id, child_id, wait, state_dir:)
        return nil unless REPORTED.include?(wait.status) && wait.session

        DelegateCursors.update(parent_id, child_id, state_dir: state_dir) do |cursor|
          cursor = cursor.with(reply_file: wait.file) if wait.status == :done
          cursor.with_baseline(ReplyWait.baseline_of(wait.session))
        end
      end

      # The tool result for how the wait ended.
      # @param wait [ReplyWait::Result]
      # @param report [Boolean] a delegate report's text (ChildReports), not
      #   the tool's: a question's last line says chi brings the next reply
      # @param reports [String] #reports_mode: what a timeout, a cancel or
      #   a question tells the model about the reply to come
      # @return [String]
      def finish(wait, child_id, timeout:, report: false, reports: "off")
        status = ParentReport.status(wait)
        case wait.status
        when :done
          reply_result(child_id, status, wait.text)
        when :error
          result(child_id, status, "the child's worker failed: #{wait.text}; its session shows what happened")
        when :stopped
          result(child_id, status, "the child was stopped (chi sessions stop); delegate with session: #{child_id} starts it again with a message")
        when :waiting_for_answer
          result(child_id, status, waiting_text(child_id, wait.question, report: report, reports: reports))
        when :canceled
          canceled_result(child_id, reports: reports)
        when :no_reply
          result(child_id, status, "#{no_reply_text(wait, child_id)}; its session shows what happened")
        when :worker_gone
          result(child_id, status,
                 "the child's worker is gone (it stopped or crashed); delegate with session: #{child_id} starts it again with a message")
        else
          timeout_result(child_id, timeout, reports: reports)
        end
      end

      # Point the cursor at the newest reply now, so only a later one counts
      # (a follow-up sent to a child that already answered), and take the
      # child's baseline before the follow-up goes in.
      # @param child [Session] the child as loaded before sending
      def mark_seen(parent_id, child, state_dir:)
        newest = ReplyWait.newest_reply(child.id, state_dir: state_dir)
        DelegateCursors.update(parent_id, child.id, state_dir: state_dir) do |cursor|
          cursor.with(reply_file: newest).with_baseline(ReplyWait.baseline_of(child))
        end
      end

      # A new child's baseline: as spawned, before its first turn ran.
      # @param child [Session] the session spawn_session returned
      def mark_started(parent_id, child, state_dir:)
        DelegateCursors.update(parent_id, child.id, state_dir: state_dir) do |cursor|
          cursor.with_baseline(ReplyWait.baseline_of(child, question_id: nil))
        end
      end

      def reply_result(child_id, status, text)
        "session: #{child_id}\nstatus: #{status}\n---\n#{cut(text)}"
      end

      # ParentReport's line for a turn that left no reply, about the child.
      def no_reply_text(wait, child_id)
        ParentReport.no_reply_line(wait, child_id).sub(/\Athe turn/, "the child's turn")
      end

      def result(child_id, status, text)
        "session: #{child_id}\nstatus: #{status}\n#{text}"
      end

      # The cursor didn't move (#advance), so the reply still comes as a
      # delegate report when this parent can get one.
      def timeout_result(child_id, timeout, reports: "off")
        head = "no reply yet after #{timeout.to_i} s; the child keeps running."
        if reports == "off"
          return result(child_id, "running",
                        "#{head} delegate_result #{child_id} waits again; chi --attach #{child_id} shows it.")
        end

        comes = if reports == "queue"
                  "chi adds its reply to your turn at its next step, or to your next turn, as a delegate report " \
                    "(you are not woken while idle)"
                else
                  "chi brings its reply here by itself as a delegate report when it ends its turn (also after you end yours)"
                end
        result(child_id, "running",
               "#{head} #{comes}, so carry on or end your turn. Only if this turn can't go on without it: " \
               "delegate_result #{child_id} waits again. chi --attach #{child_id} shows it.")
      end

      # The whole question, as `chi send --wait` prints it (ParentReport):
      # its text, options and the commands that answer it.
      # A step-limit question (kind continue) is the parent model's to
      # decide (it isn't relayed: Continue grants no permission): continue
      # it with chi answer through execute, send a follow-up instead, or
      # report back.
      # A report's last line differs (+report+): "waits again" made models
      # call delegate_result right after answering Continue.
      # The tool's last line follows #reports_mode.
      def waiting_text(child_id, pending, report: false, reports: "off")
        text = "Child #{child_id} is #{ParentReport.question_text(pending, session_id: child_id)}"
        if ParentReport.continue?(pending)
          text += "The child ran out of steps before it answered. Decide: continue it (run the chi answer command " \
                  "above with execute) if it is getting somewhere; send it a narrower follow-up with delegate " \
                  "session: #{child_id} (that drops the question); or stop it and report back to your user.\n"
        end
        return "#{text}#{REPORT_NEXT_REPLY}" if report
        return "#{text}delegate_result #{child_id} waits again once it is answered." if reports == "off"

        "#{text}Once it is answered, chi brings the child's next reply here as a delegate report; " \
          "delegate_result #{child_id} waits for it only if this turn needs it."
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
