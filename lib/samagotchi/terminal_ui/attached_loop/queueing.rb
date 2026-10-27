# frozen_string_literal: true

require_relative "../../delivery"

module Samagotchi
  class TerminalUI
    class AttachedLoop
      # Queue and unqueue handling for the attached loop.
      # Reads @client, @client_id, @first_command_id, @link, @my_queued,
      # @open_ids, @reader, @screen, @shown_enqueued, @wait_at_eof; writes
      # @my_queued, @open_ids, @own_empty, @own_failed, @prefilled, @queued_ids,
      # @shown_enqueued.
      # Calls the loop helpers #author_of, #first_command_flag, #mark_activity,
      # #own?, #prompt_line, #send_prompt, #via, and #worker_down.
      module Queueing
        private

        QUEUED_NOTE = "(queued: runs after this turn)"
        QUEUE_RUNS_NOW = "(the turn had ended: runs as the next turn)"
        NOTHING_QUEUED = "(nothing queued: /queue TEXT queues a message for after the running turn)"
        UNQUEUE_REFUSED = { "already_started" => "(not removed: it already started)",
                            "unknown_enqueued_id" => "(not removed: it is already gone)",
                            "not_queued" => "(not removed: it goes in at the next step)" }.freeze

        # /cut TEXT and /queue TEXT (+route+ has a choice). During a turn the
        # text goes with its delivery: a cut, or queued to run as a turn of
        # its own after this one. A worker that doesn't queue (its sidecar
        # names no "delivery" feature) would steer a queue, so it is not sent.
        # At the prompt both send the text as typed, a normal turn: no local
        # word or typo check (the worker's Bridge runs a session command as
        # the command).
        # @param route [ComposerRoute::Route]
        # @return [nil]
        def submit_delivery(route)
          return @screen.commit(Formatting::STEER_CHOICE_USAGE) if route.kind == :usage
          return @screen.commit(queue_needs_newer_worker) if Delivery.queue?(route.delivery) && !worker_queues?

          # To an idle session it is an ordinary prompt: no delivery to send,
          # and its ack says it was sent now (#sent_note).
          send_prompt(route.text, delivery: route.delivery, choice: route.choice)
          nil
        end

        # Whether the attached worker runs delivery: queue (its sidecar names
        # Delivery::QUEUE_FEATURE). No sidecar to read: true, its Bridge
        # answers (a P0-P2 worker refuses a queue: #send_prompt).
        def worker_queues? = @link.queues?

        # /queue to a worker from before queueing, which would steer it.
        def queue_needs_newer_worker
          "(/queue needs a newer worker: restart it with #{via.command("sessions restart")}, then send again)"
        end

        def unqueue_needs_newer_worker = "(/unqueue needs a newer worker: restart it with #{via.command("sessions restart")})"

        # /unqueue: take back the newest prompt this run queued for after the
        # turn, before it runs (POST turn/dequeue). Its :turn_dequeued comes
        # to every UI; here the reply says what became of it. A worker whose
        # sidecar lacks "unqueue" is not asked.
        def unqueue_newest
          return @screen.commit(unqueue_needs_newer_worker) unless worker_unqueues?

          id = @my_queued.last
          return @screen.commit(NOTHING_QUEUED) unless id

          reply = @client.dequeue(enqueued_id: id, client_id: @client_id)
          error = reply.json&.fetch("error", nil)
          return @screen.commit(unqueue_needs_newer_worker) if reply.status == 404 && error == "not_found"

          # Removed, started or gone: no longer this run's to take back.
          @my_queued.delete(id) if [200, 404, 409].include?(reply.status)
          return unqueued(reply.json&.fetch("prompt", nil).to_s) if reply.status == 200

          @screen.commit(UNQUEUE_REFUSED[error] || "could not remove the queued message (#{[reply.status, error].compact.join(" ")})")
        rescue SystemCallError, IOError => e
          @screen.commit("could not remove the queued message (#{worker_down(e)})")
        end

        # The removal's line, and its text back in the input to change and
        # send again (as a failed turn's prompt comes back, #restore_prompt):
        # not over typed text, and not for lines from a pipe. Its images are
        # not put back.
        def unqueued(prompt)
          @screen.commit("removed: #{first_line_clip(prompt)}")
          return if @wait_at_eof || prompt.strip.empty?

          # Set before the read restarts with it: the read's echo reads it.
          @prefilled = prompt.strip
          return if @reader&.prefill(prompt)

          @prefilled = nil
          @screen.commit("(the removed message is in the input history: ↑)")
        end

        def first_line_clip(text, max = 60)
          line = text.to_s.strip.lines.first.to_s.strip
          line.length > max ? "#{line[0, max]}…" : line
        end

        # Whether the attached worker takes queued messages back (its sidecar
        # names SessionInbox::UNQUEUE_FEATURE). No sidecar to read: true, its Bridge
        # answers (an older one's 404 not_found says so).
        def worker_unqueues? = @link.unqueues?

        # A command queued for after the running turn (command_queued with
        # waits): its line now (another client's) and a note; its command_ran
        # has no line again (queued: true).
        def command_waits(event)
          @queued_ids << event[:command_id]
          if own?(event[:client_id])
            first = event[:command_id] == @first_command_id
            return @screen.commit(first ? first_command_queued : QUEUED_NOTE)
          end

          @screen.commit("#{prompt_line(event[:client_id], event[:line])} #{QUEUED_NOTE}")
        end

        def first_command_queued
          "(#{first_command_flag} queued: applies after the running turn)"
        end

        def show_enqueued(event)
          return if own?(event[:client_id])

          # Another client's prompt shows here, before its turn starts.
          mark_activity
          @shown_enqueued << event[:enqueued_id]
          line = prompt_line(event[:client_id], event[:prompt], **author_of(event[:author]))
          @screen.commit(event[:delivery] == Delivery::QUEUE ? "#{line} #{QUEUED_NOTE}" : line)
        end

        # A queued prompt was taken back before it ran (the web's ×, /unqueue
        # in a terminal). One of this run's (wait_at_eof) will have no turn:
        # it ends the wait, as a failed one does. Another client's shown
        # line says so.
        def turn_dequeued(event)
          id = event[:enqueued_id]
          @my_queued.delete(id)
          if @open_ids.delete?(id)
            if own?(event[:client_id])
              @own_empty = true
              @screen.commit("(removed before it ran)")
            else
              @own_failed = true
              @screen.commit("(your queued message was removed before it ran)")
            end
          elsif @shown_enqueued.delete?(id)
            @screen.commit("(a queued message was removed)")
          end
        end
      end
    end
  end
end
