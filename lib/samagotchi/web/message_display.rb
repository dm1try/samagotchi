# frozen_string_literal: true

require_relative "../session"
require_relative "../answer_refs"
require_relative "../answer_tail"
require_relative "../context_note"
require_relative "../image_store"
require_relative "../message_parts"
require_relative "../message_time"
require_relative "../output_formatter"
require_relative "../recap_store"
require_relative "../ref"
require_relative "../revise_anchor"
require_relative "../steer"
require_relative "../turn_note"
require_relative "../bridge/card_store"

module Samagotchi
  module Web
    # How chi web shows saved messages and cards: a session's history as
    # display items (messages_for_display, which ParticipantReview reads
    # too), an answer as its parts and refs, a card's body as HTML, and POST
    # /api/render, the markdown read of a text the page already shows.
    # Included in App: its ROUTES name handle_render, and its helpers
    # (json_response, error_response, parse_json, request_body,
    # default_state_dir) and ivars (@manager, @session_class, @state_dir,
    # @markdown_renderer) answer. See docs/architecture.md (chi web's routes).
    module MessageDisplay
      # A POST /api/render body may be this big: a decision message is a few
      # KB, and the cap bounds the work a page can ask for.
      MAX_RENDER_BYTES = 64 * 1024

      private

      # The recap saved with the session and how many user turns came since:
      # a live worker's (it counts against its Engine's messages), else
      # recap.json against the session file. A stopped session gets its
      # recap without a worker being woken.
      # @return [Hash, nil] {text:, turns_since:, created_at:} (created_at:
      #   when it was written, UTC ISO; absent from an older recap)
      def saved_recap_for(id, session, turn_snapshot)
        if turn_snapshot
          saved = turn_snapshot["saved_recap"]
          return saved && { text: saved["text"], turns_since: saved["turns_since"].to_i, created_at: saved["created_at"] }.compact
        end

        saved = RecapStore.read(@session_class.session_dir(id, state_dir: default_state_dir))
        return nil unless saved

        messages = Array(session.messages)
        since = messages.drop(saved[:covered].to_i).count { |m| Samagotchi::Steer.turn_prompt?(m) }
        { text: saved[:text], turns_since: since, created_at: saved[:created_at] }.compact
      rescue StandardError
        nil
      end

      # The step (iteration) that answered the steer or merged input at
      # +index+: one past the model messages between it and the turn's
      # prompt.
      def steer_step(list, index)
        list[0...index].reverse_each.take_while { |m| !Samagotchi::Steer.turn_prompt?(m) }
                       .count { |m| %w[model assistant].include?((m[:role] || m["role"]).to_s) } + 1
      end

      def read_history(id)
        raw = @manager.read_responses(id, since_time: nil, state_dir: @state_dir)
        raw.map { |chunk| OutputFormatter.strip(chunk) }.reject(&:empty?)
      rescue StandardError
        []
      end

      # @param msgs [Array<Hash>] a session's messages; symbol keys from disk,
      #   string keys from a Bridge snapshot
      # @param parts [Boolean] the turn view's reload (?parts=1): each
      #   assistant message also carries what it did (MessageParts: thinking,
      #   tool calls with params and output), and a message with nothing to
      #   show but that (a text-less step) is kept with empty content
      # @param cwd [String, nil] the session's working directory (the parts'
      #   tool titles are relative to it)
      def messages_for_display(msgs, parts: false, cwd: nil)
        filtered = []
        list = Array(msgs)
        # The outputs' ✂ marks (LLM context edits), by id, for the parts.
        marks = parts ? MessageParts.edit_marks(list) : {}
        list.each_with_index do |m, index|
          role = (m[:role] || m["role"]).to_s
          content = (m[:content] || m["content"]).to_s
          if Samagotchi::ContextNote.note?(m)
            note = { role: "note", content: Samagotchi::ContextNote.text_of(m), label: Samagotchi::ContextNote.label_of(m), **time_of(m) }
            # A context wake turn's note starts that turn (Steer.turn_prompt?):
            # the page opens the turn with it and pairs it with its record.
            if Samagotchi::Steer.turn_prompt?(m)
              note[:turn_start] = true
              note[:turn_id] = (m[:turn_id] || m["turn_id"]).to_s
              note.merge!(revises_of(m))
            end
            filtered << note
            next
          end
          # A plugin's steer: a row of the step that answered it, which the
          # page finds by `step`.
          if Samagotchi::Steer.steer?(m)
            filtered << { role: "steer", content: content, source: (m[:source] || m["source"]).to_s, step: steer_step(list, index), **time_of(m) }
            next
          end
          # A turn that ended with no answer (TurnNote.empty's marker): its
          # empty steps (with ?parts=1) and the item the page draws its
          # notice from; the note itself stays hidden.
          if (marker = Samagotchi::TurnNote.empty_answer(m))
            filtered.concat(empty_answer_items(marker, parts: parts, cwd: cwd))
            next
          end
          next if role == "system"
          next if role == "tool_response"

          stripped = Samagotchi::OutputFormatter.strip_markup(content)
          did = parts && %w[model assistant].include?(role) ? message_parts(list, index, cwd, marks) : nil
          next if stripped.empty? && did.nil?

          norm_role = role == "model" ? "assistant" : role
          # normalize assistant vs model, keep user as is
          norm_role = "assistant" if %w[assistant model].include?(norm_role)
          norm_role = "user" if norm_role == "user"
          next unless %w[user assistant].include?(norm_role)

          message = { role: norm_role, content: stripped, **time_of(m) }
          # Merged into the running turn (Steer::INPUT_KIND): part of it,
          # read by step +step+; a wake turn's report starts its turn
          # (Steer.turn_prompt?). Its sender (a delegate report, chi send):
          # the page's label.
          if norm_role == "user" && Samagotchi::Steer.input?(m)
            message.merge!(merged: true, step: steer_step(list, index)) unless Samagotchi::Steer.turn_prompt?(m)
            source = (m[:source] || m["source"]).to_s
            message[:source] = source unless source.empty?
          end
          # The turn it started (Engine): the page pairs it with that turn's
          # record by this, not by its place.
          turn_id = m[:turn_id] || m["turn_id"]
          message[:turn_id] = turn_id.to_s if norm_role == "user" && turn_id
          # The turn it revised (a Revise stack, Engine#stamp_opening), and
          # whether it was a Verify turn (the page offers no Revise on its
          # answer).
          if norm_role == "user" && turn_id && !message[:merged]
            message.merge!(revises_of(m))
            message[:verify] = true if Samagotchi::VerifyAnchor.from(m[:verify] || m["verify"])
          end
          # A participant's message names them (the page's author badge).
          if norm_role == "user"
            message.merge!(Samagotchi::Steer.author_fields(m[:author] || m["author"], m[:author_name] || m["author_name"]))
            # Its turn's mode (review or pair: the badge, Apply under a review turn only).
            mode = m[:participant_mode] || m["participant_mode"]
            message[:participant_mode] = mode.to_s if mode && message[:author]
          end
          images = m[:images] || m["images"]
          message[:images] = Array(images).map { |ref| ImageStore.symbolize(ref).slice(:file, :name, :width, :height) } if norm_role == "user" && images.is_a?(Array) && !images.empty?
          if norm_role == "assistant"
            # What an after_turn hook presented (AnswerDisplay): rendered and
            # copied in place of the answer, sanitised the same way; content
            # stays the model's text, which the page finds the bubble by.
            display = m[:display] || m["display"]
            shown = display.is_a?(String) ? Samagotchi::OutputFormatter.strip_markup(display) : ""
            message[:display] = shown unless shown.strip.empty?
            rendered = message[:display] || stripped
            message[:html] = @markdown_renderer.render(rendered) if !rendered.empty? && @markdown_renderer.available?
            # The refs after_turn hooks attached (AnswerRefs), checked again:
            # a stored file is never trusted. Never raises.
            refs = Samagotchi::AnswerRefs.for_display(m[:display_refs] || m["display_refs"], cwd: cwd)
            message[:display_refs] = refs unless refs.empty?
          end
          message[:parts] = did if did
          filtered << message
        end
        filtered
      rescue StandardError
        []
      end

      # A turn opening's Revise stamp as {revises: {turn_id:}}, checked again
      # (a stored file is never trusted), or nothing.
      def revises_of(message)
        anchor = Samagotchi::ReviseAnchor.from(message[:revises] || message["revises"])
        anchor ? { revises: anchor.to_h } : {}
      end

      # The entry's wall time (MessageTime: the page's hover and gap
      # dividers) as {at:}, or nothing for an entry saved without one.
      def time_of(message)
        at = Samagotchi::MessageTime.of(message)
        at.is_a?(String) && !at.empty? ? { at: at } : {}
      end

      # A no-answer turn's marker as display items: each empty step that
      # has something to show (its thinking) as a text-less assistant step
      # (only with +parts+, as other text-less steps), then
      # { role: "empty_answer", retries: }.
      def empty_answer_items(marker, parts:, cwd:)
        steps = parts ? Array(marker[:steps] || marker["steps"]) : []
        items = steps.filter_map do |step|
          did = step.is_a?(Hash) ? MessageParts.for_message(step, [], cwd: cwd) : nil
          { role: "assistant", content: "", parts: did } if did
        end
        refusal = marker[:refusal] || marker["refusal"]
        items << { role: "empty_answer", content: "", retries: (marker[:retries] || marker["retries"]).to_i, refusal: refusal }.compact
      end

      # The last turn failed and its prompt went back to the user: the
      # prompt (session.last_prompt) and why, for the page to show after the
      # conversation as it did live. nil otherwise.
      def failed_turn_for(session, msgs)
        summary = Samagotchi::TurnNote.restored_failure(msgs)
        prompt = session.last_prompt.to_s
        return nil if summary.nil? || prompt.strip.empty?

        { prompt: prompt, summary: summary }
      end

      # The parts of the assistant message at +index+, with the tool_response
      # messages right after it; +marks+: the session's ✂ marks
      # (MessageParts.edit_marks).
      def message_parts(list, index, cwd = nil, marks = {})
        responses = list.drop(index + 1).take_while { |r| (r[:role] || r["role"]).to_s == "tool_response" }
        MessageParts.for_message(list[index], responses, cwd: cwd, marks: marks)
      end

      # The last message messages_for_display shows as an answer
      # (AnswerTail), as a list of at most one: only that one is rendered.
      # +cwd+: the session's folder, for its file refs (nil from a live
      # worker's tail: its refs were held to the folder when they were added).
      def last_assistant_for_display(msgs, turn_id: nil, cwd: nil)
        messages_for_display([AnswerTail.find(msgs, turn_id: turn_id)].compact, cwd: cwd)
      end

      # +answer+ without its file refs (the rest kept), for a read that
      # knows no folder to check them against.
      def without_file_refs(answer)
        return answer unless answer.is_a?(Hash)

        key = [AnswerRefs::KEY.to_s, AnswerRefs::KEY].find { |name| answer[name].is_a?(Array) } or return answer
        answer.merge(key => answer[key].reject { |ref| ref.is_a?(Hash) && (ref["kind"] || ref[:kind]).to_s == Ref::FILE })
      end

      # The worker's last cards and between-turns notices (Bridge
      # cards: CardStore#list), else (no live worker) the ones the last
      # worker saved in the session's folder (#saved_cards), a card's body as
      # body_html: rendered markdown when the renderer is on, else the
      # escaped text in a <pre>, and a question card's refs checked again
      # (#with_question_refs; +cwd+ the session's folder, nil where the
      # session file isn't read: a file ref then stays only absolute).
      # @return [Array<Hash>]
      def cards_for_display(cards, cwd: nil)
        Array(cards).filter_map do |card|
          next unless card.is_a?(Hash)
          if card["type"].to_s == "question" && card["pending_question"].is_a?(Hash)
            next card.merge("pending_question" => with_question_refs(card["pending_question"], cwd: cwd))
          end
          next card unless card["type"].to_s == "card"

          card.merge("body_html" => card_body_html(card["body"].to_s))
        end
      end

      # As JSON has them (string keys and values), like a snapshot's.
      def saved_cards(id)
        JSON.parse(JSON.generate(Samagotchi::Bridge::CardStore.saved(Session.session_dir(id, state_dir: default_state_dir))))
      rescue StandardError
        []
      end

      def card_body_html(body)
        return "" if body.strip.empty?

        html = @markdown_renderer.render(body) if @markdown_renderer.available?
        html || "<pre>#{CGI.escapeHTML(body)}</pre>"
      end

      # POST /api/render {text}: the page's markdown read for a text it
      # already shows (the stage's asking text, a resolved question card's
      # reply), session-free. {html: nil} when markdown is off or
      # commonmarker is missing: the page keeps the raw text.
      def handle_render(req)
        too_large = error_response(413, "too_large", "a text to render may be up to #{MAX_RENDER_BYTES / 1024} KB")
        return too_large if req.content_length.to_i > MAX_RENDER_BYTES

        raw = request_body(req, MAX_RENDER_BYTES + 1).to_s
        return too_large if raw.bytesize > MAX_RENDER_BYTES

        body = parse_json(raw)
        return error_response(400, "invalid_json", "give {text}") unless body.is_a?(Hash) && body["text"].is_a?(String)

        html = @markdown_renderer.render(body["text"]) if @markdown_renderer.available?
        json_response(200, { html: html })
      end
    end
  end
end
