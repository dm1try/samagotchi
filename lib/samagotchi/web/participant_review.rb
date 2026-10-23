# frozen_string_literal: true

require_relative "participant_view"
require_relative "participant_stream_filter"
require_relative "../session_metrics"

module Samagotchi
  module Web
    # What a participant reads, mixed into App (P4a): their page, its data
    # (GET /api/sessions/:id/review) and their stream, each through
    # ParticipantView. The owner reaches the same reads as "the participant
    # view": the page at /?as=participant, the review route, and the stream
    # with ?as=participant, through the same filter with no participant of
    # their own (nothing is "mine", no composer). See
    # docs/internals/participants.md (What a participant sees).
    module ParticipantReview
      PARTICIPANT_VIEW = "participant"
      # The stream's query keys a filtered stream passes to the Bridge: its
      # cursor and its join. Not client_id (a stream named as a TUI's would
      # count as one), not raw.
      STREAM_KEYS = %w[from_seq snapshot].freeze

      private

      # Whether this request reads as a participant: a participant's, or
      # the owner's with ?as=participant.
      def participant_view?(req)
        !principal(req).owner? || req.params["as"] == PARTICIPANT_VIEW
      end

      # Who reads: the participant (their author), or the owner through the
      # participant view (nobody's own). The session's folder places tool
      # paths; the owner's token is never shown.
      def participant_viewer(req, session)
        author = principal(req).owner? ? nil : principal(req).grant.author
        ParticipantView::Viewer.new(author: author, cwd: session.working_directory, secrets: [@lan && current_token].compact)
      end

      # GET /api/sessions/:id/review: the participant page's data, always
      # filtered (the owner gets the participant view of it).
      # @return {viewer, session, participants, messages, current_turn,
      #   waiting_for_owner, queued: {mine, others}, last_event_id}
      def handle_review(req, id)
        session = @session_class.load(id, state_dir: default_state_dir)
        viewer = participant_viewer(req, session)
        live = bridge_get_json(id, "snapshot")
        turn_snapshot = live && live["snapshot"]
        state = live && live["session_state_snapshot"]
        raw = live_or_saved(turn_snapshot, "messages") { session.messages }
        shown = messages_for_display(raw, parts: true, cwd: session.working_directory)
        current = turn_snapshot && ParticipantView.current_turn(turn_snapshot["current_turn"], viewer)
        automatic = automatic_turn_ids(id, shown, current)
        waiting = !!(current&.dig("waiting_for_owner") || turn_snapshot&.dig("continue_offer") ||
                     (turn_snapshot && !turn_snapshot["current_turn"] && turn_snapshot["pending_question"]))
        json_response(200, {
          viewer: review_viewer(req, id),
          session: { id: session.id, title: participant_title(session), status: displayed_status(session, state) },
          participants: participant_names(id).map { |entry| entry.slice(:id, :name, :kind) },
          messages: with_reply_html(ParticipantView.messages(shown, viewer, automatic: automatic)),
          current_turn: current,
          waiting_for_owner: waiting,
          queued: review_queue(snapshot_list(turn_snapshot, "queued"), viewer),
          last_event_id: turn_snapshot && turn_snapshot["event_id"]
        })
      end

      # The ids of the turns no person sent, whose prompt a participant
      # doesn't read: the saved analytics' records marked automatic, and the
      # running turn's (its record isn't saved yet: the last prompt's id)
      # when its start says so.
      def automatic_turn_ids(id, shown, current)
        records = Array(read_analytics(id)&.fetch("turn_records", nil))
        ids = records.filter_map { |record| record["id"].to_s if record.is_a?(Hash) && record["automatic"] }
        if current&.dig("automatic")
          last = shown.reverse.find { |message| message[:role] == "user" && message[:turn_id] }
          ids << last[:turn_id].to_s if last
        end
        ids
      end

      # Who is reading: a participant (their id, name, whether they may
      # comment: not once their cap is reached), or the owner looking
      # through the participant view (no composer).
      def review_viewer(req, id)
        return { kind: "owner", can_comment: false } if principal(req).owner?

        grant = principal(req).grant
        capped = !participant_cap_refusal(grant).nil?
        { kind: "participant", id: grant.id, name: grant.name, participant_kind: grant.kind, can_comment: !capped,
          cap_reached: capped, session_id: id }
      end

      # The queue as a participant sees it: their own queued turns (the
      # enqueued id, for dequeue, and the text), and how many others wait.
      def review_queue(queued, viewer)
        mine, others = queued.partition { |entry| entry.is_a?(Hash) && viewer.own?(entry["author"]) }
        { mine: mine.map { |entry| ParticipantView::Redact.deep({ "enqueued_id" => entry["enqueued_id"].to_s, "prompt" => entry["prompt"].to_s }, viewer) },
          others: others.size }
      end

      # Each reply's rendered markdown, from its filtered (redacted) text.
      def with_reply_html(messages)
        return messages unless @markdown_renderer.available?

        messages.map do |message|
          next message unless message["role"] == "assistant" && !message["content"].strip.empty?

          message.merge("html" => @markdown_renderer.render(message["content"]))
        end
      end

      # The page a participant's link opens, and the owner's participant
      # view (/?as=participant#s=<id>): the participant page's shell; its
      # script reads everything through the review route and the filtered
      # stream.
      def participant_shell(req)
        path = File.join(@public_dir, "participant.html")
        return error_response(500, "missing_page", "participant.html is missing") unless File.file?(path)

        attrs = { "version" => Samagotchi::VERSION }
        if principal(req).owner?
          attrs["viewer"] = "owner"
        else
          grant = principal(req).grant
          attrs.merge!("viewer" => "participant", "session" => grant.session_id, "name" => grant.name)
        end
        data = attrs.map { |key, value| %(data-#{key}="#{Rack::Utils.escape_html(value)}") }.join(" ")
        html_response(200, File.read(path).sub("<body>", "<body #{data}>"))
      end

      # A filtered stream's frame filter (App#stream_filter), for the
      # session +id+.
      def participant_stream_filter(req, id)
        session = @session_class.load(id, state_dir: default_state_dir)
        ParticipantStreamFilter.new(participant_viewer(req, session))
      end

      # A filtered stream's query: only its cursor and its join.
      def participant_stream_query(req)
        pairs = URI.decode_www_form(req.query_string.to_s).select { |key, _| STREAM_KEYS.include?(key) }
        pairs.empty? ? "" : "?#{URI.encode_www_form(pairs)}"
      rescue ArgumentError
        ""
      end
    end
  end
end
