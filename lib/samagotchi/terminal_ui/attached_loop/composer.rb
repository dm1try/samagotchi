# frozen_string_literal: true

require_relative "../../composer_route"
require_relative "../../prompt_history"
require_relative "../../session_commands"
require_relative "../exit_lines"
require_relative "../reline_seam"

module Samagotchi
  class TerminalUI
    class AttachedLoop
      # Input composition and Ctrl-C handling for the attached loop.
      # Reads @client, @clock, @command_registry, @continue_offer, @exit_ask,
      # @gaps, @link, @prefilled, @question, @queue, @queued_ids, @reader,
      # @running, @screen; writes @prefilled, @last_idle_interrupt_at.
      # Calls the loop helpers #answer_continue, #answer_exit_ask, #answer_question,
      # #archive_after_turn, #command_registry, #detach, #echo_answer, #exit_and_archive,
      # #exit_and_delete, #exit_worker, #gap_divider, #participant_commands, #persist_recent_history,
      # #queue_input_prefill, #read_prompt_line, #send_command, #send_prompt,
      # #show_recap, #show_stats, #submit_delivery, #unqueue_newest, #via, and
      # #worker_down.
      module Composer
        private

        # A divider above a typed line's echo (RelineSeam.echo_above, on the
        # reader thread): a prompt typed after a quiet gap, at an idle prompt.
        # It marks the activity, so the turn's start marks no second one.
        def gap_above_echo(text)
          return nil if @running

          route = ComposerRoute.call(text.to_s.strip, running: false, registry: command_registry)
          return nil unless %i[prompt deliver].include?(route.kind)

          line = @gaps.divider
          line && gap_divider(line)
        end

        # @return [Symbol, nil] :detach to end the loop
        def submit(line)
          if @exit_ask
            # The exit ask is open: this line answers it. Ctrl-D and /detach
            # detach without stopping anything, the way its 1 does.
            return detach(ExitLines.kept_line(@exit_ask, via: via, session_id: @client.session_id)) if line.nil? ||
                                                                                                       command_registry.lookup_local(line.strip)&.id == :detach

            return answer_exit_ask(line)
          end

          return detach("Detached; the session keeps running. Re-attach with: #{via.attach(@client.session_id)}") if line.nil?

          text = line.strip
          if @question
            # /detach leaves the question open, as Ctrl-D does; any other
            # line (/exit too) is read as the answer.
            return submit(nil) if command_registry.lookup_local(text)&.id == :detach

            return answer_question(text)
          end

          text, kept = split_prefilled(text)
          submitted = submit_line(text)
          # The removed text the command was typed after, back in the input
          # (unless an /unqueue put its own there, or the loop ends). Set
          # before the read restarts with it: the read's echo reads it.
          if kept && submitted != :detach && @prefilled.nil?
            @prefilled = kept
            @prefilled = nil unless @reader&.prefill(kept)
          end
          submitted
        end

        # A line typed after an /unqueue's text (#unqueued) without clearing
        # it, the text untouched and then a command ("fix it/unqueue"): the
        # command alone, and the text to put back. Any other line as is.
        # @return [Array(String, String|nil)]
        def split_prefilled(text)
          kept = @prefilled
          @prefilled = nil
          rest = command_after(text, kept)
          rest ? [rest, kept] : [text, nil]
        end

        # The command typed after +kept+ (/unqueue's text) in +text+, or nil.
        # @return [String, nil]
        def command_after(text, kept)
          return nil unless kept && text.length > kept.length && text.start_with?(kept)

          rest = text[kept.length..].strip
          route = ComposerRoute.call(rest, running: @running, registry: command_registry)
          rest if route.choice || %i[local command usage].include?(route.kind)
        end

        # The read's echo (RelineSeam.echo_as, on the reader thread): the
        # command alone when one is typed after /unqueue's text, as
        # #split_prefilled runs it; nil echoes the line as typed.
        def prefilled_echo(typed) = command_after(typed.strip, @prefilled)

        # @return [Symbol, nil] :detach to end the loop
        def submit_line(text)
          # /cut TEXT and /queue TEXT are this UI's own deliveries, read before
          # every command check (ComposerRoute; SessionCommands registers them
          # for Tab and /help only). A plain line sends no delivery: it goes in
          # at the running turn's next step, and never cuts.
          route = ComposerRoute.call(text, running: @running, registry: command_registry)
          return submit_delivery(route) if route.choice

          # The terminal's own commands (SessionCommands registers them, the
          # REPL reads the same words). Before the continue offer: the
          # leaving ones are no answer to it.
          local = route.local
          return submit(nil) if local == :detach
          return SessionCommands.delete_on_exit?(text) ? exit_and_delete : exit_worker if local == :exit
          return archive_after_turn if local == :archive && (@running || !@queued_ids.empty?)
          return exit_and_archive if local == :archive

          if @continue_offer
            return answer_continue(text) unless local || route.kind == :command

            # Not an answer: the read left no echo, so show what ran.
            echo_answer(text)
          end
          return if route.kind == :empty

          if local == :stats
            show_stats
          elsif local == :recap
            show_recap
          elsif local == :unqueue
            unqueue_newest
          elsif %i[share participants].include?(local)
            @screen.commit(participant_commands.run(text))
          elsif route.kind == :command
            # The history keeps !cmds, as the REPL's does (prompts: #send_prompt).
            persist_recent_history(text) if PromptHistory.shell_line?(text)
            send_command(text)
          elsif route.kind == :typo
            # A typo of a command (/modle) is not a prompt: say so, send nothing.
            @screen.commit(route.reply)
          else
            send_prompt(text)
          end
          nil
        end

        # One read on the reader thread: the REPL's multiline read with Tab
        # completion at the main prompt, a plain line for a question's choice
        # or the continue offer's answer.
        def read_input_line(prompt, prefill)
          return $stdin.gets&.chomp unless $stdin.tty?
          # A question's answer leaves only its summary line.
          return RelineSeam.without_echo { Reline.readline(prompt, true) } if @question || @continue_offer

          queue_input_prefill(prefill) if prefill
          read_prompt_line(prompt)
        end

        # The attached TUI's commands, for Tab.
        def slash_commands = command_registry.completions(:attached)

        # @path and #memory candidates, as the link offers them
        # (AttachLink#completions).
        def build_project_path_completion_candidates(path_fragment)
          @link.completions.paths ? super : []
        end

        def build_memory_completion_candidates(memory_fragment)
          @link.completions.memories ? super : []
        end

        # The session's commands as its worker's snapshot names them (its
        # plugins' too); the built-ins until one arrives, or from a worker too
        # old to name them. An unknown /foo is a prompt, as in the REPL.
        def command_registry = @command_registry || SessionCommands.builtin_registry

        # Ctrl-C cancels the running turn (whoever started it). At an idle
        # prompt it clears the line; on an empty one it says how to detach, and
        # a second press within DETACH_WINDOW detaches (D4).
        # @param pressed [Hash, nil] {text:, at:} from the read the press ended
        #   (nil: pressed with no read open)
        # @return [Symbol, nil] :detach
        def interrupt(pressed = nil)
          typed = pressed&.fetch(:text, nil).to_s
          if @running
            begin
              @client.cancel(reason: "ctrl_c")
            rescue SystemCallError, IOError => e
              @screen.commit("could not cancel the turn (#{worker_down(e)})")
            end
            return nil
          end
          unless typed.strip.empty?
            @last_idle_interrupt_at = nil
            return nil
          end

          now = pressed&.fetch(:at, nil) || @clock.call
          return submit(nil) if @last_idle_interrupt_at && now - @last_idle_interrupt_at <= DETACH_WINDOW

          @last_idle_interrupt_at = now
          @screen.commit(DETACH_HINT)
          nil
        end

        # On the reader thread, from Reline's Ctrl-C: what the line held, and
        # when. During a turn the press goes to the loop (it cancels the turn)
        # and the read goes on with the typed text still in it, as in the REPL;
        # otherwise it is noted for the Interrupt the LineReader queues next.
        # @return [Boolean] true: handled, the read goes on; false: Reline ends
        #   the read with Interrupt
        def note_interrupted_line
          pressed = { text: Reline.line_buffer.to_s, at: @clock.call }
          if @running
            @queue << [:interrupt, pressed]
            return true
          end

          Thread.current[:interrupted_line] = pressed
          false
        rescue StandardError
          false
        end
      end
    end
  end
end
