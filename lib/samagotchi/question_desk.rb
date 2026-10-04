# frozen_string_literal: true

require "json"
require "monitor"
require "securerandom"
require "time"

require_relative "log"
require_relative "tools/ask_user_question"
require_relative "guardrails/parent_approvals"
require_relative "guardrails/parent_continue"

module Samagotchi
  # An Engine's question flow: the one open question (ask_user_question, a
  # hook's ask_user, a guardrail approval), its answer and its cancel, shared
  # by every UI. The turn thread blocks in #open_question; the UIs answer or
  # cancel from theirs (a REPL answers inline through the sync handler).
  #
  # A standing question (#post: a worker's step-limit question, kind
  # "continue") blocks nobody: it waits between turns, its answer goes to
  # its on_answer, and its poster withdraws it (#withdraw). It can't be
  # dismissed. One question stays pending at a time: a question opened
  # while one stands supersedes it (withdrawn, reason "superseded"), and
  # once that one closes the standing one is offered again
  # (on_superseded_close); one posted while another is open waits for it
  # the same way.
  #
  # What it needs from the Engine comes through lookups, read at call time.
  class QuestionDesk
    # Raised by #answer when the question it targets is no longer open
    # (never asked, superseded, already answered or cancelled). A subclass
    # of ArgumentError for existing callers; transports map it to 409 Conflict.
    class NotPending < ArgumentError; end

    # Raised by #answer when a parent agent's answer (chi answer's client
    # id) allows an approval further than this worker's
    # guardrails.parent_approvals lets it (Guardrails::ParentApprovals), or
    # continues a turn turn.parent_continue keeps it from
    # (Guardrails::ParentContinue). The question stays open; transports map
    # it to 403.
    class Refused < StandardError
      # @return [Symbol] :off, :once_only, :protected or :stop_only
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super(reason == :stop_only ? "a parent may not continue this turn" : "a parent may not allow this approval (#{reason})")
      end
    end

    # Raised by #cancel for a standing question (#post): its poster closes
    # it, an answer settles it. Transports map it to 409 not_dismissable.
    class NotDismissable < StandardError; end

    # A step-limit question's options (kind "continue").
    CONTINUE_KIND = "continue"
    CONTINUE_OPTION = "Continue"

    # Seconds between two looks of an open question's watch (#open_question).
    WATCH_INTERVAL = 0.5

    DISMISSED_NOTE = "The user dismissed the question without answering. Don't do what you asked about, " \
                     "or anything else that changes files or state. Finish your reply with what you found " \
                     "and what you would do, and wait."

    # @param session           [#call] → Session, nil
    # @param state_dir         [#call] → String, the session's state dir
    # @param emit              [#call] (event) → emits an event to the turn sink + observers
    # @param cancel_controller [#call] → CancellationController, nil (the running turn's)
    # @param interface         [#call] → Symbol, the Engine's interface
    # @param user_input        [#call] (session_id) → a human answered (ArchiveStore)
    def initialize(session:, state_dir:, emit:, cancel_controller:, interface:, user_input:)
      @session_lookup = session
      @state_dir_lookup = state_dir
      @emit = emit
      @cancel_controller_lookup = cancel_controller
      @interface_lookup = interface
      @user_input = user_input
      # A Monitor: re-entered by the specs from the same thread.
      @lock = Monitor.new
      @cv = @lock.new_cond
      @pending = nil
      @answer = nil
      @sync_handler = nil
      # The standing question while it is @pending: {id:, fields:,
      # on_answer:, on_superseded_close:}; @shelved, one superseded by (or
      # posted during) another question, offered again when that closes.
      @standing = nil
      @shelved = nil
    end

    # @return [Hash, nil] current pending question (thread-safe copy)
    def pending
      @lock.synchronize { @pending&.dup }
    end

    # Ask the model's question (ask_user_question): the kernel's
    # question_handler, called on the turn thread with the payload
    # Tools::AskUserQuestion.validate made. Opens it (#open_question) and
    # returns the answer as JSON for the tool result.
    # @param payload [Hash] {question:, options:, header:, multi_select:, allow_freeform:}
    # @return [String] normalized answer JSON
    def request(payload)
      result = open_question(payload.slice(:question, :options, :header)
                                    .merge(multi_select: !!payload[:multi_select], allow_freeform: !!payload[:allow_freeform]))
      # Dismissed (the card's dismiss, Esc): an answer of its own, not a
      # tool failure the model learns to avoid the tool from.
      result = { dismissed: true, id: result[:id], note: DISMISSED_NOTE } if result.is_a?(Hash) && result[:error] == "no answer"
      # Who answered is for the relay, not the model's tool result.
      result = result.except(:by) if result.is_a?(Hash)
      result.is_a?(String) ? result : JSON.generate(result)
    end

    # Open a question for the UIs and wait for its answer. Emits
    # :question_requested, persists it to the session, and BLOCKS until
    # answer / cancel wakes it (or the turn is cancelled).
    # The fields go to pending as given (no cleaning), extra keys
    # included, so a caller can add its own (kind:, approval:).
    # @param fields [Hash] question:, options:, header:, multi_select:, allow_freeform:, …
    # @param watch [#call, nil] asked every WATCH_INTERVAL seconds while the
    #   question waits (outside the lock): a String closes the question with
    #   that reason, announced and returned as a cancel; nil keeps waiting.
    #   An answer recorded first wins. Not on the sync-handler path.
    # @return [Hash, String] the answer {id:, selected:, freeform:, selected_indices:},
    #   or {error:, …}; a String when a sync handler returned text itself
    def open_question(fields, watch: nil)
      supersede_standing
      ask(fields, watch)
    ensure
      offer_shelved
    end

    # Publish a standing question: pending (saved, announced with
    # standing: true) without blocking anyone. An answer to it is checked
    # as any other and handed to +on_answer+ (answer, client_id:) on the
    # answering thread, after it is cleared and :question_answered is out.
    # Posted while another question is open, it waits for that one to
    # close (as a superseded one does). A standing one already up is
    # replaced (withdrawn, reason "replaced").
    # @param fields [Hash] as for #open_question
    # @param on_answer [#call] (answer, client_id:)
    # @param on_superseded_close [#call, nil] called when a question that
    #   superseded it closes (its poster posts it again if it still
    #   stands); nil: posted again as it was
    # @return [Hash, nil] the pending question; nil when it waits for another
    def post(fields, on_answer:, on_superseded_close: nil)
      standing = { fields: fields, on_answer: on_answer, on_superseded_close: on_superseded_close }
      shelved = @lock.synchronize do
        next false unless @pending && !@standing

        @shelved = standing
        true
      end
      return nil if shelved

      withdraw("replaced")
      publish(fields, standing: standing)
    end

    # Withdraw the standing question (its poster's close: the offer went,
    # was answered by a command, the worker leaves), announced as
    # :question_cancelled with +reason+. A shelved one just goes.
    # @param id [String, nil] only this one
    # @return [Boolean] whether one was pending
    def withdraw(reason, id: nil)
      withdrawn = @lock.synchronize do
        @shelved = nil if id.nil?
        standing = @standing
        next nil unless standing && @pending && @pending[:id] == standing[:id]
        next nil if id && standing[:id].to_s != id.to_s

        @standing = nil
        @pending = nil
        standing[:id]
      end
      return false unless withdrawn

      clear_saved_question
      emit({ type: :question_cancelled, id: withdrawn, reason: reason.to_s })
      true
    end

    # @return [Boolean] the pending question is a standing one
    def standing? = @lock.synchronize { !@standing.nil? }

    private def ask(fields, watch)
      pending = publish(fields)
      id = pending[:id]

      # If a synchronous UI handler is registered (TUI), invoke it inline on the
      # SAME thread that called request_question (TerminalUI's REPL thread is the
      # turn thread — no second thread exists to answer). This avoids deadlock.
      # This path is TUI-specific but the surrounding emit/clear is generic, so
      # any future UI that registers a sync handler gets the same guarantee.
      if @sync_handler
        begin
          sync_res = @sync_handler.call(pending.dup)
          # Handler may have called answer_question or returned a hash/string.
          # Decided under the lock; saved and announced after it (never emit
          # holding the question lock: a snapshot holds the event lock and
          # then reads #pending).
          ans = @lock.synchronize do
            if @answer
              @pending = nil
              @answer
            elsif sync_res.is_a?(Hash) && sync_res[:selected]
              # Treat returned hash as answer (handler rendered and parsed)
              @answer = sync_res
              @pending = nil
              sync_res
            end
          end
          if ans
            clear_saved_question
            emit({ type: :question_answered, id: id, answer: ans })
            return ans
          end
          return sync_res if sync_res.is_a?(String) && !sync_res.strip.empty?
        rescue StandardError => e
          Log.warn(:turn, "question_handler_failed", echo: "[ask_user_question] sync handler failed: #{e.message}", error: e.class.name)
        end
        # Sync handler existed but did not produce an answer — do not deadlock on
        # CV (no cross-thread answerer exists for synchronous UIs). Clear pending
        # and return an error so the model can fallback to plain text. Generic
        # observers will discard the stale question_requested via staleness check.
        @lock.synchronize { @pending = nil }
        clear_saved_question
        return { error: "no answer", detail: "handler failed to capture selection", id: id }
      end

      # Block until answered/cancelled (cross-thread path: WEB/Bridge/background worker)
      closed_reason = wait_for_answer(watch)
      answer = nil
      cancelled_reason = nil
      @lock.synchronize do
        answer = @answer
        controller = cancel_controller
        if answer.nil?
          cancelled_reason = closed_reason || (controller.reason.to_s if controller&.cancelled?)
        end
        @pending = nil
      end
      # Saved and announced outside the question lock (see the sync path).
      clear_saved_question
      if cancelled_reason
        emit({ type: :question_cancelled, id: id, reason: cancelled_reason })
        return { error: "cancelled", reason: cancelled_reason, id: id }
      end

      if answer
        emit({ type: :question_answered, id: id, answer: answer })
        answer
      else
        { error: "no answer", id: id }
      end
    end

    # Answer the pending question (called from UI thread).
    # @param id [String] pending id
    # @param selected [Array<String>] values/labels
    # @param freeform [String, nil]
    # @param client_id [String, nil] who answers
    # @param parent_agent [Boolean, nil] the answer is a parent agent's, so
    #   it is held to guardrails.parent_approvals on an approval and doesn't
    #   bring the session back to the lists; nil: chi answer's client id says so
    # @return [Hash] normalized answer; a parent agent's carries by: "parent_agent"
    # @raise [NotPending, ArgumentError, Refused]
    def answer(id:, selected:, freeform: nil, client_id: nil, parent_agent: nil)
      sel = Array(selected).map { |v| v.to_s.strip }.reject(&:empty?)
      fm = freeform.to_s.strip
      fm = nil if fm.empty?
      parent_agent = client_id.to_s == Guardrails::ParentApprovals::CLIENT_ID if parent_agent.nil?
      # Read before the lock (config may touch the disk); this worker's own.
      parent_setting = Guardrails::ParentApprovals.setting if parent_agent
      parent_continue = Guardrails::ParentContinue.allowed? if parent_agent
      standing = nil
      answer = @lock.synchronize do
        pending = @pending
        raise NotPending, "no pending question" unless pending
        raise NotPending, "id mismatch" unless pending[:id].to_s == id.to_s
        # First responder wins: after the first answer the turn thread clears
        # @pending in a later lock block, so a second UI's answer can
        # land in between and must not overwrite the first.
        raise NotPending, "question already answered" if @answer
        raise NotPending, "question #{pending[:status]}" unless pending[:status].to_s == "pending"

        answer = validated_answer(pending, sel, fm, parent_agent: parent_agent, parent_setting: parent_setting)
        if parent_agent && (reason = Guardrails::ParentContinue.refusal(pending, sel, allowed: parent_continue))
          raise Refused, reason
        end

        if @standing
          # No waiter: cleared here, so a second answer finds none.
          standing = @standing
          @standing = nil
          @pending = nil
        else
          @answer = answer
          @cv.broadcast
        end
        answer
      end
      settle_standing(standing, answer, client_id) if standing
      # A human answered: the session is back in the lists (ArchiveStore).
      @user_input.call(session&.id) unless parent_agent
      answer
    end

    # Mark the pending question as relayed to a parent session's user, or
    # clear the mark (relayed_to: nil): saved with it and announced as
    # :question_relay, so every UI shows where else it can be answered. Under
    # the question lock, so the save never lands after the turn thread
    # cleared the question.
    # @param relayed_to [Hash, nil] {parent_id:, parent_short:, relay_id:}
    # @param reason [String, nil] why a mark was cleared (parent_gone, …)
    # @return [Boolean] false when +id+ isn't the question pending now
    def annotate(id, relayed_to:, reason: nil)
      marked = @lock.synchronize do
        pending = @pending
        next nil unless pending && pending[:id].to_s == id.to_s
        next nil if @answer || pending[:status].to_s != "pending"

        relayed_to ? pending[:relayed_to] = relayed_to : pending.delete(:relayed_to)
        if session
          session.pending_question = pending.dup
          begin; session.save(state_dir: state_dir); rescue StandardError; nil; end
        end
        pending[:id]
      end
      return false unless marked

      emit({ type: :question_relay, id: marked, relayed_to: relayed_to, reason: reason }.compact.merge(relayed_to: relayed_to))
      true
    end

    def sync_handler=(block)
      @sync_handler = block
    end

    # @return [Boolean] a REPL answers inline (no wait loop)
    def sync_handler? = !@sync_handler.nil?

    # Cancel the pending question (e.g. /cancel, a dismiss). Announces which
    # one, so every UI closes it; with none pending there is nothing to
    # announce. A question already answered (the turn thread hasn't taken the
    # answer yet) or already closed stays as it is: the first responder wins.
    # @param id [String, nil] cancel only this question (a UI's dismiss
    #   names the one it showed)
    # @return [Boolean] whether it was cancelled (true with none pending and
    #   no id, as before)
    # @raise [NotDismissable] +id+ names a standing question (#post)
    def cancel(reason = "user", id: nil)
      cancelled_id = @lock.synchronize do
        pending = @pending
        next unless pending
        next if id && pending[:id].to_s != id.to_s
        next if @answer || pending[:status].to_s != "pending"
        # Its poster closes it; nothing waits on a cancel.
        raise NotDismissable, "answer #{Array(pending[:options]).join(' or ')}" if @standing && id
        next if @standing

        pending[:status] = "cancelled"
        @cv.broadcast
        pending[:id]
      end
      return id.nil? && self.pending.nil? unless cancelled_id

      emit({ type: :question_cancelled, id: cancelled_id, reason: reason.to_s }) rescue nil
      true
    end

    # A question through the question flow (REPL sync handler, attached TUI,
    # web), single-select, kind "hook". A --non-interactive run has no one
    # to ask: nil at once. Anything but an answer (a sync handler's text, no
    # answer, cancelled) is nil too.
    # @return [Hash, nil] {selected:, freeform:, selected_indices:}
    def ask_for_hook(question, options, header, allow_freeform, hook)
      return nil if @interface_lookup.call == :non_interactive

      opts = Tools::AskUserQuestion.normalize_options(options)
      unless opts
        Log.warn(:hooks, "ask_user_invalid", echo: "[samagotchi:hooks] #{hook} asked with invalid options (2-8 strings)", hook: hook.to_s)
        return nil
      end

      fields = { question: question.to_s, options: opts, header: header, multi_select: false,
                 allow_freeform: !!allow_freeform, kind: "hook", hook: hook.to_s }.compact
      answer = open_question(fields)
      return nil unless answer.is_a?(Hash) && answer[:selected]

      result = { selected: Array(answer[:selected]), freeform: answer[:freeform] }
      result[:selected_indices] = answer[:selected_indices] if answer.key?(:selected_indices)
      result
    end

    private

    # Make +fields+ the pending question: set under the lock, saved to the
    # session file (the web's stub, a resume, the lists) and announced as
    # :question_requested to every UI. Observers that stash the event (e.g.
    # TerminalUI handle_question_event) discard it as stale if a sync
    # handler answers and clears it first (drain_pending_question?).
    # @return [Hash] the pending question
    # @param standing [Hash, nil] a standing question's record (#post)
    def publish(fields, standing: nil)
      pending = { id: SecureRandom.uuid, **fields, status: "pending", created_at: Time.now.iso8601(3) }.compact
      @lock.synchronize do
        @pending = pending
        @answer = nil
        @standing = standing&.merge(id: pending[:id])
      end
      if session
        session.pending_question = pending.dup
        begin; session.save(state_dir: state_dir); rescue StandardError; nil; end
      end
      event = { type: :question_requested, pending_question: pending }
      event[:standing] = true if standing
      emit(event)
      pending
    end

    # A question is about to open: a standing one gives way (withdrawn,
    # reason "superseded") and is shelved until the new one closes.
    def supersede_standing
      standing = @lock.synchronize do
        next nil unless @standing

        @shelved = @standing
        @standing = nil
        @pending = nil
        @shelved[:id]
      end
      emit({ type: :question_cancelled, id: standing, reason: "superseded" }) if standing
    end

    # The question that superseded a standing one closed: offer it again.
    def offer_shelved
      shelved = @lock.synchronize do
        next nil if @pending || @shelved.nil?

        @shelved.tap { @shelved = nil }
      end
      return unless shelved

      if shelved[:on_superseded_close]
        shelved[:on_superseded_close].call
      else
        post(shelved[:fields], on_answer: shelved[:on_answer])
      end
    rescue StandardError => e
      Log.warn(:turn, "standing_question_repost_failed", error: e.class.name, message: e.message)
    end

    # A standing question's answer: cleared from the file, announced, then
    # handed to its poster with who answered.
    def settle_standing(standing, answer, client_id)
      clear_saved_question
      emit({ type: :question_answered, id: answer[:id], answer: answer })
      standing[:on_answer].call(answer, client_id: client_id)
    rescue StandardError => e
      Log.warn(:turn, "standing_answer_failed", error: e.class.name, message: e.message)
    end

    # An answer to +pending+, checked: the selections are its options (value
    # == label in v1), one for a single-select, one or a text when required,
    # and a parent agent's within guardrails.parent_approvals. Under the
    # question lock: checked against the question pending now.
    # @return [Hash] {id:, selected:, freeform:, selected_indices:, by:}
    # @raise [ArgumentError, Refused]
    def validated_answer(pending, sel, fm, parent_agent:, parent_setting:)
      opts = Array(pending[:options])
      invalid = sel.reject { |v| opts.include?(v) }
      raise ArgumentError, "invalid selection: #{invalid.join(', ')} (valid: #{opts.join(', ')})" unless invalid.empty?
      raise ArgumentError, "single-select question: got #{sel.size} selections" if !pending[:multi_select] && sel.size > 1
      raise ArgumentError, "selection required" if pending[:multi_select] == false && sel.empty? && fm.nil?

      indices = sel.map { |v| opts.index(v) }
      # The one whose answer settles the approval (Approval.settle, by index).
      if parent_setting
        reason = Guardrails::ParentApprovals.refusal(pending, indices, setting: parent_setting)
        raise Refused, reason if reason
      end
      answer = { id: pending[:id].to_s, selected: sel, freeform: fm, selected_indices: indices.compact }
      answer[:by] = "parent_agent" if parent_agent
      answer
    end

    # Wait until the question is answered, cancelled or closed by +watch+.
    # @return [String, nil] the watch's close reason
    def wait_for_answer(watch)
      next_watch = monotonic + WATCH_INTERVAL
      loop do
        done = @lock.synchronize do
          next true if @answer || cancel_controller&.cancelled?
          next true if @pending.nil? || @pending[:status] != "pending"

          # Wait with timeout to check cancel; 0.2s matches reminder poll
          @cv.wait([0.2, watch ? next_watch - monotonic : 0.2].min.clamp(0.0, 0.2))
          false
        end
        return nil if done
        next unless watch && monotonic >= next_watch

        next_watch = monotonic + WATCH_INTERVAL
        reason = run_watch(watch)
        next unless reason

        closed = @lock.synchronize do
          next false if @answer || @pending.nil? || @pending[:status] != "pending"

          @pending[:status] = "cancelled"
          true
        end
        return reason if closed
      end
    end

    # The watch's close reason; one that raises closes nothing.
    def run_watch(watch)
      reason = watch.call
      reason&.to_s
    rescue StandardError => e
      Log.warn(:turn, "question_watch_failed", error: e.class.name, message: e.message)
      nil
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def session = @session_lookup.call
    def state_dir = @state_dir_lookup.call
    def cancel_controller = @cancel_controller_lookup.call
    def emit(event) = @emit.call(event)

    # The session file no longer holds a pending question.
    def clear_saved_question
      return unless session

      session.pending_question = nil
      begin; session.save(state_dir: state_dir); rescue StandardError; nil; end
    end
  end
end
