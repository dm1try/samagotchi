# frozen_string_literal: true

require_relative "llm/errors"
require_relative "tools/task_runtime"
require_relative "turn_note"

module Samagotchi
  # What each of an Engine's turn endings keeps and announces: pure builders
  # over the turn, its result or its error. The kept messages and their
  # TurnNote (#kept_messages, #ctrl_c_messages, #failed_messages), the end
  # event (#failed_event), the turn summary and the stop facts. The Engine
  # forwards each here and keeps the steps that hold the event lock or save
  # (end_turn, complete_turn, store_answer_display, record_last_turn).
  class TurnEndings
    # @param failure_summary [#call] (error) → a failed turn's one line (Engine#failure_summary)
    def initialize(failure_summary:)
      @failure_summary = failure_summary
    end

    # Why a turn stopped, from its end event (LastTurn::STOP_FACTS), for a
    # parent agent's wait (ReplyWait): a provider error's kind and whether
    # a retry may help, a cancel's reason and the hook that stopped it.
    # Only what is known.
    def stop_facts(event)
      case event&.dig(:type)
      # kept_steps: the turn's work stayed (a parent must not send the task again).
      when :turn_failed
        { error_kind: event[:error_kind]&.to_s, retryable: event[:retryable], kept_steps: event[:kept_steps] }
      when :turn_canceled
        { cancel_reason: event[:cancellation_reason]&.to_s, stopped_by: event[:cancelled_by]&.to_s }
      else {}
      end
    end

    # What the session keeps of a turn that ended normally (nil: nothing to
    # replace). Runs under the event lock: it also adds the turn's note to
    # result.conversation, which the REPL keeps as-is.
    # A turn that ran out of iterations ends at its tool results, so a
    # continue resumes from them rather than after a made-up reply (and a
    # step-limit Continue from its run's start: ModelResult#run_start).
    def kept_messages(turn, result, seconds)
      conversation = result.conversation if result.conversation.is_a?(Array)
      # Nothing visible (no text) is a turn the model should know ended
      # that way: the note, and nothing made up as its answer. The note's
      # marker is for the UIs (the notice, and the empty steps after a
      # reload); it goes on the result's conversation too (the REPL keeps it).
      # A retry's nudge at the tail goes: this note says it all. An earlier
      # turn's note stays: it says why that turn ended.
      if result.empty_answer?
        note = TurnNote.empty(retries: result.empty_retries, steps: result.empty_steps, refusal: result.refusal)
        conversation&.replace(TurnNote.without_trailing_nudge(conversation))
        saved = TurnNote.without_trailing_nudge(conversation || turn.session.messages)
        conversation << note if conversation
        saved + [note]
      elsif result.canceled? && conversation
        conversation << TurnNote.cancelled(result.cancellation_reason, seconds: seconds,
                                                                      stopped_by: turn.controller.detail,
                                                                      shown: TurnNote.interrupted_tail?(conversation),
                                                                      running_tasks: Tools::TaskRuntime.running_created_in(conversation))
      else
        conversation
      end
    end

    # A Ctrl-C keeps the loop's conversation so far, as a Stop does (its
    # finished tool iterations, every call answered: ToolResponse.run_batch),
    # else the turn's messages so far (it came before the loop), with a
    # cancel note naming the tasks still running; nil before there are any.
    def ctrl_c_messages(turn, interrupt, seconds)
      kept = loop_conversation(interrupt) || turn.messages
      return nil unless kept

      note = TurnNote.cancelled(:ctrl_c, seconds: seconds, running_tasks: Tools::TaskRuntime.running_created_in(kept))
      TurnNote.replace_trailing(kept, note)
    end

    # The conversation the loop had built when +error+ ended the turn
    # (LLM::FailedTurn), or nil.
    def loop_conversation(error)
      error.partial_conversation if error.respond_to?(:partial_conversation) && error.partial_conversation.is_a?(Array)
    end

    # A failure keeps the loop's partial conversation (else the turn's
    # messages so far) with a failed note; nil when the turn never reached
    # the model. The model reads why on its next turn. A turn that got to
    # tool results (LLM::FailedTurn.progress) says so in the note; on the
    # error (kept_steps) too unless it failed in a way that rolls back
    # (FailedTurn.keeps_work?: a context overflow). The UIs keep a marked
    # turn (TurnFlow#prompt_turn_failed), and roll back the others, with a
    # note of their own; -p --non-interactive keeps what this keeps.
    def failed_messages(turn, error)
      kept = loop_conversation(error) || turn.messages
      return nil unless kept

      steps = LLM::FailedTurn.progress(turn.session.messages, kept)
      error.kept_steps = steps if steps && error.is_a?(LLM::FailedTurn) && LLM::FailedTurn.keeps_work?(error)
      summary = error.respond_to?(:summary) ? error.summary : error.message
      TurnNote.replace_trailing(kept, TurnNote.failed(summary, continued: turn.continue, steps: steps))
    end

    # Called after #failed_messages, which marks the error's kept steps.
    def failed_event(error, seconds)
      failed = { type: :turn_failed, error_class: error.class.name, message: error.message,
                 duration_ms: (seconds * 1000).round }
      # Its work stays: the UIs say so, as after a cancel.
      steps = LLM::FailedTurn.kept_steps(error)
      failed[:kept_steps] = steps if steps
      # A provider error says what kind it is, for one line per kind in the UIs.
      if error.is_a?(LLM::ProviderError)
        failed.merge!(error_kind: error.kind, retryable: error.retryable?, host: error.host, summary: failure_summary(error))
      end
      failed
    end

    # JSON-safe digest of a finished turn for renderers (in-process or over the
    # Bridge): the bits of the native loop's result a UI needs beyond `result:`.
    # @param result [LLM::ModelResult]
    # @return [Hash]
    def turn_summary(result)
      summary = {
        output: result.output.to_s,
        exhausted: result.exhausted?,
        resumable: result.resumable?,
        pending_tool_calls: result.pending_tool_calls?,
        tool_activity: Array(result.tool_activity).map(&:dup),
        context_status: result.context_status&.dup
      }
      # No answer: every UI shows its notice (TurnNote.empty_answer_line).
      summary[:empty_answer] = { retries: result.empty_retries.to_i, refusal: result.refusal }.compact if result.empty_answer?
      summary
    end

    private

    def failure_summary(error) = @failure_summary.call(error)
  end
end
