# frozen_string_literal: true

require "time"
require_relative "last_turn"
require_relative "log"
require_relative "steer"
require_relative "turn_origin"

module Samagotchi
  # A session worker's continue offer: what it announces when a turn runs out
  # of iterations, when a prompt or a reminder drops the offer, when a
  # /continue answers it, and the continue turn a yes runs. TurnFlow keeps
  # the offer itself (its checkpoint and context); this is the worker's side
  # of it, which every UI hears about.
  #
  # The offer is also a question (kind "continue", the step-limit
  # question), standing on the Engine's question desk between turns, so
  # everything built on a pending question sees it: chi send --wait (exit
  # 3), chi answer, the lists' waiting, the web's badge and bell. Its
  # answer becomes the matching /continue line on the worker's command
  # queue, which runs it as a typed one (#run_command's path).
  class ContinueOffer
    KIND = "continue"
    HEADER = "Step limit"
    CONTINUE = "Continue"
    STOP = "Stop"
    PROMPT_PREVIEW = 200
    # last_turn's outcome after a Stop: no turn ran, but the wait of
    # whoever answered (chi answer) ends on it.
    NOT_CONTINUED = "not_continued"

    # @param engine [Engine] announces, records activity, holds the question
    # @param turn_flow [TurnFlow] owns the offer
    # @param run_turn [#call] (prompt, **turn_args, &block) the worker's
    #   run_engine_turn
    # @param max_iterations [#call] (no_interrupt) → Integer
    # @param queue_command [#call] (line, client_id:) queues a session
    #   command as a card's (Bridge#queue_command, card: true)
    # +participant_refused+ (author → reason or nil): why a participant's
    # turn may no longer run ("revoked", "cap_reached": Worker's check).
    # @param save [#call] saves the session (a refused Continue's Stop)
    def initialize(engine:, turn_flow:, run_turn:, max_iterations:, queue_command: nil, participant_refused: ->(_) {},
                   save: -> {})
      @engine = engine
      @save = save
      @turn_flow = turn_flow
      @run_turn = run_turn
      @max_iterations = max_iterations
      @queue_command = queue_command
      @participant_refused = participant_refused
      # A question was posted since the last close (it may have been
      # answered or superseded meanwhile).
      @asked = false
      # The text a Continue answer came with ({text:, source:}): it steers
      # the continue turn (#run_continue_turn).
      @continue_steer = nil
    end

    attr_writer :queue_command

    def awaiting? = @turn_flow.awaiting_continue?

    # TurnFlow keeps the checkpoint (a cancelled turn's, for !rollback) and
    # the continue offer of a turn that ran out of iterations; an offer made
    # (or kept, after a cancelled continue turn) is announced and asked.
    def after_turn(result, continue: false, no_interrupt: false)
      outcome = @turn_flow.after_turn(result, continue: continue, no_interrupt: no_interrupt)
      return unless %i[continue_offered continue_cancelled].include?(outcome)

      announce_offer
    end

    # A prompt (or a reminder turn) taken while a continue is offered
    # replaces the answer (D2): the offer goes, the partial turn stays.
    # @param origin [TurnOrigin, nil] the taken turn's
    def drop(origin)
      return unless awaiting?

      @continue_steer = nil
      close("dropped")
      @engine.synchronize_events do
        @turn_flow.drop_offer!
        @engine.announce(type: :continue_resolved, decision: "dropped", client_id: origin&.client_id)
      end
      @engine.record_activity
    end

    # Whether a command's +result+ answered the offer that was pending
    # (+awaiting+) as it started.
    def resolved?(awaiting, result)
      awaiting && result.decision && result.decision != :invalid ? true : false
    end

    # Called with the event log held, before the command's command_ran. A
    # Stop runs no turn: last_turn says so (not_continued), so a wait on
    # it ends (chi answer --option Stop).
    # It carries the offer turn's enqueued_id, so a wait on that turn
    # (ReplyWait's turn:) ends on it too.
    # A Continue on the offer of a participant who may no longer run a turn
    # (revoked, expired, at the cap since) is decided here, before anything
    # says "resume": it ends the offer as a Stop does (#refuse_continue).
    def announce_resolved(result, command)
      if result.resume && (reason = refusal_of_offer_author)
        return refuse_continue(reason, command)
      end

      @engine.announce(type: :continue_resolved, decision: result.decision.to_s, client_id: command.client_id)
      return if result.resume

      session = @engine.session
      return unless session

      session.last_turn = LastTurn.new(outcome: NOT_CONTINUED, ended_at: Time.now.iso8601(3),
                                       enqueued_id: offer_turn_id)
    end

    # After a command's command_ran and save: a /continue that answered the
    # offer closes its question; a command that dropped the offer
    # otherwise (!rollback) too.
    # @param resolved [Boolean] it answered the offer (#resolved?)
    def after_command(result, resolved:)
      close(resolved ? "answered" : "dropped") unless awaiting?
      return unless resolved

      # Answered without a turn (a typed /continue no that got there before
      # the answer's /continue yes): the answer's text steers nothing.
      @continue_steer = nil unless result.resume

      # An offer answered without a turn ("no") is activity: the recap
      # written at the offer (it says the turn stopped) gets rewritten.
      @engine.record_activity unless result.resume
    end

    # The continue offer was answered yes: resume the conversation without a
    # user message, with the iteration limit the offer's turn had, from the
    # run that turn started (TurnFlow#resume_from: its reasoning stays). A failure
    # keeps the offer, as the REPL does ("continue prompt preserved"), and
    # asks again, one before the turn began too (logged, no :turn_failed).
    # The answer's text is carried into the turn as it begins; a turn that
    # never began leaves it to no other.
    # The continue turn is the offer turn's: its origin carries that turn's
    # enqueued_id, so its last_turn, its reply file and its checkpoint mark
    # do too, and a wait on that turn (chi answer) gets its reply; and its
    # author, so a participant's turn continues as theirs, inside the
    # review boundary and on their spend (never as the owner's). One whose
    # participant may no longer run a turn isn't continued.
    def run_continue_turn(command)
      # Refused as it was answered (#announce_resolved): the offer is gone.
      return @continue_steer = nil unless awaiting?

      offer = @turn_flow.offer
      resume_from = @turn_flow.resume_from
      enqueued_id = offer_turn_id
      author = Steer.sender_author(@engine.session&.last_turn&.author)
      close("answered")
      if author && (reason = @participant_refused.call(author))
        @continue_steer = nil
        return @engine.synchronize_events { refuse_continue(reason, command) }
      end

      steer = @continue_steer
      @continue_steer = nil
      begin
        begin
          @engine.steer_next_turn(steer[:text], source: steer[:source]) if steer
          @turn_flow.before_continue_turn
        rescue StandardError => e
          Log.warn(:worker, "turn_not_begun", continue: true, error: e.class.name, msg: e.message)
          return announce_offer(offer)
        end
        origin = TurnOrigin.new(client_id: command.client_id, enqueued_id: enqueued_id, author: author)
        @run_turn.call(nil, continue: true, origin: origin, resumed: true, resume_from: resume_from,
                            max_iterations: @max_iterations.call(offer[:no_interrupt])) do |result, error|
          if error
            announce_offer(offer)
          else
            after_turn(result, continue: true, no_interrupt: offer[:no_interrupt])
          end
        end
      ensure
        @engine.drop_carried_steers if steer
      end
    end

    # The question goes (the offer went, or was answered).
    # @param reason [String] dropped, answered
    def close(reason)
      return unless @asked

      @asked = false
      @engine.withdraw_question(reason)
    end

    private

    def refusal_of_offer_author
      author = Steer.sender_author(@engine.session&.last_turn&.author)
      author && @participant_refused.call(author)
    end

    # The offer of a participant refused since (+reason+: revoked,
    # cap_reached) ends as a Stop: announced as "refused" (with a notice
    # for the owner), the model reads it wasn't continued, last_turn says
    # not_continued with the offer turn's enqueued_id (a wait on it ends),
    # and awaiting_continue? goes false (idle exit, /exit, the held
    # participant turns go on). The question goes with the next close.
    # Called with the event log held.
    def refuse_continue(reason, command)
      author = @engine.session&.last_turn&.author
      enqueued_id = offer_turn_id
      @engine.announce(type: :continue_resolved, decision: "refused", reason: reason.to_s, client_id: command.client_id)
      @engine.announce(type: :hook_notice, hook: "participants", level: :warn, between_turns: true,
                       text: format(REFUSED_NOTICE, who: author.to_s.delete_prefix("p:"), reason: REFUSED_WHY.fetch(reason.to_s, reason.to_s)))
      @turn_flow.abort_continue!
      session = @engine.session
      session.last_turn = LastTurn.new(outcome: NOT_CONTINUED, ended_at: Time.now.iso8601(3), enqueued_id: enqueued_id) if session
      @continue_steer = nil
      close("answered")
      @save.call
      nil
    end

    REFUSED_NOTICE = "Not continued: participant %<who>s's turn %<reason>s."
    REFUSED_WHY = { "revoked" => "is refused (their link was revoked or expired)",
                    "cap_reached" => "is refused (they reached their review cap)" }.freeze

    # The enqueued_id of the turn the offer stands for: the exhausted
    # turn's last_turn (a canceled continue turn's carries the same id);
    # nil when it ran no input (a reminder turn, a delegate's first).
    def offer_turn_id = @engine.session&.last_turn&.enqueued_id

    def announce_offer(offer = @turn_flow.offer)
      @engine.announce(type: :continue_offered, context: offer[:context], no_interrupt: offer[:no_interrupt])
      ask
    end

    # Post the step-limit question while the offer stands (again, after a
    # question that superseded it closed).
    def ask
      return unless awaiting?

      @asked = true
      @engine.post_question(question_fields(@turn_flow.offer), on_answer: method(:answered),
                                                               on_superseded_close: method(:ask))
    end

    def question_fields(offer)
      limit = limit_of_last_turn
      context = offer[:context] || {}
      text = "The turn ran out of iterations#{" (#{limit} steps)" if limit} before it answered. Continue it?"
      prompt = context[:original_prompt].to_s.strip
      unless prompt.empty?
        prompt = "#{prompt[0, PROMPT_PREVIEW].rstrip}..." if prompt.length > PROMPT_PREVIEW
        text += "\nPrompt: #{prompt}"
      end
      { kind: KIND, header: HEADER, question: text, options: [CONTINUE, STOP], multi_select: false,
        # Continue spends time and tokens, Stop denies (ParentPolicy).
        allow_freeform: true, effects: %w[spend deny], limit: limit, context: context }.compact
    end

    # The limit the offer's turn ran out at (Engine's last_turn marker).
    def limit_of_last_turn
      last = @engine.session&.last_turn
      last&.exhausted ? last.limit : nil
    end

    # The question's answer as the /continue line a typed answer would be:
    # Continue → yes, and a text with it steers the continue turn (from the
    # parent agent when the answer says so); Stop → no; a text (with Stop,
    # or alone) → no, <text>.
    def answered(answer, client_id:)
      # The /continue line takes the text on one line; the steer keeps its
      # line breaks.
      text = answer.freeform.to_s.gsub(/\s+/, " ").strip
      @continue_steer = nil
      if answer.selected.include?(CONTINUE) && !text.empty?
        @continue_steer = { text: answer.freeform.to_s.strip,
                            source: answer.parent_agent? ? "parent_agent" : "user" }
      end
      line = if answer.selected.include?(CONTINUE) then "/continue yes"
             elsif text.empty? then "/continue no"
             else "/continue no, #{text}"
             end
      @queue_command&.call(line, client_id: client_id)
    end
  end
end
