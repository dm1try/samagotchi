# frozen_string_literal: true

module Samagotchi
  module Web
    module Push
      # When a session needs the user, decided from two of the hub's session
      # summaries (SessionSummary.build: symbol keys, but +last_turn+'s are
      # strings): the server's port of the page's rules (web/public/notify.js
      # attentionFor, closedKeys, attentionText), so a push and the tab's
      # notification ring for the same thing under the same key.
      # spec/fixtures/attention_cases.json holds the cases both sides answer.
      # See docs/internals/web-push.md.
      module Attention
        module_function

        # One thing that needs the user. +key+ names it everywhere (the
        # notification's tag, notify.js's key); +hold+ the seconds it waits
        # before it pushes, nil for the Notifier's own (a delegated child's
        # approval waits longer: its parent may relay it).
        Event = Data.define(:reason, :session_id, :key, :hold)

        # notify.js RELAY_HOLD_MS: how long a delegated child's new approval
        # (or hook question) waits, as its parent may relay it.
        RELAY_HOLD = 3.5
        RELAYED_KINDS = %w[approval hook].freeze
        # The reasons that wait on the user: open until answered, counted in
        # the badge, cleaned up once answered. A failed or done turn is
        # neither (nothing to answer).
        WAITING = %w[approval question continue card].freeze
        # notify.js DONE_MIN_SECONDS, UNWATCHED_ORIGINS: a finished turn
        # shorter than this was watched (no "done"), unless nobody started
        # it (a delegate child's report, a context change, a finished task).
        DONE_MIN_SECONDS = 10
        UNWATCHED_ORIGINS = %w[delegate_report context task].freeze
        TITLE_MAX = 61
        BODIES = { "question" => "needs an answer", "approval" => "needs approval", "continue" => "hit its step limit",
                   "card" => "needs you", "failed" => "turn failed" }.freeze

        def waiting?(reason) = WAITING.include?(reason)

        # notify.js questionReason: a hook's question is a question.
        def reason_of(question)
          case question[:kind]
          when "approval" then "approval"
          when "continue" then "continue"
          else "question"
          end
        end

        # What +nxt+ newly needs the user for, compared with +prev+ (nil for
        # a session not seen yet): a new question first, then a new card,
        # then a finished turn or its new Verify verdict (notify.js's order).
        # @return [Event, nil]
        def for(prev, nxt)
          return nil unless nxt && nxt[:id]

          question = nxt[:pending_question]
          if question.is_a?(Hash) && question[:id] && question[:id] != prev&.dig(:pending_question, :id)
            # Relayed to the parent already: the parent's notifies.
            return nil if question[:relayed_to]

            hold = RELAY_HOLD if nxt[:parent_id] && RELAYED_KINDS.include?(question[:kind])
            return Event.new(reason: reason_of(question), session_id: nxt[:id], key: key(nxt[:id], question[:id]), hold: hold)
          end
          card = nxt[:pending_card]
          if card.is_a?(Hash) && card[:id] && card[:id] != prev&.dig(:pending_card, :id)
            return Event.new(reason: "card", session_id: nxt[:id], key: card_key(nxt[:id], card[:id]), hold: nil)
          end

          turn_event(prev, nxt)
        end

        # A top-level turn that ended since +prev+: its new Verify verdict,
        # failed, or done when it ran long or nobody watched it. A delegated
        # child's turn is reported by its parent's.
        def turn_event(prev, nxt)
          turn = nxt[:last_turn]
          return nil unless turn.is_a?(Hash) && turn["ended_at"]
          return nil if turn["ended_at"] == prev&.dig(:last_turn, "ended_at") || nxt[:parent_id]

          verdict = nxt[:last_verdict]
          if verdict.is_a?(Hash) && present?(verdict[:check_turn_id]) &&
             verdict[:check_turn_id] != prev&.dig(:last_verdict, :check_turn_id)
            return Event.new(reason: "verdict", session_id: nxt[:id], key: key(nxt[:id], verdict[:check_turn_id]), hold: nil)
          end

          reason = case turn["outcome"]
                   when "failed" then "failed"
                   when "completed"
                     "done" if seconds(turn) >= DONE_MIN_SECONDS || UNWATCHED_ORIGINS.include?(turn["origin"])
                   end
          reason && Event.new(reason: reason, session_id: nxt[:id], key: key(nxt[:id], turn["ended_at"]), hold: nil)
        end

        # The keys of what +prev+ had open and +nxt+ no longer has: its
        # question answered (anywhere), gone or newly relayed, its card
        # resolved or replaced; everything when the session is gone (+nxt+
        # nil).
        # @return [Array<String>]
        def closed_keys(prev, nxt)
          keys = []
          question = prev&.dig(:pending_question)
          if question.is_a?(Hash) && question[:id]
            now = nxt&.dig(:pending_question)
            gone = !now.is_a?(Hash) || now[:id] != question[:id] || (now[:relayed_to] && !question[:relayed_to])
            keys << key(prev[:id], question[:id]) if gone
          end
          card = prev&.dig(:pending_card)
          keys << card_key(prev[:id], card[:id]) if card.is_a?(Hash) && card[:id] && nxt&.dig(:pending_card, :id) != card[:id]
          keys
        end

        # Every waiting key still open in +by_id+ (session id → summary): a
        # pending question with an id, not relayed (any reason: a step-limit
        # continue too), and a card with actions. The rule push.js
        # openPushKeys keeps, so the show's +open+ list, the page's cleanup
        # and the badge agree.
        # @return [Array<String>]
        def open_keys(by_id)
          by_id.each_value.flat_map do |summary|
            question = summary[:pending_question]
            card = summary[:pending_card]
            keys = []
            keys << key(summary[:id], question[:id]) if question.is_a?(Hash) && question[:id] && !question[:relayed_to]
            keys << card_key(summary[:id], card[:id]) if card.is_a?(Hash) && card[:id]
            keys
          end
        end

        def key(session_id, id) = "#{session_id}:#{id}"
        def card_key(session_id, card_id) = "#{session_id}:card:#{card_id}"

        # notify.js attentionText: the session's name (clipped) and the
        # reason, never the question or the command (a lock screen shows it).
        # The name is the card's (format.js cardName): title, auto title, the
        # recap's first sentence the server already cut, first message, last prompt.
        # @return [Array(String, String)] title, body
        def text(summary, reason)
          name = (summary && [summary[:title], summary[:auto_title], summary[:recap], summary[:first_preview], summary[:last_prompt]]
                             .find { |v| present?(v) }) ||
                 "chi session"
          body = case reason
                 when "done" then "done in #{seconds(summary&.dig(:last_turn) || {}).round} s"
                 when "verdict" then verdict_text(summary&.dig(:last_verdict) || {})
                 else BODIES.fetch(reason, "")
                 end
          [clip(name.to_s.strip, TITLE_MAX), body]
        end

        def verdict_text(verdict)
          result = verdict[:verdict].to_s
          icon = { "confirmed" => "✅", "refuted" => "❌", "unclear" => "❓" }.fetch(result, "")
          by = verdict[:by_name]
          by = verdict[:by].nil? ? "You" : "A participant" unless present?(by)
          reason = clip(verdict[:reason].to_s, 120)
          "#{by}: #{icon} #{result} — #{reason}"
        end
        private_class_method :verdict_text

        # notify.js Number(turn.seconds): anything that isn't a number is 0.
        def seconds(turn)
          value = turn["seconds"]
          value.is_a?(Numeric) ? value.to_f : Float(value.to_s, exception: false) || 0.0
        end

        def present?(value) = !value.nil? && !value.to_s.strip.empty?

        # format.js clip.
        def clip(text, max) = text.length > max ? "#{text[0, max - 1].rstrip}…" : text
      end
    end
  end
end
