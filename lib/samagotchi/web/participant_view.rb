# frozen_string_literal: true

require_relative "../output_formatter"
require_relative "../steer"
require_relative "../turn_origin"
require_relative "../participant_mode"
require_relative "../revise_anchor"
require_relative "../verify_anchor"
require_relative "../redact"
require_relative "../file_ref"

module Samagotchi
  module Web
    # What a participant sees of their session (D5 a): prompts and replies
    # with their authors, one-line tool rows (the tool's name, and a
    # project-relative path for a file tool), turn boundaries, and the
    # waiting states. Verdict cards expose only their anchor, verdict,
    # reason and author. Never: tool output or arguments, thinking, context
    # notes, plugin steers, automatic input, other cards, commands,
    # questions' internals, memories, the working set, cost or timing, host paths.
    #
    # Every read a participant reaches goes through here: the stream's
    # events (#event, ParticipantStreamFilter), the review route's
    # conversation (#messages) and turn in progress (#current_turn). Each
    # is an allowlist that builds a new hash from named fields, so a field
    # added to an event later never reaches a participant until it is
    # named here, and an event type not named is dropped. Every string
    # that goes out passes Redact (lib/samagotchi/redact.rb: secret shapes, the owner's token, the
    # home folder), defence in depth only: the allowlist is the control.
    # Pure: no I/O; keys of what comes in may be strings (JSON) or symbols.
    module ParticipantView
      # A turn's participant_mode values the view passes on (ParticipantMode).
      PARTICIPANT_MODES = [ParticipantMode::REVIEW.to_s, ParticipantMode::PAIR.to_s].freeze

      # The stream's event types a participant gets, each rebuilt by the
      # method named. Every other type is dropped.
      EVENTS = {
        "turn_started" => :turn_started,
        "turn_completed" => :turn_ended,
        "turn_canceled" => :turn_ended,
        "turn_failed" => :turn_ended,
        # A Verify fresh child's verdict landing on its card: the card's
        # fields only (#verdict_record).
        "verdict_recorded" => :verdict_recorded,
        "generation_chunk" => :generation_chunk,
        "generation_retrying" => :generation_retrying,
        "tool_call_started" => :tool_call_started,
        "tool_call_completed" => :tool_call_completed,
        # Queue changes: the viewer's own in the owner's shape (the main
        # page matches its bubbles by them), anyone else's bare (the
        # participant page re-reads its review data on each).
        "turn_enqueued" => :turn_enqueued,
        "turn_dequeued" => :turn_dequeued,
        "input_merged" => :input_merged,
        # The owner's question, approval or Continue offer: "waiting for the
        # owner", nothing of it.
        "question_requested" => :bare,
        "question_answered" => :bare,
        "question_cancelled" => :bare,
        "continue_offered" => :bare,
        "continue_resolved" => :bare,
        # The cursor can't be replayed (or a join): the page re-reads.
        "snapshot" => :bare,
        "reset" => :bare
      }.freeze

      # The types chi emits that a participant never gets, named so the
      # spec that walks every emitted type (spec/web/participant_view_spec)
      # fails for a new one until it is decided here or in EVENTS. Not
      # named is dropped all the same.
      DROPPED = %w[
        after_generation after_tool_call after_turn answer_display before_generation before_tool_call before_turn
        card command_output command_queued command_ran context_added context_status empty_answer_retry
        generation_cancelled generation_completed generation_progress generation_started guardrail_warning hook_notice
        llm_context_edited merged_input objectives_updated participants_changed pending_input_merged plugin_init_finished
        plugin_init_started plugin_init_wait prompt_restored question question_relay reasoning_history_refused
        recap_ready reminder_injected sampling_refused session_end session_start side_usage steer_cut thinking_dropped
        thinking_refused tool_dispatch_completed tool_dispatch_started used_memories_updated working_set_updated
      ].freeze

      # A merged input line's saved sources a participant sees: a person's
      # (the owner, chi send, a participant). A delegate's report, a
      # plugin's or an automatic client's input is not.
      PERSON_SOURCES = ["", "chi_send", Steer::PARTICIPANT_SOURCE].freeze

      # A tool call's status words a row may carry.
      STATUSES = %w[ok error blocked stopped denied].freeze

      module_function

      # @param event [Hash] a client event (ClientEvent's shape; string keys
      #   from the stream's JSON)
      # @param own_enqueued [#include?] the enqueued ids of the viewer's own
      #   turns (a :turn_dequeued names no author; ParticipantStreamFilter's)
      # @return [Hash, nil] what a participant gets, string keys; nil: nothing
      def event(event, viewer, own_enqueued: [])
        return nil unless event.is_a?(Hash)

        type = field(event, :type).to_s
        method = EVENTS[type] or return nil
        out = method == :turn_dequeued ? turn_dequeued(event, viewer, own_enqueued) : send(method, event, viewer)
        out && Redact.deep(out, viewer)
      end

      # A turn queued: the viewer's own with its enqueued id, client id,
      # prompt, delivery and author (never its images); anyone else's bare.
      def turn_enqueued(event, viewer)
        entry = queued_entry(event, viewer) or return bare(event, viewer)

        { "type" => "turn_enqueued", **seq(event), **entry }
      end

      # A queued turn taken back or refused: the viewer's own with its
      # enqueued id (never the client that took it back); anyone else's bare.
      def turn_dequeued(event, viewer, own_enqueued)
        enqueued_id = field(event, :enqueued_id)
        return bare(event, viewer) unless enqueued_id.is_a?(String) && !enqueued_id.empty? && own_enqueued.include?(enqueued_id)

        { "type" => "turn_dequeued", **seq(event), "enqueued_id" => enqueued_id }
      end

      # Input merged into the running turn: the viewer's own lines (their
      # origins' enqueued ids) and how many, bare when none is theirs. The
      # others' (a delegate's report, another person's line) are not named
      # nor counted. No text: it comes with the turn's messages.
      def input_merged(event, viewer)
        own = Array(field(event, :origins)).filter_map do |origin|
          next unless origin.is_a?(Hash) && viewer.own?(field(origin, :author))

          enqueued_id = field(origin, :enqueued_id)
          next unless enqueued_id.is_a?(String) && !enqueued_id.empty?

          { "enqueued_id" => enqueued_id, "client_id" => field(origin, :client_id).to_s, "author" => field(origin, :author).to_s }
        end
        return bare(event, viewer) if own.empty?

        { "type" => "input_merged", **seq(event), "count" => own.size, "origins" => own }
      end

      # A turn's start: who wrote it, and its prompt when a person sent it
      # (an automatic turn's prompt, a reminder's or a task's, is not
      # shown: a person is the owner's web or TUI, chi send, a participant,
      # or no origin, an in-process turn: the owner's; TurnOrigin#human?).
      # +mine+ when the viewer queued it.
      def turn_started(event, viewer)
        origin = TurnOrigin.of(field(event, :origin))
        author = field(event, :author) || origin.author
        out = { "type" => "turn_started", **id_fields(event), **time_field(event) }
        out.merge!(author_fields(author, field(event, :author_name), viewer, field(event, :participant_mode)))
        prompt = field(event, :prompt)
        if field(event, :continue)
          out["continue"] = true
        elsif origin.human?
          out["prompt"] = prompt.to_s unless prompt.nil?
        else
          out["automatic"] = true
        end
        out
      end

      # A drawing's filtered turn_started (#event's) with +prompt+, the
      # filtered messages' prompt of its turn; nil: an automatic turn's
      # start, no prompt (a Continue's has none either way). Any other event
      # as it is.
      def drawing_start(event, prompt)
        return event unless event["type"] == "turn_started"

        out = event.except("prompt", "automatic")
        return out if out["continue"]
        return out.merge("prompt" => prompt) if prompt

        out.except("continue").merge("automatic" => true)
      end

      def turn_ended(event, viewer)
        out = { "type" => field(event, :type).to_s, **id_fields(event) }
        verdict = verdict_record(field(event, :verdict), viewer)
        out["verdict"] = verdict if verdict
        # The turn a completed Revise turn revised (as on its prompt; the
        # page doesn't draw stacks yet).
        revises = ReviseAnchor.from(field(event, :revises))
        out["revises"] = revises.to_file if revises
        out
      end

      def verdicts(records, viewer)
        Array(records).filter_map { |record| verdict_record(record, viewer) }
      end

      def verdict_record(raw, viewer)
        return unless raw.is_a?(Hash)

        anchor = VerifyAnchor.from(field(raw, :anchor))
        verdict = field(raw, :verdict).to_s
        reason = field(raw, :reason)
        check_turn_id = field(raw, :check_turn_id)
        by = field(raw, :by)
        return unless anchor && %w[confirmed refuted unclear].include?(verdict) && reason.is_a?(String)
        return unless check_turn_id.is_a?(String) && !check_turn_id.empty?
        return unless by.nil? || by.is_a?(String)

        out = {
          "anchor" => { "turn_id" => anchor.turn_id, "quote" => anchor.quote },
          "verdict" => verdict, "reason" => reason, "by" => by,
          "check_turn_id" => check_turn_id
        }
        # A Verify fresh verdict: which verdict it checked again (never the
        # child's id: a participant can't open that session).
        of = field(raw, :of)
        out.merge!("fresh" => true, "of" => of) if field(raw, :fresh) == true && of.is_a?(String) && !of.empty?
        Redact.deep(out, viewer)
      end

      def verdict_recorded(event, viewer)
        verdict = verdict_record(field(event, :verdict), viewer) or return nil
        { "type" => "verdict_recorded", "verdict" => verdict }
      end

      # The reply's visible text only: never thinking, a tool call's bytes
      # or the provider's counts. A chunk with no text is dropped.
      def generation_chunk(event, _viewer)
        text = field(event, :text)
        return nil unless text.is_a?(String) && !text.empty?

        { "type" => "generation_chunk", "text" => text, **iteration(event) }
      end

      # A dropped stream asked again: its text so far is void when restarted.
      def generation_retrying(event, _viewer)
        out = { "type" => "generation_retrying", **iteration(event) }
        out["restarted"] = true if field(event, :restarted)
        out
      end

      def tool_call_started(event, viewer)
        { "type" => "tool_call_started", **tool_row(field(event, :tool), field(event, :ref), viewer), **call_ids(event) }
      end

      def tool_call_completed(event, _viewer)
        out = { "type" => "tool_call_completed", **call_ids(event) }
        activity = field(event, :activity)
        status = activity.is_a?(Hash) ? field(activity, :status).to_s : ""
        out["status"] = status if STATUSES.include?(status)
        out
      end

      # Its type alone (and the cursor it was sent at).
      def bare(event, _viewer)
        { "type" => field(event, :type).to_s, **seq(event) }
      end

      # @param shown [Array<Hash>] the owner's display messages
      #   (App#messages_for_display with parts: true)
      # @param automatic [#include?] the ids of turns no person sent (their
      #   analytics records' +automatic+, and the running one's): their
      #   prompt is shown as an automatic turn, without its text
      # @return [Array<Hash>] {role: "user", content, turn_id, author,
      #   author_name, mine, automatic, images, at} and {role: "assistant",
      #   content, tools: [{tool, path}], at}; no notes, steers, automatic
      #   input or empty-answer markers, but a wake turn's start as an
      #   automatic turn (#wake_start). html is added by the caller, from
      #   this (redacted) content.
      def messages(shown, viewer, automatic: [])
        Array(shown).filter_map do |message|
          next unless message.is_a?(Hash)

          out = case field(message, :role).to_s
                when "user" then user_message(message, viewer, automatic)
                when "assistant" then assistant_message(message, viewer)
                when "note" then wake_start(message)
                end
          out && Redact.deep(out, viewer)
        end
      end

      # A user message a participant sees: a turn's prompt (it has the
      # turn's id) or a person's line merged into a turn. Every other user
      # message is dropped: the owner's `!` line and its output, a
      # delegate's report (a wake turn's input: only its turn's start is
      # kept, #wake_start), the notes chi adds (a Continue the owner
      # declined). Any other message from a source that isn't a person's is
      # dropped whatever it is.
      def user_message(message, viewer, automatic = [])
        source = field(message, :source).to_s
        turn_id = field(message, :turn_id)
        merged = field(message, :merged)
        return (turn_id && !merged ? wake_start(message) : nil) unless PERSON_SOURCES.include?(source)
        return nil unless turn_id || merged

        out = { "role" => "user", **time_field(message) }
        if turn_id && automatic.include?(turn_id.to_s)
          out.merge!("content" => "", "automatic" => true, "turn_id" => turn_id.to_s)
          return out
        end
        out["content"] = field(message, :content).to_s
        out["turn_id"] = turn_id.to_s if turn_id
        out["merged"] = true if merged
        # The turn it revised (a Revise stack; the page doesn't draw it yet).
        revises = ReviseAnchor.from(field(message, :revises))
        out["revises"] = revises.to_file if revises && turn_id && !merged
        out.merge!(author_fields(field(message, :author), field(message, :author_name), viewer,
                                 field(message, :participant_mode)))
        images = field(message, :images)
        out["images"] = images.size if images.is_a?(Array) && !images.empty?
        out.merge!(drawn_field(message))
      end

      # A wake turn's start (its prompt a delegate's report or a context
      # note, MessageDisplay's turn_start note): the turn's boundary only,
      # as an automatic turn with no text, so its answer is never read as
      # one more reply of the turn before (Verify, verdict cards, claim
      # links group by these). Nothing of the report or the note. nil for
      # a message that starts no turn.
      def wake_start(message)
        turn_id = field(message, :turn_id)
        return nil if turn_id.to_s.empty?
        return nil if field(message, :role).to_s == "note" && field(message, :turn_start) != true

        { "role" => "user", **time_field(message), "content" => "", "automatic" => true, "turn_id" => turn_id.to_s }
      end

      def assistant_message(message, viewer)
        parts = field(message, :parts)
        tools = parts.is_a?(Hash) ? Array(field(parts, :tools)) : []
        rows = tools.filter_map { |tool| tool.is_a?(Hash) ? tool_row(field(tool, :tool), field(tool, :ref), viewer) : nil }
        content = field(message, :content).to_s
        return nil if content.strip.empty? && rows.empty?

        out = { "role" => "assistant", "content" => content, **time_field(message) }
        out["tools"] = rows unless rows.empty?
        out.merge!(drawn_field(message))
      end

      # The turn whose drawing draws this message (MessageDisplay's +drawn+
      # stamp: a turn id), for the main page's show; none on the review read.
      def drawn_field(message)
        drawn = field(message, :drawn)
        drawn.is_a?(String) && !drawn.empty? ? { "drawn" => drawn } : {}
      end

      # A finished turn's drawing end (Bridge::TurnDrawings' end, its
      # END_KEYS) as a participant may read it: how it ended, its turn and
      # duration, and how many steps a failure kept. Never a failure's
      # summary, message or class (they may name a host path), a cancel's
      # reason or who stopped it.
      def drawing_end(raw, turn_id)
        out = { "type" => (TURN_ENDS.include?(field(raw, :type).to_s) ? field(raw, :type).to_s : "turn_completed"),
                "turn_id" => turn_id.to_s }
        duration = field(raw, :duration_ms)
        out["duration_ms"] = duration if duration.is_a?(Integer)
        kept = field(raw, :kept_steps)
        out["kept_steps"] = kept if kept.is_a?(Integer)
        out
      end

      TURN_ENDS = %w[turn_completed turn_canceled turn_failed].freeze

      # The turn in progress (TurnAccumulator#current_turn, string keys
      # from the Bridge's snapshot) as a participant sees it: its start
      # (#turn_started's fields), the reply's text so far, its tool rows,
      # and whether it waits for the owner (a question, an approval).
      # @return [Hash, nil]
      def current_turn(turn, viewer)
        return nil unless turn.is_a?(Hash)

        started = turn_started(turn.merge("type" => "turn_started"), viewer)
        started.delete("type")
        text = +""
        tools = []
        Array(field(turn, :parts)).each do |part|
          next unless part.is_a?(Hash)

          case field(part, :kind).to_s
          when "text" then text << field(part, :text).to_s
          when "tool"
            row = tool_row(field(part, :tool), field(part, :ref), viewer)
            status = field(part, :status).to_s
            row["status"] = status if status == "running" || STATUSES.include?(status)
            tools << row
          end
        end
        out = started.merge("text" => text, "tools" => tools)
        # The running generation's phase (Bridge#with_generation: the main
        # page's delivery-line clock): whether it only thinks so far, and its
        # age; nothing of what it thinks.
        generation = field(turn, :generation)
        if generation.is_a?(Hash)
          gen = {}
          gen["thinking_only"] = field(generation, :thinking_only) if [true, false].include?(field(generation, :thinking_only))
          gen["age"] = field(generation, :age) if field(generation, :age).is_a?(Numeric)
          out["generation"] = gen
        end
        out["waiting_for_owner"] = true if field(turn, :pending_question)
        Redact.deep(out, viewer)
      end

      # A queued entry (a Bridge snapshot's +queued+ row) when it is the
      # viewer's own, in the owner's shape: its enqueued id, client id,
      # prompt, delivery and author. Never its images. nil for another
      # person's (their prompt).
      def queued_entry(entry, viewer)
        return nil unless entry.is_a?(Hash) && viewer.own?(field(entry, :author))

        out = { "enqueued_id" => field(entry, :enqueued_id).to_s, "client_id" => field(entry, :client_id).to_s,
                "prompt" => field(entry, :prompt).to_s, "author" => field(entry, :author).to_s }
        delivery = field(entry, :delivery).to_s
        out["delivery"] = delivery if DELIVERIES.include?(delivery)
        Redact.deep(out, viewer)
      end

      DELIVERIES = %w[queue next_step].freeze

      # A turn record's fields a participant reads: its id and times (the
      # turn time) and its speed. Never its cost, tokens, model, author,
      # cancel reason or failure.
      TURN_RECORD_KEYS = %w[id started_at completed_at duration_ms decode_tps tps_source].freeze
      # The running turn's (SessionMetrics#active_turn_snapshot).
      ACTIVE_TURN_KEYS = %w[id started_at duration_ms].freeze

      # The show's timing (SessionShow#timing_from) as a participant may
      # read it: the session's clock, each turn's duration and speed, the
      # running turn's start, and the context's fill (its token counts).
      # Never tool_records (guardrail judgment ids, System 1 labels),
      # active_tools, tokens, model_segments (cost per model), memory_index
      # (memory names) or side (side requests' cost).
      def timing(payload)
        return nil unless payload.is_a?(Hash)

        records = Array(field(payload, :turn_records)).filter_map { |record| pick(record, TURN_RECORD_KEYS) }
        context = field(payload, :context)
        {
          "started_at" => string_or_nil(field(payload, :started_at)),
          "last_activity_at" => string_or_nil(field(payload, :last_activity_at)),
          "session_duration_ms" => number_or_nil(field(payload, :session_duration_ms)),
          "turn_records" => records,
          "tool_records" => [],
          "turn_count" => number_or_nil(field(payload, :turn_count)),
          "active_turn" => pick(field(payload, :active_turn), ACTIVE_TURN_KEYS),
          "active_tools" => [],
          "context" => pick(context, %w[used_tokens window_tokens]),
          "tokens" => nil,
          "model_segments" => [],
          "memory_index" => nil,
          "side" => nil
        }
      end

      # +keys+ of +hash+ whose values are plain (a string or a number), nil
      # for a hash with none.
      def pick(hash, keys)
        return nil unless hash.is_a?(Hash)

        out = keys.each_with_object({}) do |key, kept|
          value = field(hash, key.to_sym)
          kept[key] = value if value.is_a?(String) || (value.is_a?(Numeric) && value.to_f.finite?)
        end
        out.empty? ? nil : out
      end

      def string_or_nil(value) = value.is_a?(String) ? value : nil

      def number_or_nil(value) = value.is_a?(Numeric) && value.to_f.finite? ? value : nil

      # A tool row: the tool's name, and for a file tool the path relative
      # to the session's folder when it is inside it. Never its arguments.
      # The row's +ref+ is the owner's shape (FileRef#to_h: kind, path, the
      # lines) with the relative path, for the main page's refs.js; +path+
      # is the participant page's flat copy until that page goes.
      def tool_row(tool, ref, viewer)
        row = { "tool" => tool.to_s }
        path = ref.is_a?(Hash) ? field(ref, :path) : nil
        relative = project_path(path, viewer.cwd, home: viewer.home)
        return row unless relative

        row["path"] = relative
        file = { "kind" => FileRef::KIND, "path" => relative }
        %i[line end_line].each do |key|
          value = field(ref, key)
          file[key.to_s] = value if value.is_a?(Integer) && value.positive?
        end
        row.merge("ref" => file)
      end

      # +path+ relative to +cwd+ when it is inside it, else nil. None when
      # the session's folder is the home folder or / (everything would be
      # "inside": chi's own state and config, other projects).
      def project_path(path, cwd, home: nil)
        return nil unless path.is_a?(String) && cwd.is_a?(String) && !cwd.empty?

        root = File.expand_path(cwd)
        return nil if root == "/" || (home && root == File.expand_path(home.to_s))

        full = File.expand_path(path, root)
        return nil unless full.start_with?("#{root}/")

        full.delete_prefix("#{root}/")
      rescue ArgumentError
        nil
      end

      # A turn's author as a participant sees it: the participant's id and
      # name, or none for the owner's; +mine+ for the viewer's own; the
      # turn's +mode+ (its participant_mode stamp: review or pair) when
      # it has one.
      def author_fields(author, name, viewer, mode = nil)
        return {} unless Steer.participant_author?(author)

        out = { "author" => author.to_s }
        out["author_name"] = name.to_s if name.is_a?(String) && !name.empty?
        out["participant_mode"] = mode.to_s if PARTICIPANT_MODES.include?(mode.to_s)
        out["mine"] = true if viewer.own?(author)
        out
      end

      # When it happened (MessageTime's stamp, a turn's start): the page's
      # hover and gap dividers. A wall time only, nothing of what was done.
      def time_field(item)
        at = field(item, :at)
        at.is_a?(String) && !at.empty? ? { "at" => at } : {}
      end

      def id_fields(event)
        out = seq(event)
        turn_id = field(event, :turn_id)
        out["turn_id"] = turn_id.to_s if turn_id
        out
      end

      def seq(event)
        seq = field(event, :event_seq)
        seq.is_a?(Integer) ? { "event_seq" => seq } : {}
      end

      def iteration(event)
        value = field(event, :iteration)
        value.is_a?(Integer) ? { "iteration" => value } : {}
      end

      def call_ids(event)
        out = iteration(event)
        index = field(event, :call_index)
        out["call_index"] = index if index.is_a?(Integer)
        out
      end

      # Markup a reply may hold whole (closed): kept for the tool rows read
      # from it (MessageParts) and stripped by the display.
      CLOSED_BLOCKS = Regexp.union(OutputFormatter::QWEN_THINK_RE, OutputFormatter::QWEN_TOOL_CALL_RE,
                                   OutputFormatter::GEMMA_TOOL_CALL_RE, OutputFormatter::GEMMA_THOUGHT_RE)
      # A close with no open before it: what came before was thinking (the
      # raw loop saves prefill + response).
      BARE_CLOSES = ["</think>", "<channel|>"].freeze
      # An open with no close after it (a cut-off thought, a tool call the
      # loop recovered): everything from it on is the model's own.
      OPENS = ["<think>", "<tool_call>", "<|tool_call>", "<|channel>", "<|tool_response>", "<tool_response>", "<|think|>"].freeze

      # A saved model message's raw content as a participant may read it:
      # closed blocks kept (the display strips them, its tool rows come from
      # them), anything before a bare close and from an unclosed open on
      # dropped, which the display's strip would only untag (leaving the
      # thinking or the tool call's arguments as text).
      def visible_raw(text)
        held = []
        out = text.to_s.gsub(CLOSED_BLOCKS) do |block|
          held << block
          "\u0000#{held.size - 1}\u0000"
        end
        close = BARE_CLOSES.filter_map { |marker| (at = out.rindex(marker)) && (at + marker.size) }.max
        out = out[close..] if close
        cut = OPENS.filter_map { |marker| out.index(marker) }.min
        out = out[0, cut] if cut
        out.gsub(/\u0000(\d+)\u0000/) { held[Regexp.last_match(1).to_i] }
      end

      # A turn's saved reply (the reply file a wait reads) as a participant
      # may read it: no cut-off or closed thinking or tool call, redacted.
      def reply(text, viewer)
        Redact.text(OutputFormatter.strip_markup(visible_raw(text)), viewer)
      end

      def field(hash, key)
        return nil unless hash.is_a?(Hash)

        hash.key?(key) ? hash[key] : hash[key.to_s]
      end
    end
  end
end
