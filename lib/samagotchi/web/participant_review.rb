# frozen_string_literal: true

require_relative "participant_view"
require_relative "participant_stream_filter"
require_relative "participant_exposure"
require_relative "../session_metrics"
require_relative "../review_start"
require_relative "../guardrails/review_paths"
require_relative "../participant_mode"
require_relative "../verify_fresh"

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
      # How much of each review subject the page gets; the rest is cut
      # (+truncated+).
      SUBJECT_BYTES = 256 * 1024
      MARKDOWN_EXT = %w[.md .markdown .mdown .mkd].freeze

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
        ParticipantView::Viewer.new(author: author, cwd: session.working_directory, secrets: [(@lan || @public_url) && current_token].compact)
      end

      # GET /api/sessions/:id/review: the participant page's data, always
      # filtered (the owner gets the participant view of it).
      # @return {viewer, session, subjects, participants, messages,
      #   current_turn, waiting_for_owner, queued: {mine, others}, last_event_id}
      def handle_review(req, id)
        session = @session_class.load(id, state_dir: default_state_dir)
        mode = ParticipantMode.live(session, state_dir: default_state_dir).to_s
        viewer = participant_viewer(req, session)
        live = bridge_get_json(id, "snapshot")
        turn_snapshot = live && live["snapshot"]
        state = live && live["session_state_snapshot"]
        raw = live_or_saved(turn_snapshot, "messages") { session.messages }
        shown = messages_for_display(visible_replies(raw), parts: true, cwd: session.working_directory)
        current = turn_snapshot && ParticipantView.current_turn(turn_snapshot["current_turn"], viewer)
        automatic = automatic_turn_ids(id, session, shown, current, state)
        waiting = !!(current&.dig("waiting_for_owner") || turn_snapshot&.dig("continue_offer") ||
                     (turn_snapshot && !turn_snapshot["current_turn"] && turn_snapshot["pending_question"]))
        queued = turn_snapshot && snapshot_list(turn_snapshot, "queued")
        status = displayed_status(session, state)
        status = Session::STATUS_IDLE if status == Session::STATUS_RUNNING && current.nil?
        json_response(200, {
          viewer: review_viewer(req, id, session: session, state: state, queued: queued, viewer: viewer, mode: mode),
          session: { id: session.id, title: participant_title(session), status: status },
          subjects: review_subjects(session, viewer),
          participants: participant_names(id).map { |entry| entry.slice(:id, :name, :kind) },
          messages: with_reply_html(ParticipantView.messages(shown, viewer, automatic: automatic)),
          current_turn: current,
          waiting_for_owner: waiting,
          queued: review_queue(queued || [], viewer),
          verdicts: ParticipantView.verdicts(VerifyFresh.verdicts_of(session, Session.session_dir(id, state_dir: default_state_dir)), viewer),
          # The verdicts a fresh check runs for now (their check_turn_id;
          # never the child's id: a participant can't open it).
          fresh_running: VerifyFresh.running(id, state_dir: default_state_dir).map { |row| row[:of] }.uniq,
          last_event_id: turn_snapshot && turn_snapshot["event_id"]
        })
      end

      # A review session's subjects as the page shows them (the Plan view):
      # each {path, text, html (markdown only), truncated}, or {path,
      # missing: true} for one that is gone or that ReviewPaths refuses now
      # (it became a symlink out of the project, say): checked at every
      # read, as a review turn's read is. The text is cut at SUBJECT_BYTES
      # and redacted like everything else a participant gets; [] for a
      # session that isn't a review session.
      def review_subjects(session, viewer)
        review = session.review or return []
        root = ReviewStart.root_for(session.working_directory)
        check = Guardrails::ReviewPaths.new(root: root)
        review.subjects.map do |path|
          # The real path is checked and read, the file with O_NOFOLLOW: a
          # symlink swapped in for it after the check isn't followed. Only
          # the last component: a folder swapped for a symlink in between
          # still is, which takes write access to the project (the owner's).
          real = File.realpath(File.expand_path(path, root))
          next { path: path, missing: true } unless File.file?(real) && check.refusal([real]).nil?

          review_subject(path, real, viewer)
        rescue SystemCallError
          { path: path, missing: true }
        end
      end

      def review_subject(path, full, viewer)
        raw = File.open(full, File::RDONLY | File::NOFOLLOW | File::BINARY) { |file| file.read(SUBJECT_BYTES + 1) }.to_s
        text = ParticipantView::Redact.text(raw.byteslice(0, SUBJECT_BYTES).force_encoding(Encoding::UTF_8).scrub, viewer)
        entry = { path: path, text: text, truncated: raw.bytesize > SUBJECT_BYTES }
        markdown = MARKDOWN_EXT.include?(File.extname(path).downcase)
        entry[:html] = @markdown_renderer.render(text) if markdown && @markdown_renderer.available?
        entry
      rescue SystemCallError
        { path: path, missing: true }
      end

      # The saved messages with each model message's content as a
      # participant may read it (ParticipantView.visible_raw: no cut-off
      # thought or tool call left as text).
      def visible_replies(raw)
        Array(raw).map do |message|
          next message unless message.is_a?(Hash) && %w[model assistant].include?((message[:role] || message["role"]).to_s)

          key = message.key?(:content) ? :content : "content"
          content = message[key]
          content.is_a?(String) ? message.merge(key => ParticipantView.visible_raw(content)) : message
        end
      end

      # The ids of the turns no person sent, whose prompt a participant
      # doesn't read: the turn records marked automatic (the saved ones and
      # the live worker's, which has a finished turn's before it is saved),
      # the running turn's when its start says so (its prompt is the last),
      # and a delegate child's first turn (its task, the parent's text,
      # came with no client).
      def automatic_turn_ids(id, session, shown, current, state)
        live = state.is_a?(Hash) && state["metrics"].is_a?(Hash) ? Array(state["metrics"]["turn_records"]) : []
        records = Array(read_analytics(id)&.fetch("turn_records", nil)) + live
        ids = records.filter_map { |record| record["id"].to_s if record.is_a?(Hash) && record["automatic"] }
        prompts = shown.select { |message| message[:role] == "user" && message[:turn_id] }
        ids << prompts.last[:turn_id].to_s if current&.dig("automatic") && prompts.last
        ids << prompts.first[:turn_id].to_s if delegate_child?(session) && prompts.first
        ids
      end

      # Session.load reads the parent sidecar over the file's field.
      def delegate_child?(session) = !session.parent_id.to_s.empty?

      # Who is reading: a participant (their id, name, whether they may
      # comment: not once their cap is reached, and their +usage+ as their
      # grant's exposure shows it), or the owner looking through the
      # participant view (no composer, no usage: the owner has /stats).
      # +state+ the live worker's session state (nil without one), +queued+
      # its queue.
      def review_viewer(req, id, session:, state:, queued:, viewer:, mode:)
        return { kind: "owner", can_comment: false, mode: mode } if principal(req).owner?

        grant = principal(req).grant
        capped = !participant_cap_refusal(grant).nil?
        # Theirs: pair only when their grant was issued to act (ParticipantMode.live_for).
        mode = ParticipantMode.live_for(session, grant, state_dir: default_state_dir).to_s
        { kind: "participant", id: grant.id, name: grant.name, participant_kind: grant.kind, mode: mode, can_comment: !capped,
          cap_reached: capped, session_id: id,
          usage: review_usage(grant, session: session, state: state, queued: queued, viewer: viewer) }
      end

      # A participant's usage, the fields their grant's exposure level
      # shows (ParticipantExposure), each computed only when shown. Every
      # source reads the grant's own author: never another participant's or
      # the owner's.
      def review_usage(grant, session:, state:, queued:, viewer:)
        usage = ParticipantExposure.usage(grant.exposure, {
          spent: -> { participant_spent(grant, state) },
          cap: -> { grant.spend_cap },
          queued: -> { queued&.count { |entry| entry.is_a?(Hash) && viewer.own?(entry["author"]) } },
          queue_limit: -> { grant.queue_limit },
          expires_at: -> { grant.expires_at },
          model: -> { participant_model(session, state, viewer) }
        })
        usage.delete(:queued) unless queued
        usage
      end

      # What the participant has cost so far, in dollars: the saved
      # analytics' count (#participant_cap_refusal's), or the live worker's
      # when it is more (SessionMetrics#spend: its saved turns, the running
      # turn's finished generations and the side requests; a running turn
      # is saved only at its end). The worker's count already holds the
      # saved one, so the two are never added.
      def participant_spent(grant, state)
        dir = Session.session_dir(grant.session_id, state_dir: default_state_dir)
        saved = SessionMetrics.saved_spend(dir, grant.author)
        live = live_spend(state, grant.author)
        fresh = VerifyFresh.children_spend(grant.session_id, grant.author, state_dir: default_state_dir)
        ([saved, live].max + fresh).round(4)
      end

      # +author+'s cost in the live worker's metrics (spend_by_author), 0.0
      # without one.
      def live_spend(state, author)
        cost = state.is_a?(Hash) ? state.dig("metrics", "spend_by_author", author, "cost") : nil
        cost.is_a?(Numeric) && cost.to_f.finite? ? cost.to_f : 0.0
      rescue TypeError
        0.0
      end

      # The model the session runs on, as its host is sent it (the alias
      # applied, no host name): the live worker's, else the saved one's;
      # nil when it doesn't resolve.
      def participant_model(session, state, viewer)
        ref = (state.is_a?(Hash) && state["model_name"]) || session.model_name
        return nil if ref.to_s.empty?

        name = host_registry.bare_name(ref.to_s)
        name.to_s.empty? ? nil : ParticipantView::Redact.text(name.to_s, viewer)
      rescue StandardError
        nil
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
        # The owner's participant view has no composer; a participant's
        # selection quotes with the same presets as the owner's page.
        attrs.merge!(annotate_presets_data) unless principal(req).owner?
        # A block: a name's \& or \' is text, never a backreference.
        html_response(200, File.read(path).sub("<body>") { "<body #{body_data(attrs)}>" })
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
