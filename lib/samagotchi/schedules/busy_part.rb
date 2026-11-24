# frozen_string_literal: true

require_relative "../continue_offer"
require_relative "../log"
require_relative "../session"
require_relative "../session_inbox"
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

      private

      # Two paths (FR7): a live worker is asked through its Bridge; with no
      # worker the files say what the tick can know. A session being deleted
      # is a skip first, then one its owner stopped, in both modes: a schedule
      # restarts nothing the owner stopped (deliver_turn would refuse a same-mode
      # firing too, SessionManager::DeliverResult::STOPPED, in the same words).
      def busy_reason(entry, links, target)
        dir = Session.session_dir(target, state_dir: @state_dir)
        owner = SessionManager.session_owner(target, state_dir: @state_dir)
        presence = WorkerPresence.read(target, state_dir: @state_dir, owner: owner, link: :look)
        return [:skip, SessionManager::DeliverResult::DELETING["detail"]] if presence.deleting?
        return [:skip, SessionManager::DeliverResult::STOPPED["detail"]] if presence.stop_marked?

        link = presence.link

        if presence.worker_owned?
          # A newer worker's Bridge cannot be asked; updating chi or restarting
          # chi web fixes it, and max_skips still bounds a stuck schedule.
          return [:skip, link.short_message] if link.is_a?(WorkerLink::Skew)

          # A worker that has not published its Bridge yet (or is closing it):
          # nothing can be read from it, and firing now would race with it.
          return [:skip, "its worker is starting or leaving"] unless presence.live?

          activity = ask_activity(link, target)
          if activity == :old
            # Its chi predates GET /activity. The file checks cannot see an open
            # tab, so a chain firing would archive under someone's terminal:
            # refuse with a restart, never silently degrade. Same mode only
            # queues a turn, so for it the files are enough.
            return [:skip, "its worker is too old to ask: chi sessions restart #{target[0, 8]}"] if entry.mode == CHAIN

            return file_busy_reason(links.session(target), dir)
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
          return nil
        end
        # A worker being started for it holds no lock yet (another ticker's
        # firing just continued the chain to it, a resume): a chain firing
        # would archive it from under that worker (its archive refuses it too).
        # A queued turn is fine: the starting worker takes it.
        return [:skip, "its worker is starting or leaving"] if entry.mode == CHAIN && presence.starting?

        file_busy_reason(links.session(target), dir)
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
