# frozen_string_literal: true

require_relative "../bridge/turn_accumulator"
require_relative "../bridge/turn_drawings"
require_relative "../bridge/turn_drawings/synth"
require_relative "../bridge/turn_ranges"
require_relative "../context_note"
require_relative "../image_store"
require_relative "../log"
require_relative "../output_formatter"
require_relative "../steer"
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

      # The last prompt's turn is drawn from a drawing: the snapshot's
      # last_turn_drawing (Bridge#snapshot: as live drew it) when it is that
      # turn's, else one made from the snapshot's messages, the link's saved
      # records and the snapshot's cards (Bridge::TurnDrawings::Synth: an
      # older worker, a turn before drawings, a line over 1 MB).
      def render_join(snapshot, saved)
        render_join_header(Array(snapshot[:messages]), drawing: snapshot[:last_turn_drawing], cards: Array(snapshot[:cards]))
        render_join_gap(snapshot, saved)
      end

      # One replayed event of a turn's rows (TurnAccumulator.replay_events),
      # as live drew it: a joined running turn's (AttachedLoop#render_current_turn)
      # and a drawn finished one's (#render_drawn_turn). Its tool rows with
      # their action and duration, merged input, reminders, a plugin's steer,
      # a hook's notice, a retry's, a steer cut's and a ✂ row's line. The
      # step text, the turn's start and questions are the caller's (the
      # pending one is asked after the replay, answered ones showed no line).
      def replay_row(event)
        case event[:type]
        when :tool_call_started then @renderer.call(event)
        when :tool_call_completed then replay_tool_completed(event)
        when :merged_input then @screen.commit("input> #{event[:content]}")
        when :reminder_injected then @screen.commit(reminder_line(event[:reminders]))
        when :pending_input_merged, :hook_notice, :empty_answer_retry, :steer_cut, :llm_context_edited
          @renderer.call(event)
        end
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

      # A finished tool call: the live row (action, duration: none when the
      # part has none, never the replay's own clock). A snapshot from an
      # older worker has no action: its row names the tool only.
      def replay_tool_completed(event)
        return @renderer.call({ duration_ms: nil }.merge(event)) if event.dig(:activity, :action)

        activity = EventRenderer.described(event) || {}
        @screen.commit(snapshot_tool_line({ tool: event[:tool], params: activity[:params], status: activity[:status],
                                            description: activity[:description], output_truncated: event[:output_truncated],
                                            images: event[:images], diff: event[:diff] }))
      end

      # Where the session's last activity was: its newest stamped entry,
      # else its saved recap's time. A gap ago (and no turn running): one
      # line after the join block says when.
      def render_join_gap(snapshot, saved)
        @gaps.seed(snapshot[:messages], fallback: saved&.dig(:created_at))
        return if snapshot[:current_turn]

        line = @gaps.join_line
        @screen.commit(gap_divider(line)) if line
      end

      def render_join_header(messages, drawing: nil, cards: [])
        exchange = messages.select { |m| %w[user model assistant].include?(m[:role].to_s) }
        # The id stays findable: the detach line and chi sessions list show it.
        Log.session_id = @link.client.session_id
        Log.info(:attached, "joined", session: @link.client.session_id, messages: exchange.size,
                                      notes: messages.count { |m| ContextNote.note?(m) })
        # The last turn's own prompt (Steer.turn_prompt?, as the page's
        # turns): not Qwen's recovery line, nor input merged into the turn.
        last_user = exchange.rindex { |m| Steer.turn_prompt?(m) }
        from = last_user && messages.index { |m| m.equal?(exchange[last_user]) }
        render_join_notes(messages, from)
        return unless last_user

        prompt = exchange[last_user]
        @screen.commit(join_prompt_line(prompt))
        # An image-only turn's text names its images already.
        unless ImageRef.placeholder_only?(prompt[:content])
          Array(prompt[:images]).each { |ref| @screen.commit(format_image_line(ref)) }
        end
        drawn = drawn_turn(drawing, prompt) || made_turn(messages, from, cards)
        if drawn
          render_drawn_turn(*drawn, exchange[(last_user + 1)..])
        else
          # No turn ran for it (a `!cmd`'s record): what came after it.
          render_join_answer(exchange[(last_user + 1)..])
        end
        render_join_notes(messages, from, after_exchange: true)
      end

      # The last answer of the messages after the prompt (+after+). The saved
      # answer is raw: the latest keeps its thinking, and one may be only a
      # tool call.
      def render_join_answer(after)
        answer = after.reverse_each.map { |m| OutputFormatter.strip_markup(m[:content]) }.find { |text| !text.empty? }
        @screen.commit(last_lines(answer)) if answer
      end

      # The snapshot's drawing as [turn, end event] when it is +prompt+'s
      # turn (a Continue's or a reminder's drawing isn't the prompt's: the
      # rows are rebuilt), else nil; nil too for one whose parts aren't a
      # list of rows.
      def drawn_turn(drawing, prompt)
        return nil unless drawing.is_a?(Hash) && drawing[:drawing].is_a?(Hash) && drawing[:end].is_a?(Hash)

        turn = Bridge::TurnAccumulator.from_wire(drawing[:drawing])
        id = prompt[:turn_id] || prompt["turn_id"]
        return nil unless id && turn[:turn_id].to_s == id.to_s
        # An older worker sends a line its parse didn't check (the unfold
        # would raise after the prompt line is drawn).
        return nil unless Bridge::TurnDrawings.rows?(turn[:parts])

        [turn, EventRenderer.symbolize(Bridge::TurnAccumulator.from_wire(drawing[:end]))]
      end

      # The prompt's turn (its opening at +from+ in +messages+) drawn from
      # its messages (TurnRanges, Synth.safe_line) with the link's saved
      # records of it (this machine's, or chi web's for --remote) and the
      # snapshot's +cards+ (its CardStore rows), as [turn, end event]; nil
      # when no turn opens there.
      def made_turn(messages, from, cards)
        # Its opening, or the range that holds it (a wake turn's report, its note the opening).
        range = Bridge::TurnRanges.of(messages).find { |r| r.opening == from || r.range.cover?(from) }
        return nil unless range

        # Tool records first: a remote link reads both in one request then
        # (RemoteLink#saved_tool_records keeps it for #saved_turn_record).
        tools = range.turn_id ? Array(@link.saved_tool_records(range.turn_id)) : []
        record = range.turn_id && @link.saved_turn_record(range.turn_id)
        line = Bridge::TurnDrawings::Synth.safe_line(messages, range, record: record, tools: tools, entries: cards)
        [Bridge::TurnAccumulator.from_wire(line.drawing), EventRenderer.symbolize(Bridge::TurnAccumulator.from_wire(line.end))]
      end

      # The last turn from its drawing, through the renderer as live drew it
      # (the running turn's join path, AttachedLoop#render_current_turn): its
      # rows with their status and duration, a retry's line, a hook's notice,
      # steers, merged input and reminders; no step text (the live ticker's)
      # and no cards (the snapshot's cards are drawn after). Then its end: a
      # cancel's or a failure's line from the end event, else the empty
      # answer's notice or the saved answer (+after+, the messages after the
      # prompt).
      def render_drawn_turn(turn, ending, after)
        Bridge::TurnAccumulator.replay_events(turn).each do |event|
          # The prompt line named its images already.
          event[:type] == :turn_started ? @renderer.call(event.except(:images)) : replay_row(event)
        end
        case ending[:type]
        when :turn_canceled, :turn_failed then @renderer.call(ending)
        else
          empty = ending.dig(:turn_summary, :empty_answer)
          empty ? @screen.commit(format_empty_answer_line(empty[:retries], empty[:refusal])) : render_join_answer(after)
        end
        # A call the turn never answered left the tool slot running.
        @view.finish_thinking_spinner
      end

      # The context notes that came since the last prompt (+from+, its index
      # in +messages+; all of them in a session with none), after the
      # exchange the header shows.
      def render_join_notes(messages, from, after_exchange: false)
        return if after_exchange != !from.nil?

        messages[(from ? from + 1 : 0)..].select { |m| ContextNote.note?(m) }.each do |m|
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
