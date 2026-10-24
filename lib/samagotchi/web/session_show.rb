# frozen_string_literal: true

require "time" # Time.iso8601
require "uri"

require_relative "../analytics_file"
require_relative "../answer_refs"
require_relative "../answer_tail"
require_relative "../output_formatter"
require_relative "../question_asked"
require_relative "../session_commands"
require_relative "../session_metrics"
require_relative "../session_setting"

module Samagotchi
  module Web
    # GET /api/sessions/:id, the page's session read, and its light re-reads
    # (?cards=1, ?tail=1, ?timing=1; ?brief=1 is SessionAccessRoutes'
    # handle_brief_read), GET /api/sessions/:id/output, and the timing
    # payload they carry. Included in App: its ROUTES name the handlers, and
    # its helpers (json_response, error_response, bridge_get_json,
    # session_owner, session_to_json, …) and ivars (@manager,
    # @session_class, @state_dir, @markdown_renderer) answer. A participant's
    # read goes to ParticipantAccess (participant_show). See
    # docs/architecture.md (chi web's routes) and docs/internals/working-set.md.
    module SessionShow
      private

      def handle_show(req, id)
        return participant_show(id) unless principal(req).owner?

        # The page's light re-reads: never the whole conversation.
        return handle_cards_read(id) if req.params["cards"] == "1"
        return handle_tail_read(req, id) if req.params["tail"] == "1"
        return handle_timing_read(id) if req.params["timing"] == "1"
        return handle_brief_read(id) if req.params["brief"] == "1"

        session = @session_class.load(id, state_dir: default_state_dir)
        # Read-only preview: selecting a session never spawns a worker.
        # The worker is woken only on POST /turn (handle_turn) via
        # SessionManager.resume_session + write_turn_input. This avoids
        # replaying last_prompt and spamming workers on preview scrub.
        # last_event_seq is nil when no live bridge, so the frontend stays
        # silent until the first Send.
        #
        # A live worker's snapshot is the truth (the session file lags its
        # Engine): the messages, the turn in progress and the prompts queued
        # behind it, all at one event_seq the client streams on from.
        live = bridge_get_json(id, "snapshot")
        turn_snapshot = live && live["snapshot"]
        snapshot = live && live["session_state_snapshot"]
        last_event_seq = live_or_saved(snapshot, "event_seq") { bridge_event_seq(id) }
        current_turn = turn_snapshot && turn_snapshot["current_turn"]
        owner = session_owner(id)
        pending = shown_pending_question(session, turn_snapshot, owner)
        # What the worker's server said it served for that model (after a turn);
        # without a worker, what the session's analytics.json last saved.
        persisted = snapshot ? nil : read_analytics(id)
        session_json = shown_session_json(session, snapshot, owner, persisted)
        raw_messages = live_or_saved(turn_snapshot, "messages") { session.messages }
        timing = timing_payload(id, live_metrics: snapshot && snapshot["metrics"], persisted: persisted)
        json_response(200, {
          session: session_json,
          history: read_history(id),
          messages: messages_for_display(raw_messages, parts: req.params["parts"] == "1",
                                                       cwd: session.working_directory),
          failed_turn: failed_turn_for(session, raw_messages),
          current_turn: current_turn,
          queued: snapshot_list(turn_snapshot, "queued"),
          # Commands waiting for the running turn's end (their bubbles).
          queued_commands: snapshot_list(turn_snapshot, "queued_commands"),
          recap: turn_snapshot && turn_snapshot["recap"],
          saved_recap: saved_recap_for(id, session, turn_snapshot),
          continue_offer: turn_snapshot && turn_snapshot["continue_offer"],
          guardrail_warning: turn_snapshot && turn_snapshot["guardrail_warning"],
          plugin_warning: turn_snapshot && turn_snapshot["plugin_warning"],
          # Plugins' slow setup still running (chi.init): the page's init row.
          init_tasks: snapshot_list(turn_snapshot, "init_tasks"),
          cards: cards_for_display(live_or_saved(turn_snapshot, "cards") { saved_cards(id) }, cwd: session.working_directory),
          # The composer's / autocomplete; the built-ins until a worker
          # names its plugins' too.
          commands: turn_snapshot&.fetch("commands", nil) || SessionCommands.builtin_registry.listing,
          markdown_warning: @markdown_renderer.warning,
          **viewer_capabilities(req),
          pending_question: pending,
          last_event_seq: last_event_seq,
          # The stream cursor `<seq>-<epoch>`: a later worker resets it
          # instead of taking the seq as its own. Only the snapshot has it.
          last_event_id: turn_snapshot && turn_snapshot["event_id"],
          timing: timing
        })
      end

      # A list in the worker's turn +snapshot+ (queued prompts, commands,
      # init tasks); [] without a worker.
      def snapshot_list(snapshot, key) = Array(snapshot&.[](key))

      # A live worker's +key+ as its reading (+live+: a snapshot, a tail)
      # says it, nil included; without a worker (+live+ nil) the block's,
      # the server's own reading of the saved session. A nil value from a
      # worker is not a missing one (contrast SessionSetting#snapshot_value's
      # :or).
      def live_or_saved(live, key)
        live ? live[key] : yield
      end

      # The file's question only while a worker owns the session: one a
      # dead worker saved can't be answered (its turn is gone), nor a chi
      # REPL's (it shares nothing with the web).
      # A question between turns (the step-limit one) is the snapshot's own.
      # Its refs (the asking reply's, QuestionAsked) are checked again.
      def shown_pending_question(session, turn_snapshot, owner)
        pending = if turn_snapshot
                    current_turn = turn_snapshot["current_turn"]
                    current_turn ? current_turn["pending_question"] : turn_snapshot["pending_question"]
                  elsif owner&.worker?
                    session.pending_question&.to_h
                  end
        with_question_refs(pending, cwd: session.working_directory)
      end

      # A pending question (a snapshot's, the session file's or a saved
      # card's) with its refs checked again, under a question's caps
      # (QuestionAsked): a stored file is never trusted, and what isn't
      # valid any more is dropped. The question as it was without refs.
      def with_question_refs(pending, cwd:)
        return pending unless pending.is_a?(Hash)

        key = [:refs, "refs"].find { |name| pending.key?(name) } or return pending
        refs = Samagotchi::AnswerRefs.for_display(pending[key], cwd: cwd, max_refs: Samagotchi::QuestionAsked::MAX_REFS,
                                                                max_bytes: Samagotchi::QuestionAsked::MAX_BYTES)
        refs.empty? ? pending.except(key) : pending.merge(key => refs)
      end

      # The full show's session part: the file's, with what a live worker's
      # state +snapshot+ knows first (its model, status, served model,
      # prompt notes and chips); without one, the served model from
      # +persisted+ (analytics.json). Sets a worker's model on +session+:
      # a /model in the worker changes it before the file catches up.
      def shown_session_json(session, snapshot, owner, persisted)
        session.model_name = snapshot["model_name"] if snapshot && !snapshot["model_name"].to_s.empty?
        session_json = session_to_json(session, status: displayed_status(session, snapshot, owner: owner), owner: owner)
        if snapshot
          session_json = session_json.merge(served_model: snapshot["served_model"], served_model_for: snapshot["served_model_for"],
                                            served_expected_by: snapshot["served_expected_by"])
          # The model notes its prompt carries now (a /model there changes them).
          session_json = session_json.merge(prompt_notes: snapshot["prompt_notes"]) if snapshot["prompt_notes"].is_a?(Array)
        else
          session_json = session_json.merge(saved_served_model(session, persisted))
        end
        # The per-session settings' chips (the info bar's llm ctx, think,
        # reasoning and tools): the worker's, else worked out here from the
        # session file (SessionSetting#snapshot_value, #saved_summary).
        SessionSetting::ALL.each do |setting|
          chip = setting.snapshot_value(snapshot) { setting.saved_summary(session, registry: host_registry) }
          session_json = session_json.merge(setting.key => chip)
        end
        session_json
      end

      # ?cards=1: the page's re-read when a card arrives, for its rendered
      # body (the stream carries the card's plain text only). The worker's
      # cards from its light GET tail, else the saved ones; the session file
      # is only stat'ed (the 404), never parsed.
      def handle_cards_read(id)
        return error_response(404, "not_found", "Session not found: #{id}") unless session_exists?(id)

        tail = live_tail(id)
        json_response(200, { cards: cards_for_display(live_or_saved(tail, "cards") { saved_cards(id) }) })
      end

      # ?tail=1: the page's re-read at the end of a turn wants the final
      # answer's rendered markdown, the status and the timing, not the whole
      # history again (nor a render of every earlier answer). Live: the
      # worker's GET tail alone (no session file read); else the file. The
      # session part is what the page reads of it (id, status, used memory
      # names, the model notes its prompt carried: the first turn's build or
      # a /model records them). ?turn_id=: that turn's answer (a queued
      # turn's page re-reads after the next one started). The timing's records
      # are the newest turn's (#recent_timing), which the page merges by id
      # (the page still sends ?recent=1, which is accepted and not needed).
      def handle_tail_read(req, id)
        return error_response(404, "not_found", "Session not found: #{id}") unless session_exists?(id)

        turn_id = req.params["turn_id"].to_s.strip
        turn_id = nil if turn_id.empty?
        tail = live_tail(id, turn_id: turn_id)
        state = tail && tail["session_state_snapshot"]
        state = nil unless state.is_a?(Hash)
        if state
          status, used, notes = state.values_at("status", "used_memory_names", "prompt_notes")
          answer = tail["answer"]
          cwd = tail_working_directory(id, tail, answer)
          answer = without_file_refs(answer) unless cwd
          messages = last_assistant_for_display([answer].compact, cwd: cwd)
        else
          session = @session_class.load(id, state_dir: default_state_dir)
          status = displayed_status(session)
          used = session.used_memory_names
          notes = session.prompt_notes.map(&:to_h)
          messages = last_assistant_for_display(session.messages, turn_id: turn_id, cwd: session.working_directory)
        end
        session_json = { id: id, status: status, used_memory_names: Array(used), prompt_notes: Array(notes) }
        live_metrics = state && state["metrics"]
        timing = recent_timing(id, live_metrics)
        json_response(200, {
          tail: true,
          session: session_json,
          messages: messages,
          markdown_warning: @markdown_renderer.warning,
          **viewer_capabilities(req),
          timing: timing
        })
      end

      # The folder the live tail's answer's file refs must stay under: the
      # worker's (its tail's working_directory), else the hub's session list
      # entry's (a worker from before the field, or read through its
      # snapshot), else, only when the answer has refs to check, the session
      # file's, as the full read takes it. nil when none is known: the
      # caller drops the file refs rather than show them unchecked.
      # @return [String, nil]
      def tail_working_directory(id, tail, answer)
        known = ->(dir) { dir.is_a?(String) && !dir.empty? }
        cwd = tail["working_directory"]
        cwd = @hub&.working_directory(id) unless known.call(cwd)
        return cwd if known.call(cwd)
        return nil unless answer.is_a?(Hash) && (answer[AnswerRefs::KEY.to_s] || answer[AnswerRefs::KEY])

        cwd = @session_class.load(id, state_dir: default_state_dir).working_directory
        known.call(cwd) ? cwd : nil
      rescue ArgumentError, KeyError, SystemCallError
        nil
      end

      # ?timing=1: the whole timing (every record, analytics.json merged with
      # the live ones) and turn_count, when the page's merge comes up short.
      # The worker's GET state, never its messages.
      def handle_timing_read(id)
        return error_response(404, "not_found", "Session not found: #{id}") unless session_exists?(id)

        state = bridge_get_json(id, "state")
        json_response(200, { timing: timing_payload(id, live_metrics: state && state["session_state_snapshot"]&.fetch("metrics", nil)) })
      end

      def session_exists?(id)
        @session_class.exist?(id, state_dir: default_state_dir)
      rescue ArgumentError
        false
      end

      # The worker's light read (Bridge GET tail): {"session_state_snapshot",
      # "working_directory", "answer", "cards", "event_seq", "event_id"}. A
      # worker from before the route answers 404 not_found: its GET snapshot,
      # in the same shape (the answer by AnswerTail; no working_directory). Anything else (no worker, a refused connect, a
      # 500, a timeout) is nil: the caller reads the disk, with no second
      # try at a worker that failed once.
      # @return [Hash, nil]
      def live_tail(id, turn_id: nil)
        status, body = bridge_get(id, turn_id ? "tail?turn_id=#{URI.encode_www_form_component(turn_id)}" : "tail")
        return body if status == 200 && body.is_a?(Hash)
        return nil unless status == 404 && body.is_a?(Hash) && body["error"] == "not_found"

        status, live = bridge_get(id, "snapshot")
        return nil unless status == 200 && live.is_a?(Hash) && live["snapshot"].is_a?(Hash)

        snap = live["snapshot"]
        { "session_state_snapshot" => live["session_state_snapshot"],
          "answer" => AnswerTail.find(snap["messages"], turn_id: turn_id),
          "cards" => snap["cards"], "event_seq" => snap["event_seq"], "event_id" => snap["event_id"] }
      end

      def handle_output(req, id)
        # Query ?since= may be an ISO8601 time or numeric mtime; we treat it as Time parse.
        since_param = req.params["since"]
        since_time = parse_since(since_param)
        session = @session_class.load(id, state_dir: default_state_dir)
        raw = @manager.read_responses(id, since_time: since_time, state_dir: @state_dir)
        # Strip wire tokens server-side so the client never sees <|tool_call> etc.
        rendered = raw.map { |chunk| OutputFormatter.strip(chunk) }.reject(&:empty?)
        json_response(200, { session_id: session.id, output: rendered })
      end

      # The whole timing: analytics.json's records merged with a live
      # worker's (by id), and turn_count, the finished turns (#turn_count).
      # +persisted+: the session's analytics.json when the caller read it.
      def timing_payload(session_id, live_metrics: nil, persisted: nil)
        persisted ||= read_analytics(session_id)
        live = live_metrics.is_a?(Hash)
        source = if live
                   persisted.merge(live_metrics).merge(
                     "started_at" => persisted["started_at"] || live_metrics["started_at"],
                     "turn_records" => merge_timing_records(without_running_turn(persisted["turn_records"], live_metrics),
                                                            live_metrics["turn_records"]),
                     "tool_records" => merge_timing_records(persisted["tool_records"], live_metrics["tool_records"])
                   )
                 else
                   persisted
                 end
        turns = Array(source["turn_records"])
        timing_from(source, turns, Array(source["tool_records"]), live: live,
                                                                 turn_count: (live && turn_count(live_metrics)) || turns.size)
      end

      # The timing a ?tail=1 read sends: a live worker's recent
      # records as its metrics hold them (the newest finished turn's and
      # the unsaved ones, the running turn's finished calls), no
      # analytics.json read; with no worker the disk's, trimmed to the
      # newest turn. turn_count tells the page whether its merge missed one
      # (it then reads ?timing=1).
      def recent_timing(session_id, live_metrics)
        if live_metrics.is_a?(Hash)
          count = turn_count(live_metrics)
          # A metrics hash without the count: the whole timing.
          return timing_payload(session_id, live_metrics: live_metrics) unless count

          turns = Array(live_metrics["turn_records"])
          tools = Array(live_metrics["tool_records"])
          # An older worker's metrics hold every record (before they held the
          # recent ones only, never more than LIVE_RECORDS_CAP turns).
          turns, tools = newest_turn_records(turns, tools, live_metrics["active_turn"]) if turns.size > SessionMetrics::LIVE_RECORDS_CAP
          return timing_from(live_metrics, turns, tools, live: true, turn_count: count)
        end

        persisted = read_analytics(session_id)
        all = Array(persisted["turn_records"])
        turns, tools = newest_turn_records(all, Array(persisted["tool_records"]), nil)
        timing_from(persisted, turns, tools, live: false, turn_count: all.size)
      end

      # The finished turns a live worker counts: its metrics' turns (the
      # loaded history, its own and the running one) less the running one.
      # @return [Integer, nil]
      def turn_count(metrics)
        turns = metrics["turns"]
        return nil unless turns.is_a?(Integer)

        [turns - (metrics["active_turn"] ? 1 : 0), 0].max
      end

      # The newest turn record and its tool records (and the running turn's
      # finished calls).
      def newest_turn_records(turns, tools, active_turn)
        kept = turns.last(1)
        ids = kept.filter_map { |r| r["id"] if r.is_a?(Hash) }
        ids << active_turn["id"] if active_turn.is_a?(Hash) && active_turn["id"]
        [kept, tools.select { |r| r.is_a?(Hash) && ids.include?(r["turn_id"]) }]
      end

      def timing_from(source, turn_records, tool_records, live:, turn_count:)
        started_at = source["started_at"]
        last_activity_at = source["last_activity_at"]
        {
          started_at: started_at,
          last_activity_at: last_activity_at,
          session_duration_ms: session_duration_ms(started_at, last_activity_at, active: live),
          turn_records: turn_records,
          tool_records: tool_records,
          turn_count: turn_count,
          active_turn: source["active_turn"],
          active_tools: Array(source["active_tools"]),
          # The context last seen and the token sums, for the ctx meter
          # before the next turn streams (live over saved).
          context: source["context"],
          tokens: source["tokens"],
          # The tokens, cost and speeds per model (SessionMetrics'
          # model_segments; none with one model, or from an older file).
          model_segments: Array(source["model_segments"]),
          # The memory indexes the session's prompt holds (the ctx tooltip).
          memory_index: source["memory_index"],
          # The side requests (recap, /btw, ctx.ask_model), apart from the
          # tokens: the ctx tooltip's own line (nil without any).
          side: source["side"]
        }
      end

      def read_analytics(session_id)
        AnalyticsFile.read(@session_class.session_dir(session_id, state_dir: default_state_dir)) || {}
      end

      # The saved turn records without the one the live worker is running:
      # its turn checkpoint saves that turn's record so far as a killed
      # turn's (canceled, worker_stopped, SessionMetrics#persist's
      # running_turn), which is only true once the worker is gone.
      def without_running_turn(records, live_metrics)
        active = live_metrics["active_turn"]
        id = active.is_a?(Hash) ? active["id"] || active[:id] : nil
        return records if id.nil?

        Array(records).reject { |record| record.is_a?(Hash) && (record["id"] || record[:id]) == id }
      end

      def merge_timing_records(persisted, live)
        (Array(persisted) + Array(live)).each_with_object({}) do |record, records|
          next unless record.is_a?(Hash)

          id = record["id"] || record[:id]
          records[id] = record if id
        end.values
      end

      def session_duration_ms(started_at, last_activity_at, active:)
        started = Time.iso8601(started_at.to_s)
        finished = active ? Time.now : Time.iso8601(last_activity_at.to_s)
        [((finished - started) * 1000).round, 0].max
      rescue ArgumentError
        nil
      end
    end
  end
end
