# frozen_string_literal: true

module Samagotchi
  module Web
    module Push
      # When a session needs the user, decided from two of the hub's session
      # summaries (SessionSummary.build: symbol keys): the server's port of
      # the page's rules (web/public/notify.js attentionFor, closedKeys,
      # attentionText), so a push and the tab's notification ring for the
      # same thing under the same key. P1 pushes approvals and questions
      # only (the plan's D1): a step-limit question, a card, a failed or
      # done turn come later. See docs/internals/web-push.md.
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
        # The reasons P1 pushes.
        PUSHED = %w[approval question].freeze
        TITLE_MAX = 61
        BODIES = { "question" => "needs an answer", "approval" => "needs approval", "continue" => "hit its step limit",
                   "card" => "needs you" }.freeze

        # notify.js questionReason: a hook's question is a question.
        def reason_of(question)
          case question[:kind]
          when "approval" then "approval"
          when "continue" then "continue"
          else "question"
          end
        end

        # What +nxt+ newly needs the user for, compared with +prev+ (nil for
        # a session not seen yet).
        # @return [Event, nil]
        def for(prev, nxt)
          return nil unless nxt && nxt[:id]

          question = nxt[:pending_question]
          return nil unless question && question[:id] && question[:id] != prev&.dig(:pending_question, :id)
          # Relayed to the parent already: the parent's notifies.
          return nil if question[:relayed_to]

          reason = reason_of(question)
          return nil unless PUSHED.include?(reason)

          hold = RELAY_HOLD if nxt[:parent_id] && RELAYED_KINDS.include?(question[:kind])
          Event.new(reason: reason, session_id: nxt[:id], key: key(nxt[:id], question[:id]), hold: hold)
        end

        # The keys of what +prev+ had open and +nxt+ no longer has: its
        # question answered (anywhere), gone or newly relayed; everything
        # when the session is gone (+nxt+ nil).
        # @return [Array<String>]
        def closed_keys(prev, nxt)
          question = prev&.dig(:pending_question)
          return [] unless question && question[:id]

          now = nxt&.dig(:pending_question)
          gone = now.nil? || now[:id] != question[:id] || (now[:relayed_to] && !question[:relayed_to])
          gone ? [key(prev[:id], question[:id])] : []
        end

        def key(session_id, question_id) = "#{session_id}:#{question_id}"

        # notify.js attentionText: the session's name (clipped) and the
        # reason, never the question or the command (a lock screen shows it).
        # @return [Array(String, String)] title, body
        def text(summary, reason)
          name = (summary && [summary[:title], summary[:first_preview], summary[:last_prompt]].find { |v| present?(v) }) ||
                 "chi session"
          [clip(name.to_s.strip, TITLE_MAX), BODIES.fetch(reason, "")]
        end

        def present?(value) = !value.nil? && !value.to_s.strip.empty?

        # format.js clip.
        def clip(text, max) = text.length > max ? "#{text[0, max - 1].rstrip}…" : text
      end
    end
  end
end
