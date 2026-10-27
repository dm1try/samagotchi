# frozen_string_literal: true

require_relative "../tools/task_record"

module Samagotchi
  class TerminalUI
    # The /exit ask and its reply lines: pure text from a reply, holds, and
    # the invocation used to spell commands.
    module ExitLines
      module_function

      # Why a request the Bridge read after its deadline didn't go through.
      LATE = "worker not answering in time"
      # An exit the worker agreed to in an empty session. Said before it has
      # left: it checks again once it lets go, and a note or prompt arriving
      # first keeps the session (SessionManager.discard_left_session).
      EMPTY_WORDS = "the session is empty: it will be discarded if nothing arrives before its worker stops."
      EMPTY_EXIT = "Detached; #{EMPTY_WORDS}"
      # Why the worker stayed up after /exit, by the reason it gave.
      HELD_REASONS = {
        "turn_running" => "a turn is running", "input_queued" => "prompts are queued",
        "continue_offered" => "a continue offer is pending", "client_connected" => "another UI is attached",
        "reminders" => "reminders are set", "starting" => "the worker is still starting",
        "background_tasks" => "background tasks it started are still running",
        "delegates" => "delegates of this session are still running"
      }.freeze
      # How to end a background task that holds the worker up (an older
      # worker's 409 has no hint of its own).
      TASK_STOP_HINT = "stop one with the web's stop-task button or by asking for task_stop"
      # The /exit ask, when every hold is one the user can stop: what still
      # runs, then the three answers. Each kind, singular and plural.
      EXIT_HOLD_WORDS = {
        "reminders" => %w[reminder reminders],
        "background_tasks" => ["background task", "background tasks"],
        "delegates" => %w[delegate delegates]
      }.freeze
      # The 200's +stopped+ keys, by the kind the ask lists them under.
      STOPPED_KEYS = { "reminders" => "reminders", "tasks" => "background_tasks", "delegates" => "delegates" }.freeze
      EXIT_ASK_OPTIONS = ["Keep running in the background (detach)", "Stop them and exit", "Back to the session"].freeze
      # How the ask reads an answer.
      EXIT_ANSWERS = {
        "1" => :keep, "keep" => :keep, "detach" => :keep, "background" => :keep,
        "2" => :stop, "stop" => :stop, "exit" => :stop,
        "3" => :back, "back" => :back, "stay" => :back
      }.freeze

      # The ask: what still runs, then the three answers.
      def ask_lines(holds)
        lines = holds.map do |hold|
          items = Array(hold["items"])
          singular, plural = hold_words(hold["kind"])
          "  • #{items.size} #{items.size == 1 ? singular : plural}: #{items.map { |item| item_word(item, hold["kind"]) }.join(", ")}"
        end
        lines += EXIT_ASK_OPTIONS.each_with_index.map { |option, index| "  #{index + 1}. #{option}" }
        (["This session still has:"] + lines).join("\n")
      end

      # One entry of a hold: the command or name, with its detail in
      # brackets; a delegate leads with its short id and its title in quotes.
      def item_word(item, kind)
        label = item["label"].to_s
        label = "#{item["id"].to_s[0, 8]} \"#{label}\"" if kind == "delegates"
        detail = item["detail"].to_s
        detail.empty? ? label : "#{label} (#{detail})"
      end

      # 1: detach, everything left running.
      def kept_line(holds, via:, session_id:)
        "Detached; the session keeps running (#{hold_words_list(holds)}). " \
          "Re-attach with: #{via.attach(session_id)}"
      end

      # "2 reminders, 1 background task, 1 delegate" from the ask's holds.
      def hold_words_list(holds)
        holds.map do |hold|
          items = Array(hold["items"])
          singular, plural = hold_words(hold["kind"])
          "#{items.size} #{items.size == 1 ? singular : plural}"
        end.join(", ")
      end

      def hold_words(kind) = EXIT_HOLD_WORDS.fetch(kind.to_s, [kind.to_s, kind.to_s])

      # What a stop-all exit stopped: "stopped 2 reminders (api_health, git
      # push), 1 background task (rails s)"; nil when it stopped nothing.
      def stopped_words(stopped)
        return nil unless stopped.is_a?(Hash)

        parts = STOPPED_KEYS.filter_map do |key, kind|
          names = Array(stopped[key])
          next if names.empty?

          singular, plural = hold_words(kind)
          "#{names.size} #{names.size == 1 ? singular : plural} (#{names.join(", ")})"
        end
        parts.empty? ? nil : "stopped #{parts.join(", ")}"
      end

      def exit_line(reply, via:, session_id:)
        error = reply.json&.fetch("error", nil)
        case reply.status
        when 200
          stopped = stopped_words(reply.json&.fetch("stopped", nil))
          return EMPTY_EXIT if discards?(reply) && stopped.nil?
          return "Detached; #{stopped}. #{EMPTY_WORDS.capitalize}" if discards?(reply)

          "Detached; #{stopped || "the session's worker is stopping"}. Resume with: #{via.resume(session_id)}"
        when 409
          reason = reply.json&.fetch("reason", nil).to_s
          "Detached; the session keeps running (#{held_words(reason, reply.json&.fetch("tasks", nil))}). " \
            "Re-attach with: #{via.attach(session_id)}"
        when 0 then exit_failed_line("no reply", via: via, session_id: session_id)
        when 408 then exit_failed_line(LATE, via: via, session_id: session_id)
        else
          # A worker from before the route answers the Bridge's plain 404.
          if error == "not_found"
            return "Detached; this worker runs an older chi and can't be stopped from here: #{via.command("sessions stop #{session_id}")}"
          end

          exit_failed_line([reply.status, reply.json&.fetch("detail", nil) || error].compact.join(" "),
                           via: via, session_id: session_id)
        end
      end

      # Why the worker stayed up; the background tasks it waits for by
      # their short id and command (a finish wake's, D3), and how to stop one.
      def held_words(reason, tasks)
        words = HELD_REASONS.fetch(reason, reason)
        listed = Array(tasks).filter_map { |t| "#{Tools::TaskRecord.short_id(t["id"])} (#{t["command"]})" if t.is_a?(Hash) }
        listed.empty? ? words : "#{words}: #{listed.join(", ")}; #{TASK_STOP_HINT}"
      end

      # An older worker leaves the field out.
      def discards?(reply) = reply.json&.fetch("discard", nil) == true

      def exit_failed_line(why, via:, session_id:)
        "Detached (could not ask the worker to stop: #{why}). Re-attach with: #{via.attach(session_id)}"
      end
    end
  end
end
