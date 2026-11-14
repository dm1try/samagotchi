# frozen_string_literal: true

require "json"
require_relative "participant_view"
require_relative "viewer"
require_relative "../bridge/turn_accumulator"
require_relative "../worker_link"
require_relative "../verify_anchor"
require_relative "../verify_fresh"

module Samagotchi
  module Web
    # A participant's GET /api/sessions/:id, mixed into App: the main page's
    # session read in the owner's shape (SessionShow#owner_show's keys), made
    # from the same reads (SessionShow#show_reads) and every part passed
    # through ParticipantView: the messages, each finished turn's drawing
    # event by event, the turn in progress, the replay and the queue. What a
    # participant never gets is there empty or nil (history, commands, cards,
    # recap, the continue offer, the question, the warnings); the only keys
    # the owner's show lacks are +viewer+'s own and the verdicts' (+fresh_running+,
    # +session.verify_unavailable+). The light re-reads (?tail=1, ?timing=1,
    # ?cards=1) answer in the owner's shape too, filtered; ?brief=1 is what
    # SessionAccess::Remote#show reads with a participant's token.
    # See docs/internals/participants.md (What a participant sees).
    module ParticipantShow
      private

      def participant_show_read(req, id)
        return participant_show(id) if req.params["brief"] == "1"
        return participant_cards_read(id) if req.params["cards"] == "1"
        return participant_tail_read(req, id) if req.params["tail"] == "1"
        return participant_timing_read(req, id) if req.params["timing"] == "1"

        session = @session_class.load(id, state_dir: default_state_dir)
        participant_main_show(req, show_reads(id, session))
      end

      # The owner's show's keys, a participant's values (the class comment).
      def participant_main_show(req, reads)
        session = reads.session
        viewer = participant_viewer(req, session)
        turn_snapshot = reads.turn_snapshot
        features = WorkerLink.live_features(session.id, state_dir: default_state_dir)
        timing = participant_timing(reads.id, live_metrics: reads.state && reads.state["metrics"])
        raw = visible_replies(reads.raw_messages)
        drawn = drawn_lines(reads.id, raw, timing: {}, entries: [], cwd: session.working_directory,
                                           skip_turn_id: reads.current_turn_id)
        shown = messages_for_display(raw, parts: true, cwd: session.working_directory, markdown: false, drawings: drawn)
        current = turn_snapshot && ParticipantView.current_turn(reads.current_turn, viewer)
        automatic = automatic_turn_ids(reads.id, session, shown, current, reads.state)
        messages = with_reply_html(ParticipantView.messages(shown, viewer, automatic: automatic))
        queued = snapshot_list(turn_snapshot, "queued")
        json_response(200, {
          session: participant_session_json(reads, features, viewer),
          history: [],
          messages: messages,
          **participant_drawings_field(drawn, messages, viewer),
          failed_turn: nil,
          current_turn: current,
          replay: participant_replay(turn_snapshot, timing, viewer),
          queued: participant_queued(queued, viewer),
          queued_commands: [],
          recap: nil,
          saved_recap: nil,
          continue_offer: nil,
          guardrail_warning: nil,
          plugin_warning: nil,
          init_tasks: [],
          cards: [],
          commands: [],
          # The owner's chi web's own setup notes: never a participant's.
          markdown_warning: nil,
          markdown_tip: nil,
          **participant_capabilities,
          viewer: participant_main_viewer(req, reads, queued: turn_snapshot && queued, viewer: viewer),
          pending_question: nil,
          last_event_seq: reads.event_seq,
          last_event_id: reads.event_id,
          timing: timing,
          fresh_running: VerifyFresh.running(reads.id, state_dir: default_state_dir).map { |row| row[:of] }.uniq
        })
      end

      # The show's session: who it is (id, the participant title), its status
      # as a participant reads it (idle when a worker says running with no
      # turn), whether a worker runs it and what it can do (the page's
      # delivery line, the stale-worker badge), its verdicts (filtered) and whether Verify fresh can run.
      def participant_session_json(reads, features, viewer)
        session = reads.session
        status = displayed_status(session, reads.state)
        status = Session::STATUS_IDLE if status == Session::STATUS_RUNNING && reads.turn_snapshot && reads.current_turn.nil?
        dir = Session.session_dir(reads.id, state_dir: default_state_dir)
        { id: session.id, title: participant_title(session), status: status,
          bridge_up: !reads.turn_snapshot.nil?, worker_features: Array(features),
          verdicts: ParticipantView.verdicts(VerifyFresh.verdicts_of(session, dir), viewer),
          verify_unavailable: VerifyAnchor.worker_unavailable?(features) }
      end

      # The show's capabilities (Capabilities, what the page renders): never
      # the editor (it opens this machine's paths), whoever's machine it is.
      def participant_capabilities
        { capabilities: Capabilities.for(@markdown_renderer, editor: false).to_h, editor_url: nil }
      end

      # The show's viewer: Viewer's (kind, id, name, can, client_id) with what
      # #review_viewer says (their mode, cap,
      # usage) and whether the session is stopped (only the owner's message
      # starts it again).
      def participant_main_viewer(req, reads, queued:, viewer:)
        session = reads.session
        review = review_viewer(req, reads.id, session: session, state: reads.state, queued: queued, viewer: viewer)
        Viewer.for(principal(req)).to_h.merge(
          review.slice(:participant_kind, :mode, :cap_reached, :usage),
          session_stopped: session.status == Session::STATUS_STOPPED,
          waiting_for_owner: participant_waiting(reads.turn_snapshot)
        )
      end

      # What the session waits for the owner on (ParticipantView.waiting_kind),
      # nil when it doesn't: the running turn's question or approval, a
      # Continue offer, or a question between turns.
      def participant_waiting(turn_snapshot)
        return nil unless turn_snapshot.is_a?(Hash)

        turn = turn_snapshot["current_turn"]
        pending = turn.is_a?(Hash) ? turn["pending_question"] : turn_snapshot["pending_question"]
        return ParticipantView.waiting_kind(pending) if pending
        return ParticipantView::WAITING_CONTINUE if turn_snapshot["continue_offer"]

        nil
      end

      # {turn_drawings: {turn_id => {events:, end:}}} as the owner's
      # (SessionShow#turn_drawings_field), each event through
      # ParticipantView.event (a dropped one is left out) and the end
      # through ParticipantView.drawing_end. No cards. Its start's prompt is
      # the filtered messages' (ParticipantView.drawing_start): a turn they
      # show no person's prompt for (an automatic turn, a wake, a delegate
      # child's task; a made drawing's start has no origin to say so)
      # starts with none.
      def participant_drawings_field(lines, messages, viewer)
        stamped = messages.to_set { |item| item["drawn"] }
        shown = lines.select { |line| stamped.include?(line.turn_id) }
        return {} if shown.empty?

        prompts = messages.each_with_object({}) do |message, by_turn|
          next unless message["role"] == "user" && message["turn_id"] && !message["automatic"] && !message["merged"]

          by_turn[message["turn_id"]] = message["content"]
        end
        { turn_drawings: shown.to_h do |line|
          turn = Bridge::TurnAccumulator.from_wire(line.drawing)
          events = participant_events(Bridge::TurnAccumulator.replay_events(turn, cards: false), viewer)
          events = events.map { |event| ParticipantView.drawing_start(event, prompts[line.turn_id.to_s]) }
          [line.turn_id, { events: events, end: ParticipantView.drawing_end(line.end || {}, line.turn_id) }]
        end }
      end

      # The page's join (SessionShow#replay_events_for), each event through
      # ParticipantView.event: another person's queued turn is a bare
      # turn_enqueued (its entry holds their prompt).
      def participant_replay(turn_snapshot, timing, viewer)
        participant_events(replay_events_for(turn_snapshot, timing), viewer)
      end

      def participant_events(events, viewer)
        Array(events).filter_map { |event| ParticipantView.event(JSON.parse(JSON.generate(event)), viewer) }
      end

      # The queue as the owner's show lists it, the viewer's own entries only
      # (ParticipantView.queued_entry): another person's entry holds their
      # prompt.
      def participant_queued(queued, viewer)
        queued.filter_map { |entry| ParticipantView.queued_entry(entry, viewer) }
      end

      # ?cards=1: a participant gets no cards.
      def participant_cards_read(id)
        return session_not_found(id) unless session_exists?(id)

        json_response(200, { cards: [] })
      end

      # ?tail=1 as the owner's (SessionShow#handle_tail_read): the session's
      # id and status, the turn's answer through ParticipantView (the last
      # one, or ?turn_id='s), the timing filtered. Read from the live
      # snapshot (the messages a participant may read are filtered as the
      # full show's), else the file.
      def participant_tail_read(req, id)
        session = @session_class.load(id, state_dir: default_state_dir)
        reads = show_reads(id, session)
        viewer = participant_viewer(req, session)
        turn_id = req.params["turn_id"].to_s.strip
        raw = visible_replies(reads.raw_messages)
        shown = messages_for_display(raw, parts: true, cwd: session.working_directory, markdown: false)
        messages = ParticipantView.messages(shown, viewer)
        answer = participant_answer(messages, turn_id.empty? ? nil : turn_id)
        status = displayed_status(session, reads.state)
        status = Session::STATUS_IDLE if status == Session::STATUS_RUNNING && reads.turn_snapshot && reads.current_turn.nil?
        json_response(200, {
          tail: true,
          session: { id: id, status: status, used_memory_names: [], prompt_notes: [] },
          messages: with_reply_html([answer].compact),
          # The owner's chi web's own setup notes: never a participant's.
          markdown_warning: nil,
          markdown_tip: nil,
          **participant_capabilities,
          timing: participant_timing(id, live_metrics: reads.state && reads.state["metrics"])
        })
      end

      # The answer of the turn +turn_id+ (the reply after its prompt), else
      # the last reply with text.
      def participant_answer(messages, turn_id)
        if turn_id
          start = messages.index { |message| message["role"] == "user" && message["turn_id"] == turn_id }
          return nil unless start

          turn = messages.drop(start + 1).take_while { |message| message["role"] != "user" || message["merged"] }
          return turn.reverse.find { |message| message["role"] == "assistant" && !message["content"].strip.empty? }
        end
        messages.reverse.find { |message| message["role"] == "assistant" && !message["content"].strip.empty? }
      end

      # ?timing=1: the whole timing, filtered.
      def participant_timing_read(_req, id)
        return session_not_found(id) unless session_exists?(id)

        state = bridge_get_json(id, "state")
        json_response(200, { timing: participant_timing(id, live_metrics: state && state["session_state_snapshot"]&.fetch("metrics", nil)) })
      end

      # The show's timing (SessionShow#timing_payload) as a participant may
      # read it (ParticipantView.timing: durations and speeds only).
      def participant_timing(id, live_metrics:)
        ParticipantView.timing(timing_payload(id, live_metrics: live_metrics))
      end
    end
  end
end
