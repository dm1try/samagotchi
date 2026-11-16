# frozen_string_literal: true

require_relative "../children_status"
require_relative "../log"
require_relative "../reminder_carry"
require_relative "../session_manager"
require_relative "../worker_idle_exit"

module Samagotchi
  class Worker
    # Exit and leave: the exit claim's requests (#exit_request, #exit_hold),
    # the leaves (#leave_on_request, #leave_idle) and what they hand on (the
    # carried reminders, the recap, the discard). Writes @marked_leaving
    # (#mark_leaving) and @discard (#left), and the exit claim through its own
    # methods; reads @exit_claim, @idle_exit, @hold_stop, @session, @session_id,
    # @session_dir, @state_dir, @default_model, @engine, @bridge, @owner_lock,
    # @waker and @task_wakes.
    module LeavePart
      # /exit held by background tasks a finish wake waits for: how to end them.
      TASK_STOP_HINT = "stop one with the web's stop-task button or by asking for task_stop"

      # @return [HoldStop::Stopped, nil] the last stop-all's list (the Bridge's
      #   exit_stopped)
      def stopped_holds = @exit_claim.stopped

      private

      # Bridge POST /exit, on a Bridge thread with the event log held.
      # +delete+: the session is deleted after (/exit --delete), so no recap.
      # +restart+: a new worker takes over (on the newest chi installed), so
      # WorkerIdleExit#hold_for_restart's rules, and no recap or discard.
      # +stop+: the exit ask's "stop them and exit" — stop every hold the user
      #   can stop before leaving; a hold they can't stop refuses the request
      #   (WorkerIdleExit#request_hold checks again, so one that appeared
      #   since the ask is refused too).
      # +ask+: this client asks the user what to do with what still runs, so the
      #   delegate children are part of the list. An exit that deletes the
      #   session, or one a UI can't ask about (/archive), leaves them out:
      #   they never hold the worker up on their own.
      # @return [WorkerIdleExit::Hold, nil] what keeps the worker up (for
      #   :background_tasks, the watched tasks still running), nil when it
      #   will leave
      def exit_request(client_id, delete: false, restart: false, stop: false, ask: true)
        # The Bridge serves before the idle-exit policy exists.
        return WorkerIdleExit::Hold.new(reason: :starting) unless @idle_exit

        kind = if restart then :restart
               elsif delete then :delete
               else :exit
               end
        # One exit at a time, and the first one taken decides how the worker
        # leaves (a later stop-all can't turn a restart, whose reminders go to
        # the next worker, into a plain exit): claimed before the slow
        # stop-all, so a request of another kind meanwhile is refused (409),
        # not told it went through. Held at the leave, it is forgotten and the
        # next request counts again.
        refused = @exit_claim.claim(kind)
        return refused.value if refused

        hold = exit_hold(client_id, kind: kind, stop: stop, ask: ask)
        if hold
          @exit_claim.forget
          return hold
        end

        @exit_claim.accept(by: client_id, stop: stop)
        @waker.wake
        nil
      rescue StandardError
        # A look or a stop that raised lets the claim go (the Bridge answers 500).
        @exit_claim.release
        raise
      end

      # What keeps the worker up for this request, nil when nothing does; a
      # stop request stops what the user can stop first (#exit_request).
      # @return [WorkerIdleExit::Hold, nil]
      def exit_hold(client_id, kind:, stop:, ask:)
        if kind == :restart
          # A scratch session's worker ends with its terminal: never restarted.
          return WorkerIdleExit::Hold.new(reason: :scratch) if @session.scratch

          hold = @idle_exit.hold_for_restart
          return hold && WorkerIdleExit::Hold.new(reason: hold)
        end

        # /exit names the tasks it waits for (D3), from the one look that found them.
        # The ask covers the delegate children too, but only for a plain /exit: an
        # exit that deletes the session, or one a UI won't ask about, ignores them.
        hold = @idle_exit.request_hold(requester: client_id, hint: TASK_STOP_HINT, ask: ask && kind != :delete)
        return nil unless hold
        # A hold the user can't stop here: no ask, today's refusal.
        return hold unless hold.ask?
        # The ask's 409: the list, for the terminal to ask with.
        return hold unless stop

        @exit_claim.stopped!(@hold_stop.stop_all)
        # An unstoppable hold may have arrived while stopping (a child stopped
        # here is no longer counted).
        @idle_exit.request_hold(requester: client_id, hint: TASK_STOP_HINT)
      end

      # #leave_idle for an exit a client asked for: check again with the event
      # log held (a prompt may have come in since), then close the Bridge's
      # intake and stop the idle jobs (the Bridge stops after the log). Other clients' streams no longer hold: the asker's
      # may not have closed yet, and a UI joining now finds the worker gone
      # (:stream_closed), the window #leave_idle has too.
      # @return [Symbol, false] how it leaves (:restart or :exit_requested,
      #   decided under the lock), false when something came in since the request
      def leave_on_request
        stop_bridge_after do
          @engine.synchronize_events do
            # One read: the kind and the asker of the same exit.
            taken = @exit_claim.taken
            restart = taken&.restart?
            hold = if restart
                     @idle_exit.hold_for_restart
                   else
                     @idle_exit.hold_for_request(requester: taken&.by, streams: false)
                   end
            if hold
              @exit_claim.forget
              Log.info(:worker, "exit_held", reason: hold)
              next false
            end
            next false if restart && !carry_reminders

            @bridge&.close_intake
            # Not joined: a recap tick's emit waits for the event log held here.
            @engine.stop_idle(join: false)
            Log.info(:worker, restart ? "restart_requested" : "exit_requested", by: taken&.by || "a client")
            restart ? :restart : :exit_requested
          end
        end
      end

      # Check again with the event log held, which the Bridge holds while it
      # queues a POST /turn, then close the Bridge's intake so no client can
      # queue one after the check, and stop the idle jobs (reminder callback,
      # recap). The Bridge stops after the log is let go (#stop_bridge_after).
      # A client connecting from here on finds no worker: `chi --attach` fails
      # and the web stream answers 503 (a small window, left as is).
      # @return [Boolean] false when something came in since #due?
      def leave_idle
        stop_bridge_after do
          @engine.synchronize_events do
            next false unless @idle_exit.due?

            @bridge&.close_intake
            # Not joined: a recap tick's emit waits for the event log held here.
            @engine.stop_idle(join: false)
            log_idle_exit
            true
          end
        end
      end

      def log_idle_exit
        Log.info(:worker, "idle_exit", idle_s: @idle_exit.idle_seconds.round)
      end

      # The Bridge stops once the block (which closed its intake with the
      # event log held) answers true, outside the log: Bridge#stop waits for
      # the requests it is answering, and one waiting on the log would hold
      # it for the whole grace before being killed. The owner lock says it is
      # leaving first, so a client that finds no Bridge from here on waits
      # for the lock (OwnerLock.await_release) instead of giving up.
      # @return [Boolean] what the block answered
      def stop_bridge_after
        leaving = yield
        if leaving
          mark_leaving
          @bridge&.stop
        end
        leaving
      end

      # How long the lock stays held after the Bridge: the recap on leave's
      # timeout (#left), none for a restart (#left writes none). A delete
      # writes none either, but the bound only has to be an upper one.
      # Once: the teardown's (after #stop_bridge_after's) keeps the first one.
      # @param wait [Numeric, nil] nil: as above
      def mark_leaving(wait: nil)
        return if @marked_leaving

        @marked_leaving = true
        wait ||= @exit_claim.restart? ? 0 : @engine.recap_timeout.to_f
        @owner_lock&.mark_leaving(wait: wait)
      rescue StandardError => e
        Log.warn(:worker, "mark_leaving_failed", error: e.class.name, msg: e.message)
      end

      # A restart hands the reminders to the next worker (ReminderCarry), while
      # the event log is held: no turn can register or fire one from here. A
      # write that fails keeps this worker up with them rather than losing them.
      # A session stopped meanwhile drops them (WorkerBoot.run_session_loop
      # then starts no successor): nothing is written.
      # @return [Boolean] false when the write failed
      def carry_reminders
        if stopped_on_disk?
          ReminderCarry.remove(@session_dir)
        else
          ReminderCarry.write(@session_dir, session_id: @session_id, store: @engine.reminder_store)
        end
        true
      rescue StandardError => e
        @exit_claim.forget
        Log.warn(:worker, "reminders_carry_failed", error: e.class.name, msg: e.message)
        false
      end

      # The reminders a restart handed over (#carry_reminders), read and
      # deleted; a stopped session drops them.
      # @return [Array<Hash>, nil] ReminderStore#export's entries
      def take_carried_reminders
        ReminderCarry.take(@session_dir, session_id: @session_id, stopped: stopped_on_disk?)
      rescue StandardError => e
        Log.warn(:worker, "reminders_carry_take_failed", error: e.class.name, msg: e.message)
        nil
      end

      # Into the new Engine's store, before the idle scheduler starts polling it.
      def restore_carried_reminders(entries)
        return unless entries

        names = @engine.reminder_store.restore(entries)
        Log.info(:worker, "reminders_carried", count: names.size)
      rescue StandardError => e
        Log.warn(:worker, "reminders_carry_restore_failed", error: e.class.name, msg: e.message)
      end

      # @return [Symbol] +result+, with #discard? decided and, for a session
      #   kept, its recap written: the Bridge is closed and the idle jobs are
      #   stopped by now, and nothing waits on this (the TUI has detached). A
      #   `chi send` meanwhile is picked up after the exit (WorkerBoot.run_session_loop);
      #   a `chi --attach` finds no Bridge until then.
      # A restart keeps even an empty session (a new worker takes it over at
      # once) and leaves the recap to the conversation's next real pause.
      def left(result)
        deleting = (result == :exit_requested && @exit_claim.deletes?) || result == :scratch_left
        # The attached context goes with this process: a change that landed after
        # the leaving pass looked at it has no later pass to note it, so note it
        # here (no wake turn: the worker is on its way out). Not into a session
        # /exit --delete deletes next: its save could land after the delete and
        # write the session back.
        absorb_context unless deleting
        # The watch goes with this process: a task that finished since the
        # last look (nothing held the exit for it: queue, a note-only task,
        # /exit) is a plain note for the next turn, not lost. Not into a
        # session /exit --delete deletes next: its save could land after the
        # delete and write the session back.
        @task_wakes.absorb unless deleting
        return result if %i[restart scratch_left].include?(result)

        @discard = empty_session?
        write_recap_on_leave unless @discard || deleting
        result
      end

      def write_recap_on_leave
        written = @engine.write_recap_now
        Log.info(:worker, "recap_on_leave") if written
      rescue StandardError => e
        Log.warn(:worker, "recap_on_leave_failed", error: e.class.name, msg: e.message)
      end

      # Memory used before any turn saved it lives only in the Engine.
      def empty_session?
        SessionManager.discardable?(@session_id, state_dir: @state_dir, default_model: @default_model,
                                                 used_memory_names: @engine.used_memory_names)
      end

      # The delegate children of this session that are running a turn or have
      # a live worker. ChildrenStatus.of scans the session files; this runs on
      # an exit request, not every pass.
      # @return [Array<ChildrenStatus::Child>]
      def live_delegates
        ChildrenStatus.of(@session_id, state_dir: @state_dir)
                        .select { |child| child.delegate && (child.state == "running" || child.live) }
      rescue StandardError => e
        Log.warn(:worker, "delegate_look_failed", error: e.class.name, msg: e.message)
        []
      end
    end
  end
end
