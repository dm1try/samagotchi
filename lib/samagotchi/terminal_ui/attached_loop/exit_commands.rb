# frozen_string_literal: true

require_relative "../exit_lines"

module Samagotchi
  class TerminalUI
    class AttachedLoop
      # Exit and archive commands for the attached loop.
      # Reads @client, @client_id, @exit_ask, @link, @queued_ids, @running,
      # @screen, @view; writes @archive_after_turn and @exit_ask.
      # Calls the loop helpers #via and #detach.
      module ExitCommands
        private

        # @return [Symbol] :detach
        def detach(line)
          @view.finish_thinking_spinner
          @screen.commit(line)
          :detach
        end

        # Detach, and ask the worker to exit now. The worker decides: it stays
        # up while anything still needs it (a turn, queued input, a continue
        # offer, another UI, reminders), and the line says which. When the only
        # holds are ones the user can stop, it asks what to do with them instead
        # of detaching (#answer_exit_ask).
        # @return [Symbol, nil] :detach, or nil to stay at the prompt
        def exit_worker
          reply = @client.request_exit(client_id: @client_id)
          holds = reply.status == 409 ? reply.json&.fetch("holds", nil) : nil
          return detach(ExitLines.exit_line(reply, via: via, session_id: @client.session_id)) unless holds.is_a?(Array) && !holds.empty?

          @exit_ask = holds
          @screen.commit(ExitLines.ask_lines(holds))
          nil
        rescue SystemCallError, IOError => e
          detach(ExitLines.exit_failed_line(e.message, via: via, session_id: @client.session_id))
        end

        # The answer to the exit ask.
        # @return [Symbol, nil] :detach for 1 and 2, nil for 3 or a line the
        #   ask doesn't understand
        def answer_exit_ask(line)
          choice = ExitLines::EXIT_ANSWERS[line.to_s.strip.downcase]
          unless choice
            @screen.commit("Say 1 (keep running), 2 (stop them and exit) or 3 (back to the session).")
            return nil
          end

          holds = @exit_ask
          @exit_ask = nil
          case choice
          when :keep then detach(ExitLines.kept_line(holds, via: via, session_id: @client.session_id))
          when :stop then stop_and_exit
          else
            @screen.commit("(nothing stopped; the worker keeps running)")
            nil
          end
        end

        # 2: ask the worker to stop them all and exit.
        # @return [Symbol] :detach
        def stop_and_exit
          reply = @client.request_exit(client_id: @client_id, stop: true)
          detach(ExitLines.exit_line(reply, via: via, session_id: @client.session_id))
        rescue SystemCallError, IOError => e
          detach(ExitLines.exit_failed_line(e.message, via: via, session_id: @client.session_id))
        end

        # /exit --delete: the worker exits as for /exit, then the session is
        # deleted. When the worker stays up (another UI, queued input, ...),
        # nothing is deleted.
        def exit_and_delete
          reply = @client.request_exit(client_id: @client_id, delete: true)
          id = @client.session_id
          unless reply.status == 200
            line = ExitLines.exit_line(reply, via: via, session_id: id)
            return detach(line.sub("Detached; the session keeps running", "Detached; not deleted: the session keeps running")) if reply.status == 409

            return detach("#{line} Not deleted.")
          end
          # An empty session: the worker deletes it as it leaves.
          return detach(ExitLines::EMPTY_EXIT) if ExitLines.discards?(reply)

          @link.delete_session
          detach("Detached; deleted session #{id}.")
        rescue SystemCallError, IOError => e
          detach("#{ExitLines.exit_failed_line(e.message, via: via, session_id: id)} Not deleted.")
        rescue SessionManager::DeleteRefused, SessionManager::OwnedByTUI, ArgumentError => e
          detach("Detached; the worker is stopping, but session #{id} was not deleted (#{e.message}): " \
                 "#{via.command("sessions delete #{id}")}")
        end

        # /archive during a turn (D2): it waits for the turn's end and the
        # commands queued behind it (#archive_due?), then runs.
        # @return [nil]
        def archive_after_turn
          @archive_after_turn = true
          @screen.commit("(archives after this turn)")
          nil
        end

        def archive_due? = @archive_after_turn && !@running && @queued_ids.empty?

        # @return [Symbol] :detached
        def archive_now
          @archive_after_turn = false
          exit_and_archive
          :detached
        end

        # /archive: the worker is asked to exit as for /exit, then the session
        # is archived. A worker staying up for another UI (or reminders) is
        # stopped by the archive, as the web's archive stops it; a turn
        # running, a queued prompt or an open continue offer refuses it
        # (SessionManager.archive_session). An empty session: the worker
        # deletes it as it leaves.
        def exit_and_archive
          # /archive can't ask about what still runs: a child the archive will
          # stop is not worth a question here.
          reply = @client.request_exit(client_id: @client_id, ask: false)
          id = @client.session_id
          return detach(ExitLines::EMPTY_EXIT) if reply.status == 200 && ExitLines.discards?(reply)
          return detach("#{ExitLines.exit_line(reply, via: via, session_id: id)} Not archived.") unless [200, 409].include?(reply.status)

          result = @link.archive_session
          return detach("Detached; the session was empty, so it is discarded.") if result[:discarded].include?(id)

          detach("Detached; archived session #{id}. #{via.command("sessions list --archived")} finds it.")
        rescue SystemCallError, IOError => e
          detach("#{ExitLines.exit_failed_line(e.message, via: via, session_id: id)} Not archived.")
        rescue SessionManager::ArchiveRefused, SessionManager::OwnedByTUI, ArgumentError => e
          detach("Detached; session #{id} was not archived (#{e.message}). Re-attach with: #{via.attach(id)}")
        end
      end
    end
  end
end
