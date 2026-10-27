# frozen_string_literal: true

require_relative "../context_note"
require_relative "../image_store"
require_relative "../log"
require_relative "../message_parts"
require_relative "../output_formatter"
require_relative "../steer"
require_relative "../tool_activity"
require_relative "../tool_view"
require_relative "../turn_note"
require_relative "event_renderer"
require_relative "formatting"

module Samagotchi
  class TerminalUI
    # Draws the saved part of a worker snapshot when an attached TUI joins or
    # resyncs. The live loop owns the collaborators; this owns replay only.
    class JoinReplay
      include Formatting

      # How much of the last answer a join shows.
      JOIN_ANSWER_LINES = 12
      JOIN_ANSWER_CHARS = 1200

      def initialize(screen:, view:, link:, gaps:, renderer:)
        @screen = screen
        @view = view
        @link = link
        @gaps = gaps
        @renderer = renderer
      end

      def render_join(snapshot, saved)
        render_join_header(Array(snapshot[:messages]))
        render_join_gap(snapshot, saved)
      end

      # The snapshot's cards and between-turns notices (Bridge CardStore):
      # on join the ones since the last turn (and the running turn's), as
      # the join header shows the last exchange; on a resync only cards not
      # shown here yet, and not the ones an earlier worker saved (a resync
      # onto a new worker: earlier turns, not news). A turn's own rows (notices, retries) are left out:
      # the running turn's come with its parts, and the join shows no older
      # turn's steps.
      def render_snapshot_cards(entries, joining:)
        entries.each do |entry|
          case entry[:type].to_s
          when "hook_notice"
            next if entry[:in_turn]

            @screen.commit(EventRenderer.hook_notice_line(entry)) if joining && entry[:turns_since].to_i.zero?
          when "card"
            next unless joining ? entry[:turns_since].to_i.zero? : !entry[:earlier] && !@renderer.card_shown?(entry[:id])

            @renderer.render_card(entry, updated: entry[:updated] == true)
          end
        end
      end

      private

      # Where the session's last activity was: its newest stamped entry,
      # else its saved recap's time. A gap ago (and no turn running): one
      # line after the join block says when.
      def render_join_gap(snapshot, saved)
        @gaps.seed(snapshot[:messages], fallback: saved&.dig(:created_at))
        return if snapshot[:current_turn]

        line = @gaps.join_line
        @screen.commit(gap_divider(line)) if line
      end

      def render_join_header(messages)
        exchange = messages.select { |m| %w[user model assistant].include?(m[:role].to_s) }
        # The id stays findable: the detach line and chi sessions list show it.
        Log.session_id = @link.client.session_id
        Log.info(:attached, "joined", session: @link.client.session_id, messages: exchange.size,
                                      notes: messages.count { |m| ContextNote.note?(m) })
        last_user = exchange.rindex { |m| Steer.prompt?(m) }
        render_join_notes(messages)
        return unless last_user

        @screen.commit(join_prompt_line(exchange[last_user]))
        # An image-only turn's text names its images already.
        unless ImageRef.placeholder_only?(exchange[last_user][:content])
          Array(exchange[last_user][:images]).each { |ref| @screen.commit(format_image_line(ref)) }
        end
        from = messages.index { |m| m.equal?(exchange[last_user]) }
        render_join_steps(messages, from, durations: join_tool_records(exchange[last_user]))
        record = @link.saved_turn_record(exchange[last_user][:turn_id] || exchange[last_user]["turn_id"])
        failed = join_failed_record(record)
        # A turn that ended with no answer: its notice, as live.
        empty = messages.drop(from + 1).filter_map { |m| TurnNote.empty_answer(m) }.last
        if empty
          @screen.commit(format_empty_answer_line(empty[:retries] || empty["retries"], empty[:refusal] || empty["refusal"]))
        elsif failed
          # A failed turn whose steps stayed: the line the live view left,
          # and no step text as if it were the answer (the web keeps a
          # failed turn's texts as steps too).
          failure = failed["failure"]
          @screen.commit(@view.turn_failed_line(failure["summary"] || failure["message"], failed["duration_ms"]))
          @screen.commit(@view.turn_end_hint(ROLLBACK_HINT)) if failure["kept_steps"]
        elsif record && record["status"] == "canceled"
          # A canceled turn (a Stop, Ctrl-C): its line, as live, and no
          # text it streamed before the cancel as if it were the answer.
          @screen.commit(@view.turn_canceled_line(record["cancellation_reason"], record["duration_ms"], by: record["cancelled_by"]))
          @screen.commit(@view.turn_end_hint(ROLLBACK_HINT)) unless record["continue"]
        else
          # The saved answer is raw: the latest keeps its thinking, and one may
          # be only a tool call.
          answer = exchange[(last_user + 1)..].reverse_each
                                             .map { |m| OutputFormatter.strip_markup(m[:content]) }
                                             .find { |text| !text.empty? }
          @screen.commit(last_lines(answer)) if answer
        end
        render_join_notes(messages, after_exchange: true)
      end

      # What the last exchange did, as the live turn drew it: each saved
      # call's tool row (action, params, status from its result, and its
      # duration from +durations+, the turn's saved tool records) and a
      # plugin's steer where it came. The step texts stay out, as live (the
      # ticker's).
      def render_join_steps(messages, from, durations: [])
        records = durations.dup
        messages.each_with_index.drop(from + 1).each do |m, i|
          if Steer.steer?(m)
            @screen.commit(format_steer_line(source: m[:source], text: m[:content]))
          elsif %w[model assistant].include?(m[:role].to_s)
            responses = messages.drop(i + 1).take_while { |r| r[:role].to_s == "tool_response" }
            Array(MessageParts.for_message(m, responses)&.dig(:tools)).each do |part|
              record = join_record(records, part)
              duration = record&.dig("duration_ms")
              @screen.commit(join_tool_line(part, duration_ms: duration.is_a?(Numeric) ? duration : nil,
                                                  saved_status: record&.dig("status"),
                                                  auto_allowed: record&.dig("guardrail")))
            end
          end
        end
      end

      # The prompt's turn's saved tool records (AttachLink: SessionMetrics,
      # in this machine's state dir, as #attach_images): none for a prompt
      # with no turn id (an older session) or a session with no analytics.
      def join_tool_records(prompt)
        @link.saved_tool_records(prompt[:turn_id] || prompt["turn_id"])
      end

      # The turn's saved +record+ when it failed with the fields its line is
      # made of (SessionMetrics#failure_fields), else nil: a completed or
      # older turn — or one saved before the failure field — draws its
      # answer as before (a canceled one its line).
      def join_failed_record(record)
        return nil unless record && record["status"] == "failed" && record["failure"].is_a?(Hash)

        failure = record["failure"]
        return nil if failure["summary"].to_s.empty? && failure["message"].to_s.empty?

        record
      end

      # The saved record of +part+'s call (its duration and status): the
      # next record of its tool, in call order, consumed with the ones it
      # skipped. By tool and order, not by iteration: an empty retry spends
      # an iteration that left no message (as the web's timing.js
      # takeRecord). nil for a call that left none: it never finished, or a
      # worker before turn ids saved it.
      def join_record(records, part)
        return nil if part[:output].nil?

        at = records.index { |r| r["tool"].to_s == part[:tool].to_s }
        return nil unless at

        records.shift(at + 1).last
      end

      # A saved call's row; "no result" for a call the turn never answered
      # (it ended first). Its status is the saved record's, as live and the
      # web's reload (a guardrail's "blocked" is no error), else read from
      # its result (a guardrail's deny text reads blocked too). A record that
      # System 1 allowed once (+auto_allowed+, its saved {rule, p}) says so,
      # as the live row does.
      def join_tool_line(part, duration_ms: nil, saved_status: nil, auto_allowed: nil)
        output = part[:output]
        command = part.dig(:view, :truncated) ? nil : part.dig(:view, :command)
        text = ToolActivity.saved_result_text(output) unless output.nil?
        status = if output.nil?
                   "no result"
                 elsif !saved_status.to_s.empty?
                   saved_status.to_s
                 elsif ToolActivity.guardrail_denied?(text)
                   "blocked"
                 else
                   ToolActivity.tool_activity_status(text, part[:tool], command: command)
                 end
        activity = { action: part[:label] || ToolActivity.tool_activity_action(part[:tool]), tool: part[:tool],
                     params: part[:params], status: status,
                     description: ToolView.description_title(part[:view] || {}) }
        "#{format_tool_activity_line(activity, duration_ms: duration_ms)}" \
          "#{format_tool_image_suffix(part[:images])}#{format_tool_diff_suffix(part[:diff])}#{format_tool_cut_suffix(part[:output_truncated])}" \
          "#{auto_allowed_suffix(auto_allowed)}"
      end

      # The live row's System 1 suffix for a saved record's {rule, p}.
      def auto_allowed_suffix(saved)
        return "" unless saved.is_a?(Hash)

        format_tool_guardrail_suffix({ decided_by: "system one", p: saved["p"] || saved[:p] })
      end

      # The context notes that came since the last prompt (all of them in a
      # session with none), after the exchange the header shows.
      def render_join_notes(messages, after_exchange: false)
        last_user = messages.rindex { |m| Steer.prompt?(m) }
        return if after_exchange != !last_user.nil?

        messages[(last_user ? last_user + 1 : 0)..].select { |m| ContextNote.note?(m) }.each do |m|
          @screen.commit(context_note_line(ContextNote.label_of(m), ContextNote.text_of(m)))
        end
      end

      # The end of a long answer; the whole of it is in the session.
      def last_lines(text)
        lines = text.split("\n", -1)
        if lines.size > JOIN_ANSWER_LINES
          text = "(… #{lines.size - JOIN_ANSWER_LINES} earlier lines)\n#{lines.last(JOIN_ANSWER_LINES).join("\n")}"
        end
        return text if text.length <= JOIN_ANSWER_CHARS

        "(… earlier text)\n…#{text[-JOIN_ANSWER_CHARS..]}"
      end
    end
  end
end
