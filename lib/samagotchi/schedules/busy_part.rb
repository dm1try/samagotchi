# frozen_string_literal: true

require_relative "../continue_offer"
require_relative "../log"
require_relative "../session"
require_relative "../session_inbox"
require_relative "../session_lifecycle"
require_relative "../session_manager"
require_relative "../session_row"
require_relative "../worker_link"
require_relative "../worker_presence"

module Samagotchi
  class Schedules
    # The busy check (docs/scheduling.md, "The busy check"): whether a
    # schedule may act on its target now, or the skip and its words.
    module BusyPart
      # Seconds a tick waits for a live worker's GET /activity.
      ACTIVITY_TIMEOUT = 2.0
      # The skip words of each busy cell (SessionLifecycle::ALLOWED's
      # sched_chain / sched_same) but :go and :worker_newer (WorkerLink::Skew's
      # own words, #busy_words). spec/schedules_spec.rb checks every cell the
      # table holds has words; one it misses still skips (#busy_words), so a
      # table edit never aborts a tick.
      BUSY_WORDS = {
        deleting: SessionManager::DeliverResult::DELETING["detail"],
        stopped: SessionManager::DeliverResult::STOPPED["detail"],
        worker_busy: "its worker is starting or leaving"
      }.freeze

      private

      # Two paths (FR7). The state's answer comes from the lifecycle table
      # (#busy_cell: SessionLifecycle::ALLOWED, plus two op-local overrides);
      # then a live worker is asked through its Bridge (#live_busy_reason)
      # and with no worker the files say what the tick can know
      # (#file_busy_reason). A session being deleted is a skip first, then
      # one its owner stopped, in both modes: a schedule restarts nothing the
      # owner stopped (deliver_turn would refuse a same-mode firing too,
      # SessionManager::DeliverResult::STOPPED, in the same words).
      def busy_reason(entry, links, target)
        dir = Session.session_dir(target, state_dir: @state_dir)
        owner = SessionManager.session_owner(target, state_dir: @state_dir)
        presence = WorkerPresence.read(target, state_dir: @state_dir, owner: owner, link: :look)
        # exists: true: #target_of resolved the target already, and a delete
        # mid-way (its JSON gone, the deleting lock held) must read deleting,
        # not absent. No extra read: SessionLifecycle.read would add a
        # ContinueIntent read this check doesn't use.
        state = SessionLifecycle::Reading.derive(presence.with(exists: true)).state
        cell = busy_cell(entry, presence, state)
        return [:skip, busy_words(cell, presence.link)] unless cell == :go
        return live_busy_reason(entry, links, target, presence.link) if state == :live

        file_busy_reason(links.session(target), dir)
      end

      # The table's cell for this mode in +state+, then the two facts the
      # state doesn't hold, read in today's order (spec/session_lifecycle/
      # matrix_spec.rb's KNOWN_DIFFERENCES name both):
      # - the stop marker before the owner (F1, chain and same; an unknown
      #   owner's stop too): stopped under any lock but a deleter's;
      # - F1b: chain mode's starting check with no one-turn-run check: a
      #   fresh starting marker without a worker's lock is worker_busy (a
      #   worker being started for it holds no lock yet: a chain firing would
      #   archive it from under that worker; a queued turn is fine).
      def busy_cell(entry, presence, state)
        chain = entry.mode == CHAIN
        cell = SessionLifecycle.allowed(chain ? :sched_chain : :sched_same, state)
        return :stopped if presence.stop_marked? && cell != :deleting
        return :worker_busy if chain && cell == :go && presence.starting? && !presence.worker_owned?

        cell
      end

      # A newer worker's Bridge cannot be asked (:worker_newer); updating chi
      # or restarting chi web fixes it, and max_skips still bounds a stuck
      # schedule. A worker that has not published its Bridge yet, or is
      # closing it (:worker_busy): nothing can be read from it, and firing
      # now would race with it.
      def busy_words(cell, link)
        return link.short_message if cell == :worker_newer

        BUSY_WORDS.fetch(cell) { "it is not free now (#{cell})" }
      end

      # A live worker, asked through its Bridge.
      def live_busy_reason(entry, links, target, link)
        activity = ask_activity(link, target)
        if activity == :old
          # Its chi predates GET /activity. The file checks cannot see an open
          # tab, so a chain firing would archive under someone's terminal:
          # refuse with a restart, never silently degrade. Same mode only
          # queues a turn, so for it the files are enough.
          return [:skip, "its worker is too old to ask: chi sessions restart #{target[0, 8]}"] if entry.mode == CHAIN

          return file_busy_reason(links.session(target), Session.session_dir(target, state_dir: @state_dir))
        end
        return [:skip, "its worker is not answering"] if activity.nil?

        return [:skip, "a turn is running in it"] if activity[:turn_running]
        return [:skip, "a prompt is queued for it"] if activity[:input_pending]
        return [:skip, "its step-limit question waits for an answer"] if activity[:awaiting_continue]

        # A chain firing archives the session and stops its worker: a
        # terminal or a web tab on it would be cut off. A queued turn into
        # an open session is fine, so same mode does not count streams.
        return [:skip, "a terminal or a web tab is open on it"] if entry.mode == CHAIN && activity[:open_streams].to_i.positive?

        # An idle live worker: free, whatever a starting marker its own
        # start left (Worker#start clears it just after the lock).
        nil
      end

      # The worker's activity snapshot, :old when it has no /activity route, or
      # nil when it did not answer at all. A worker published its features when
      # it started, so a sidecar without "activity" is an older chi's: asking it
      # would only cost a round trip to a 404.
      def ask_activity(link, session_id)
        return :old unless Array(link.features).include?(WorkerLink::ACTIVITY_FEATURE)

        status, body = link.client(session_id, read_timeout: ACTIVITY_TIMEOUT).get("activity")
        return nil if status.nil?
        return body.transform_keys(&:to_sym) if status == 200 && body.is_a?(Hash)

        :old
      rescue StandardError => e
        Log.warn(:worker, "activity_failed", sid: session_id, error: e.class.name, msg: e.message)
        nil
      end

      # The signals RemovalPart#archive_refusal reads, from the files alone.
      def file_busy_reason(session, dir)
        return nil if session.nil?

        if SessionRow.running_or_starting?(saved_status: session.status, live: false, busy: false, updated_at: session.updated_at)
          return [:skip, "a turn is running in it"]
        end
        return [:skip, "a prompt is queued for it"] unless SessionInbox.find_new_input_files(dir).empty?

        return [:skip, "its step-limit question waits for an answer"] if session.waiting_question(live: false)&.dig(:kind) == ContinueOffer::KIND

        nil
      end
    end
  end
end
