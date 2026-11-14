# frozen_string_literal: true

require_relative "participant_view"
require_relative "token"
require_relative "participant_stream_filter"
require_relative "../participant_exposure"
require_relative "../session_metrics"
require_relative "../verify_fresh"

module Samagotchi
  module Web
    # What a participant reads, mixed into App: the reads their main page's
    # show is made of (ParticipantShow: the viewer, their usage, the
    # messages as they may read them) and their stream, each through
    # ParticipantView. See docs/internals/participants.md (What a
    # participant sees).
    module ParticipantReview
      # The stream's query keys a filtered stream passes to the Bridge: its
      # cursor and its join. Not client_id (a stream named as a TUI's would
      # count as one), not raw.
      STREAM_KEYS = %w[from_seq snapshot].freeze

      private

      # Whether this request reads as a participant (their show, their
      # filtered stream).
      def participant_view?(req)
        !principal(req).owner?
      end

      # Who reads: the participant (their author). The session's folder
      # places tool paths; the owner's token is never shown, nor (LAN) its
      # loopback cookie value.
      def participant_viewer(req, session)
        Redact::Viewer.new(author: principal(req).grant.author, cwd: session.working_directory, secrets: owner_secrets)
      end

      def owner_secrets
        token = (@lan || @public_url) && current_token
        [token, @lan && Token.loopback_cookie(token)].compact
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
      # comment: not once their cap is reached, their grant's mode, and
      # their +usage+ as their grant's exposure shows it). +state+ the live
      # worker's session state (nil without one), +queued+ its queue.
      def review_viewer(req, id, session:, state:, queued:, viewer:)
        grant = principal(req).grant
        capped = !participant_cap_refusal(grant).nil?
        # Their turns act under the owner's rules (every active grant is pair).
        mode = Grants::PAIR_MODE
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
        name.to_s.empty? ? nil : Redact.text(name.to_s, viewer)
      rescue StandardError
        nil
      end

      # Each reply's rendered markdown, from its filtered (redacted) text.
      def with_reply_html(messages)
        return messages unless @markdown_renderer.available?

        messages.map do |message|
          next message unless message["role"] == "assistant" && !message["content"].strip.empty?

          message.merge("html" => @markdown_renderer.render(message["content"]))
        end
      end

      # A filtered stream's frame filter (App#stream_filter), for the
      # session +id+.
      def participant_stream_filter(req, id)
        session = @session_class.load(id, state_dir: default_state_dir)
        grant = principal(req).grant
        own = ->(enqueued_id) { own_turn?(grant, id, enqueued_id) }
        ParticipantStreamFilter.new(participant_viewer(req, session), own_enqueued: own)
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
