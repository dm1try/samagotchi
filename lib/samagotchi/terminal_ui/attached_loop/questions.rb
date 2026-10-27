# frozen_string_literal: true

require_relative "../../client_id"
require_relative "../exit_lines"
require_relative "../../session_commands"
require_relative "../question_prompt"

module Samagotchi
  class TerminalUI
    class AttachedLoop
      # Question and continue prompts for the attached loop.
      # Reads @as_parent, @answered_ids, @client, @continue_offer, @offer_asked,
      # @question, @reader, @screen, @set_aside, @view; writes @continue_answer,
      # @continue_offer, @offer_asked, @previewed_id, @question, @question_pending,
      # @set_aside, @unanswered.
      # Calls the loop helpers #client_label, #detach, #own?, #paint, #send_command,
      # #stale_worker, #sync_prompt, #via, and #worker_down.
      module Questions
        private

        # The worker says what became of it (:continue_resolved); an invalid
        # answer gets its error and the offer stays.
        def answer_continue(text)
          echo_answer(text) if TurnFlow.continue_decision(text).first == :invalid
          @continue_answer = text.empty? ? "yes" : text
          send_command(continue_line(text))
          nil
        end

        # A bare answer at the continue prompt, as the REPL reads it (an empty
        # one is yes).
        def continue_line(text)
          text.empty? ? SessionCommands::CONTINUE_COMMAND : "#{SessionCommands::CONTINUE_COMMAND} #{text}"
        end

        def offer_continue(event)
          @continue_offer = { context: event[:context], no_interrupt: event[:no_interrupt] }
          sync_prompt
          sync_continue_slot
        end

        CONTINUE_DECISIONS = { "resume" => "yes", "abort" => "no", "abort_with_reason" => "no, with a reason",
                               "refused" => "not continued: the participant may no longer run turns" }.freeze

        # The offer's choices go; one line says what became of it. Another
        # UI's answer shows as its command line (web> /continue yes) instead.
        def continue_resolved(event)
          @continue_offer = nil
          # Asked as the step-limit question: its line says what became of it.
          asked = @offer_asked
          @offer_asked = false
          sync_continue_slot
          who = client_label(event[:client_id], "another UI")
          outcome = if event[:decision] == "dropped"
                      "(dropped: #{own?(event[:client_id]) ? "you" : who} sent a new prompt)"
                    elsif event[:decision] == "refused"
                      CONTINUE_DECISIONS["refused"]
                    elsif own?(event[:client_id])
                      @continue_answer || CONTINUE_DECISIONS.fetch(event[:decision].to_s, event[:decision].to_s)
                    end
          @continue_answer = nil
          @screen.commit(QuestionSlot.continue_summary(outcome, paint: method(:paint))) if outcome && !asked
          # Back to the > prompt: with the text a question set aside meanwhile
          # (#close_question), else what the ? read holds.
          set_aside = @set_aside
          @set_aside = nil
          set_aside ? sync_prompt(keep_text: false, prefill: set_aside) : sync_prompt
        end

        # The notes slot shows the offer's choices while it waits (a question
        # has the slot while it is open).
        def sync_continue_slot
          return if @question || @offer_asked

          if @continue_offer
            @screen.set_slot(:notes, QuestionSlot.continue_offer(@continue_offer[:context], paint: method(:paint)))
          else
            @screen.clear_slot(:notes)
          end
        end

        def unanswered_question(pending)
          @unanswered = pending
          detach("A question waits for an answer: #{via.attach(@client.session_id)}")
          :unanswered
        end

        def prompt_text
          return paint(QUESTION_PROMPT, 33) if @question || @continue_offer

          paint(PROMPT, 92)
        end

        # Switch the open prompt to ? for the answer and show the choices in
        # the notes slot, fitted to the terminal. Once the question closes,
        # one line (the question and what became of it) stays.
        def ask(pending)
          return unless pending

          @view.finish_thinking_spinner
          # What was typed at the prompt waits for the question to close.
          # Not over text already set aside (a question that closed while a
          # continue offer waits): the ? read holds an answer then, if anything.
          @set_aside = @reader&.typed_text.to_s.then { |typed| typed.empty? ? nil : typed } unless @question || @set_aside
          @question = QuestionPrompt.new(pending)
          @question_pending = pending
          # The step-limit question stands for the continue offer's own slot
          # until the offer is resolved.
          @offer_asked = true if @question.continue?
          # An edit's diff goes above, into the scrollback, once per question
          # (a join gets it from the snapshot and may get the event too).
          unless @previewed_id == @question.id
            @previewed_id = @question.id
            preview = @question.preview_lines(paint: method(:paint))
            @screen.commit(preview.join("\n")) unless preview.empty?
          end
          # The prompt first, so the choices never show under the typed text.
          sync_prompt(keep_text: false)
          @screen.set_slot(:notes, @question.slot(paint: method(:paint)))
        end

        def answer_question(text)
          # Enter alone at the step-limit question continues (it can't be
          # dismissed), as at the continue prompt.
          return dismiss_question if text.empty? && !@question.continue?

          answer = @question.parse(text)
          @screen.commit(answer.note) if answer.note
          unless answer.ok?
            echo_answer(text)
            return @screen.commit(answer.error)
          end

          parent = @as_parent ? { client_id: ClientId::CLI_ANSWER } : {}
          reply = @client.answer(id: @question.id, selected: answer.selected, freeform: answer.freeform, **parent)
          case reply.status
          when 200
            @answered_ids << @question.id
            close_question(@question.answer_text(answer))
          when 409 then close_question("(already answered in another UI)")
          when 408 then @screen.commit("could not answer (#{ExitLines::LATE})")
          else
            detail = reply.json&.fetch("detail", nil) || reply.json&.fetch("error", nil)
            @screen.commit("could not answer (#{[reply.status, detail].compact.join(" ")})")
          end
          nil
        rescue SystemCallError, IOError => e
          @screen.commit("could not answer (#{worker_down(e)})")
          nil
        end

        # An empty answer dismisses the question, as in the REPL: the tool
        # returns unanswered (an approval: denied) and the turn goes on. The
        # :question_cancelled every UI gets finds it already closed here.
        def dismiss_question
          reply = @client.dismiss_question(id: @question.id)
          case reply.status
          when 200 then close_question(@question.approval? ? "(denied)" : "(cancelled)")
          when 409 then close_question("(question already closed in another UI)")
          when 404 then @screen.commit("#{stale_worker("dismiss questions")}; Ctrl-C cancels the turn")
          when 408 then @screen.commit("could not dismiss the question (#{ExitLines::LATE}); Ctrl-C cancels the turn")
          else
            # The question stays open (after a 404 too).
            detail = reply.json&.fetch("error", nil)
            @screen.commit("could not dismiss the question (#{[reply.status, detail].compact.join(" ")}); Ctrl-C cancels the turn")
          end
          nil
        rescue SystemCallError, IOError => e
          @screen.commit("could not dismiss the question (#{worker_down(e)}); Ctrl-C cancels the turn")
          nil
        end

        # A line read at ? that isn't a (valid) answer: the read left no echo,
        # so it shows above what it got.
        def echo_answer(text) = @screen.commit("#{paint(QUESTION_PROMPT, 33)}#{text}")

        def question_relayed(event)
          return unless @question && @question.id == event[:id].to_s

          @question.relayed_to = event[:relayed_to]
          @screen.set_slot(:notes, @question.slot(paint: method(:paint)))
        end

        def question_answered(event)
          return unless @question
          return close_question(nil) if @answered_ids.include?(event[:id])

          answer = event[:answer] || {}
          picked = [*Array(answer[:selected]), answer[:freeform]].compact.join(", ")
          close_question("#{picked.empty? ? "(answered)" : picked} (in another UI)")
        end

        # @param outcome [String, nil] what became of it, for the line that
        #   stays in the scrollback (nil: none, it was closed already)
        def close_question(outcome)
          @screen.clear_slot(:notes)
          @screen.commit(@question.summary(outcome, paint: method(:paint))) if outcome
          @question = nil
          # A continue offer still waiting keeps the ? prompt (the step-limit
          # question closes before its offer resolves): the text set aside
          # waits for the > prompt (#continue_resolved).
          return sync_continue_slot if @continue_offer

          set_aside = @set_aside
          @set_aside = nil
          sync_prompt(keep_text: false, prefill: set_aside)
        end

        # Restart the open read when its prompt no longer fits (a question or a
        # continue offer opened or closed), first erasing the prompt Reline drew.
        # What is typed there goes along (+keep_text+), or +prefill+ goes in.
        def sync_prompt(keep_text: true, prefill: nil)
          return unless @reader

          @screen.synchronize do
            next if @reader.current == prompt_text

            @screen.clear_slot(:editor)
            @reader.reprompt(keep_text: keep_text, prefill: prefill)
          end
        end
      end
    end
  end
end
