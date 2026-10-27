# frozen_string_literal: true

require_relative "../../client_id"
require_relative "../../delivery"
require_relative "../../prompt_history"
require_relative "../../turn_origin"
require_relative "../exit_lines"
require_relative "../image_input"

module Samagotchi
  class TerminalUI
    class AttachedLoop
      # Bridge sending, first-command launch, and this run's turn ledger.
      # Reads @as_parent, @client, @client_id, @display_pending, @first_command_id,
      # @first_command_line, @first_commands, @first_prompt, @input_ended, @link,
      # @merged_ids, @my_queued, @no_interrupt, @open_ids, @own_empty, @own_failed,
      # @queued_ids, @reader, @running, @screen, @sent_ids, @status, @wait_at_eof;
      # writes @display_pending, @first_command_id, @first_command_line,
      # @first_commands, @first_prompt, @merged_ids, @my_queued, @open_ids,
      # @own_empty, @own_failed, @queued_ids, @sent_ids.
      # Calls the loop helpers #client_id_for, #command_registry, #default_model_name,
      # #detach, #mark_activity, #older_worker_command, #origin_of, #own?, #paint,
      # #persist_recent_history, #prompt_line, #put_back_busy_command, #prefill_confirm,
      # #queue_needs_newer_worker, #send_command, #send_prompt, #stale_worker,
      # #steer_cut_note, #too_late?, #via, and #worker_down.
      module Sending
        private

        # The worker runs it and every UI renders its :command_ran, this one
        # too, so nothing waits here.
        def send_command(line)
          reply = @client.post_command(line: line, client_id: client_id_for(line))
          if reply.status == 202
            # Input from a pipe ends once its output is in (#command_ran).
            command_id = reply.json&.fetch("command_id", nil)
            @open_ids << command_id if command_id && @wait_at_eof
            return
          end
          return @screen.commit(stale_worker("run commands")) if reply.status == 404

          name = older_worker_command(reply, line)
          return @screen.commit(stale_worker("run #{name}")) if name
          return @screen.commit("could not run the command (#{ExitLines::LATE})") if too_late?(reply)

          detail = reply.json&.fetch("detail", nil) || reply.json&.fetch("error", nil)
          @screen.commit("could not run the command (#{[reply.status, detail].compact.join(" ")})")
        rescue SystemCallError, IOError => e
          @screen.commit("could not run the command (#{worker_down(e)})")
        end

        def command_ran(event)
          @open_ids.delete(event[:command_id])
          @queued_ids.delete(event[:command_id])
          unless own?(event[:client_id]) || event[:anytime] || event[:card] || event[:queued]
            @screen.commit(prompt_line(event[:client_id], event[:line]))
          end
          output = event[:output].to_s
          if output.empty?
            nil
          elsif %w[busy dropped].include?(event[:status]) || PromptHistory.shell_line?(event[:line])
            @screen.commit(output)
            put_back_busy_command(event) if event[:status] == "busy"
          else
            @screen.commit("#{paint("model>", 36)} #{output}")
          end
          prefill_confirm(event)
          # /title from any client: the row's title follows.
          @status.update(title: event[:title]) if Array(event[:changed]).include?("title")
          return unless event[:model_name]

          # After the output, so the status row changes with the line saying why.
          served = @status[:model] == event[:model_name] ? @status[:served] : nil
          @status.update(model: event[:model_name], default_model: default_model_name, served: served)
        end

        # Our change that asks first (CacheConfirm) puts its --yes line in the
        # input: Enter applies it. Another client's question is its own.
        def prefill_confirm(event)
          return unless own?(event[:client_id])

          confirm = event[:confirm]
          line = confirm.is_a?(Hash) ? confirm[:line] || confirm["line"] : nil
          @reader&.prefill(line.to_s) if line
        end

        # Our command the worker couldn't run yet goes back into the prompt, for
        # Enter once the turn ends (not the launch's --model: that ends the launch).
        def put_back_busy_command(event)
          return unless own?(event[:client_id]) && event[:command_id] != @first_command_id

          @screen.commit("(the command is in the input history: ↑)") unless @reader&.prefill(event[:line].to_s)
        end

        # What a prompt's 202 says became of it, or nil when there is nothing
        # to say: the dim line both TUIs print for a delivery. A plain line
        # for a running turn goes in at its next step; a cut's outcome comes
        # from the ack (the worker knows whether cutting is on for its model);
        # a queued one waits for the turn's end (the ack says queue).
        # An idle session's prompt simply runs, and a prompt with images runs
        # as its own next turn (never merging mid-turn), so nothing is said;
        # one typed as /cut or /queue says it was sent now (+choice+).
        # @param ack [Hash, nil] the Bridge's 202 body
        # @param delivery [String, nil] what was asked for
        # @return [String, nil]
        def sent_note(ack, delivery: nil, images: [], running: false, choice: nil)
          return Formatting::STEER_CHOICE_IDLE if choice && !running
          return nil unless running && ack.is_a?(Hash)
          # The Bridge acks queue only while a turn ran at enqueue; a /queue
          # it acks next_step found the turn over: it is the next turn.
          return Queueing::QUEUED_NOTE if ack["delivery"] == Delivery::QUEUE
          return Queueing::QUEUE_RUNS_NOW if Delivery.queue?(delivery)
          return nil unless images.empty?

          return Formatting::NEXT_STEP_NOTE unless delivery == Delivery::CUT

          steer_cut_note(ack["cut"].to_s.to_sym, ack["cut_after"])
        end

        # The client id +line+ goes with, as a command (#send_command) or as a
        # message the Bridge may run as one (#send_prompt: /cut and /queue
        # text). A parent agent's /continue yes and /parent-answers go as chi
        # answer's: the worker holds the first to guardrails.parent_answers and
        # never takes the second as a user's loosening. The command is the
        # registry's own match (the worker's), not a pattern of ours.
        def client_id_for(line)
          return @client_id unless @as_parent
          return ClientId::CLI_ANSWER if TurnFlow.continue_yes?(line)
          return ClientId::CLI_ANSWER if command_registry.lookup(line)&.id == :parent_answers

          @client_id
        end

        # @param choice [Symbol, nil] :cut or :queue when typed with that word
        def send_prompt(text, delivery: nil, choice: nil)
          persist_recent_history(text)
          images = attach_images(text)
          return own_prompt_failed if images.nil?

          running = @running
          # Off a live region (no echo seam) the divider comes here; after
          # #gap_above_echo it marks none.
          mark_activity
          options = { prompt: text, client_id: client_id_for(text) }
          options[:no_interrupt] = true if @no_interrupt
          options[:images] = images unless images.empty?
          options[:delivery] = delivery if delivery
          reply = @client.post_turn(**options)
          if reply.status == 202
            enqueued_id = reply.json&.fetch("enqueued_id", nil)
            @sent_ids << enqueued_id if enqueued_id
            @open_ids << enqueued_id if enqueued_id && @wait_at_eof
            @my_queued << enqueued_id if enqueued_id && reply.json&.fetch("delivery", nil) == Delivery::QUEUE
            note = sent_note(reply.json, delivery: delivery, images: images, running: running, choice: choice)
            @screen.commit(note) if note
            return
          end

          own_prompt_failed

          detail = reply.json&.fetch("error", nil)
          # Read after its deadline and dropped (BridgeClient::DEADLINE_SHARE).
          return @screen.commit("could not send the prompt (#{ExitLines::LATE})") if detail == "deadline_passed"
          # A worker from 0.51 to 0.63 refuses a queue (nothing was sent).
          return @screen.commit(queue_needs_newer_worker) if detail == "delivery_unavailable"

          @screen.commit("could not send the prompt (#{[reply.status, detail].compact.join(" ")})")
        rescue SystemCallError, IOError => e
          own_prompt_failed
          @screen.commit("could not send the prompt (#{worker_down(e)})")
        end

        # Whether the input's end must wait: the -p prompt isn't sent yet, a
        # prompt this run sent hasn't had its turn, or its turn's after_turn
        # hooks still run (their notices, source-links' sources:, come next).
        def own_turns_pending? = !@first_prompt.to_s.strip.empty? || !@open_ids.empty? || @display_pending == true

        # A turn ended: this run's prompt (and ours merged into it) had its turn.
        def own_turn_ended(event)
          return unless @wait_at_eof

          id = origin_of(event[:origin]).enqueued_id
          ours = @open_ids.include?(id) || !@merged_ids.empty?
          @own_failed = true if ours && event[:type] == :turn_failed
          @own_empty = true if ours && event[:type] == :turn_completed && event.dig(:turn_summary, :empty_answer)
          # The worker sends answer_display once its after_turn hooks ran.
          @display_pending = true if ours && event[:type] == :turn_completed && event[:display_pending]
          @open_ids.delete(id)
          @open_ids.subtract(@merged_ids)
          @merged_ids.clear
        end

        # Ours merged into the running turn: they end with it.
        def merged_own_prompts(event)
          Array(event[:origins]).each do |value|
            origin = origin_of(value)
            id = origin.enqueued_id
            @merged_ids << id if own?(origin.client_id) && @open_ids.include?(id)
          end
          nil
        end

        def own_prompt_failed
          @own_failed = true if @wait_at_eof
          nil
        end

        # The input ended and nothing of ours is left to wait for.
        def end_of_input
          detach("Detached; the session keeps running. Re-attach with: #{via.attach(@client.session_id)}") if @input_ended
          return :turn_failed if @own_failed

          @own_empty ? :empty_answer : :detached
        end

        # The prompt's `@path` images, stored where the worker reads them
        # (AttachLink#ingest_images: the session's images/ here) and sent as
        # refs: the Bridge never takes a path. nil (after a line saying why)
        # when one can't be.
        def attach_images(text)
          paths = ImageInput.extract(text)
          return [] if paths.empty?

          @link.ingest_images(paths.map { |image| image[:path] })
        rescue ImageStore::Error => e
          @screen.commit("could not attach the image: #{e.message}")
          nil
        end

        # --model (or --llm-context, --thinking) on a resumed session: run it in its
        # worker before the first prompt goes; its :command_ran decides
        # (#first_command_ran), and sends the next one.
        # @return [Symbol, nil] :failed when the worker didn't take it
        def send_first_command
          line = @first_commands.shift
          @first_command_line = line
          reply = @client.post_command(line: line, client_id: @client_id)
          if reply.status == 202
            @first_command_id = reply.json&.fetch("command_id", nil)
            return nil if @first_command_id
          end

          why =
            if reply.status == 404 then stale_worker("run commands")
            elsif (name = older_worker_command(reply, line)) then stale_worker("run #{name}")
            elsif too_late?(reply) then ExitLines::LATE
            else "the worker answered #{reply.status}"
            end
          @screen.commit("#{first_command_failed}: #{why}")
          :failed
        rescue SystemCallError, IOError => e
          @screen.commit("#{first_command_failed}: #{worker_down(e)}")
          :failed
        end

        # @return [Symbol, nil] :failed unless the command went through
        def first_command_ran(event)
          @first_command_id = nil
          if event[:status] == "ok"
            return send_first_command unless @first_commands.empty?

            send_first_prompt
            return nil
          end

          @screen.commit("#{first_command_failed}: #{event[:output]}")
          :failed
        end

        def first_command_failed
          flag = first_command_flag
          flag == "--model" ? "could not switch to the --model" : "could not set the #{flag}"
        end

        # The launch flag the first command came from: "/model X" is --model,
        # "/llm-context …" --llm-context, "/thinking X --yes" --thinking.
        def first_command_flag
          "--#{@first_command_line.to_s[%r{\A/([\w-]+)}, 1]}"
        end

        # After the join, so it lands below what the session already had. Our
        # own prompts are never echoed from events (a typed one stays on screen),
        # so it is shown here as if typed.
        def send_first_prompt
          text = @first_prompt.to_s.strip
          @first_prompt = nil
          return if text.empty?

          @screen.commit("#{paint(PROMPT, 92)}#{text}")
          # As if typed: a session command runs as the command; a typo of one
          # gets the hint, not a turn.
          if command_registry.command?(text)
            send_command(text)
          elsif (hint = command_registry.unknown_command_hint(text))
            @screen.commit(hint)
          else
            send_prompt(text)
          end
        end
      end
    end
  end
end
