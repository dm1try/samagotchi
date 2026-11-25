# frozen_string_literal: true

require "time"
require_relative "../config"
require_relative "../log"
require_relative "../session"
require_relative "../spawn_env"

module Samagotchi
  class Schedules
    # A schedule's condition (docs/scheduling.md, "Conditions (--if)"): the
    # owner's `chi schedule add|edit --if CMD`, stored as
    # {cmd:, by: "cli", set_at:}. Only the CLI sets one: no tool declares it,
    # and the guardrails keep the model's shell and file tools from setting
    # it (the chi-schedule-if rule, schedules.json a protected path).
    #
    # An older chi (0.188.0 and before) doesn't know the member and would
    # fire the entry whatever CMD says. So an entry with a condition is
    # stored with `next_due: null` and the real moment under
    # CONDITION_NEXT_DUE (#hide_next_due, on every #write; Entry.from_record
    # reads it back): an older chi's due? can't parse null, so it never
    # fires it, while the entry stays readable and enabled (it still
    # protects its sessions from retention, and an older list shows it).
    #
    # The tick (#condition_results, then #condition_gate in its main pass):
    # before it takes the lock, it runs each due entry's CMD once, in turn,
    # in the target session's folder (`sh -c`, its own process group, stdin
    # closed, ContextFetch.run_command), with the scrubbed spawn env and
    # SAMAGOTCHI_SCHEDULE_ID/_TITLE/_SESSION, for at most
    # schedule.condition_timeout_seconds. Exit 0 lets the entry go on to the
    # busy check and the firing; 1..125 is "not needed": the clock moves to
    # the next occurrence and nothing else changes (no counter, no history
    # row, the chain's one firing unused); anything else (126, 127, a
    # signal, a timeout, more than 1 MiB printed, no folder, a condition set
    # by anyone but the CLI) is a failure, counted as any other. Under the
    # lock a result counts only when the entry still has the same condition
    # and next_due (another ticker, an edit or a run-now since: it is left
    # alone and the next tick runs CMD again).
    module ConditionPart
      # The member that holds a condition entry's real next_due in the file.
      CONDITION_NEXT_DUE = "condition_next_due"
      # Who set a condition: the owner, from the CLI. Any other value fails
      # closed (the tick records a failure and never runs it).
      CONDITION_BY = "cli"
      CONDITION_MAX_BYTES = 1024
      CONDITION_TIMEOUT = 30
      CONDITION_TIMEOUT_MAX = 300
      # A result's detail (last_result, the tick's outcome, the log) keeps
      # this many characters of one line.
      CONDITION_DETAIL_CHARS = 120

      # What one run of an entry's condition said: +kind+ :pass, :not_needed
      # or :error, for the +condition+ and +next_due+ it ran for (a result
      # counts only while the entry still has both).
      ConditionResult = Data.define(:id, :condition, :next_due, :kind, :detail)

      # The command that runs a condition: ContextFetch.run_command's
      # signature, its Run back.
      DEFAULT_RUNNER = lambda do |cmd, **options|
        require_relative "../context_fetch"
        ContextFetch.run_command(cmd, **options)
      end

      # Entry.from_record's fields with +extra+: the condition symbolised (kept
      # as it is when it isn't a Hash: any condition but nil gates the entry,
      # and one that doesn't read fails, never fires), and next_due from
      # CONDITION_NEXT_DUE unless the stored next_due holds one (an older
      # chi's run-now or edit wrote it since).
      # @return [Hash] the fields, extra: included
      def self.stored(fields, extra)
        condition = fields[:condition]
        fields[:condition] = condition.transform_keys(&:to_sym) if condition.is_a?(Hash)
        extra = extra.dup
        hidden = extra.delete(CONDITION_NEXT_DUE)
        fields[:next_due] = hidden if fields[:next_due].nil? && hidden.is_a?(String)
        fields.merge(extra: extra)
      end

      # How long a condition may run (schedule.condition_timeout_seconds,
      # 1..CONDITION_TIMEOUT_MAX), for `chi schedule show` too.
      def condition_timeout_seconds
        value = Config.get("schedule.condition_timeout_seconds").to_i
        value.positive? ? value.clamp(1, CONDITION_TIMEOUT_MAX) : CONDITION_TIMEOUT
      end

      private

      # The condition +cmd+ stores as, checked: one line, not blank, at most
      # CONDITION_MAX_BYTES. A `date` one-off takes none: it fires once, and a
      # "not needed" would have no next time to move to.
      # @return [Hash] {cmd:, by:, set_at:}
      # @raise [Usage]
      def condition_for(cmd, recurrence)
        cmd = cmd.to_s
        raise Usage, "--if needs a command" if cmd.strip.empty?
        raise Usage, "--if takes one line: no newline, carriage return or NUL" if cmd.match?(/[\n\r\0]/)
        if cmd.bytesize > CONDITION_MAX_BYTES
          raise Usage, "the --if command is #{cmd.bytesize} bytes; the limit is #{CONDITION_MAX_BYTES}"
        end

        refuse_dated_condition!(recurrence)
        { cmd: cmd, by: CONDITION_BY, set_at: @clock.call.utc.iso8601 }
      end

      # @raise [Usage] a `date` one-off with a condition
      def refuse_dated_condition!(recurrence)
        return unless recurrence.is_a?(Hash) && recurrence[:kind] == "date"

        raise Usage, "a --date one-off can't have --if: it fires once (use --every or --weekday)"
      end

      # The pre-pass: each enabled entry with a condition that is due now
      # (lock-free read; the main pass applies the rest of the rules), its
      # CMD run once, in turn, until +cancelled+. nil when there is none.
      # @return [Hash{String => ConditionResult}, nil]
      def condition_results(now, cancelled)
        candidates = read(quiet: true).entries.grep(Entry).select { |entry| entry.enabled && !entry.condition.nil? && entry.due?(now) }
        return nil if candidates.empty?

        links = links_now
        results = {}
        candidates.sort_by { |entry| [entry.next_due.to_s, entry.id] }.each do |entry|
          break if cancelled.call

          result = evaluate_condition(entry, links, cancelled)
          results[entry.id] = result if result
        end
        results
      end

      # One entry's condition run; nil when it didn't run to an answer (its
      # target doesn't resolve: the main pass's check says why; or the run
      # was cancelled).
      def evaluate_condition(entry, links, cancelled)
        cmd = condition_cmd(entry)
        by = entry.condition.is_a?(Hash) ? entry.condition[:by] : nil
        return condition_result(entry, :error, "it doesn't read (no command)") if cmd.nil?
        unless by == CONDITION_BY
          return condition_result(entry, :error, "set by #{by.to_s.empty? ? "no one" : by}: this chi runs only one set with chi schedule")
        end

        target, = target_of(entry, links)
        return nil if target.nil?

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        run = @condition_runner.call(cmd, cwd: condition_cwd(target), env: condition_env(entry, target),
                                          timeout: condition_timeout_seconds, cancelled: cancelled)
        return nil if run.cancelled

        kind, detail = condition_verdict(run)
        Log.info(:worker, "schedule_condition", id: entry.id, result: kind, detail: detail,
                                                ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
        condition_result(entry, kind, detail)
      rescue StandardError => e
        # A run that blows up (a spawn refusing its env, a session file that
        # doesn't load) is this entry's failure, never the whole tick's: the
        # entry stays due, and an abort here would stop every schedule.
        Log.warn(:worker, "schedule_condition_failed", id: entry.id, error: e.class.name, msg: e.message)
        condition_result(entry, :error, "couldn't run it: #{e.class}: #{e.message}")
      end

      def condition_result(entry, kind, detail)
        ConditionResult.new(id: entry.id, condition: entry.condition, next_due: entry.next_due, kind: kind,
                            detail: condition_line(detail))
      end

      # [kind, detail] for a Run: by how it ended first (Run#status is nil
      # unless it ended on its own within the cap), then by its exit code.
      def condition_verdict(run)
        code = run.status&.exitstatus
        return [:error, run.error || "it didn't run"] if code.nil?
        return [:pass, "exit 0"] if code.zero?

        said = first_line(run.output) || last_line(run.stderr)
        return [:not_needed, ["exit #{code}", said].compact.join(": ")] if (1..125).cover?(code)

        [:error, run.error || "exit #{code}"]
      end

      # The main pass's say on an entry with a condition, under the lock,
      # once its target resolves (the check reports one that doesn't). nil:
      # it passed, on to the busy check and the firing. Else [entry as
      # updated, Outcome or nil]: catch_up none a whole cycle late (missed,
      # CMD unasked), no fresh result (left as it is, no outcome: the next
      # tick runs CMD again), a failure, or not needed.
      # @return [Array(Entry, Outcome|nil), nil]
      def condition_gate(entry, links, results, now)
        return nil if entry.condition.nil?

        target, = target_of(entry, links)
        return nil if target.nil?

        if entry.catch_up == "none" && late?(entry, now)
          return [reschedule(entry, now), Outcome.new(id: entry.id, title: entry.title, status: "missed", detail: "past its time",
                                                      entry: entry)]
        end

        result = results&.fetch(entry.id, nil)
        unless result && result.condition == entry.condition && result.next_due == entry.next_due
          Log.info(:worker, "schedule_condition_unchecked", id: entry.id)
          return [entry, nil]
        end

        case result.kind
        when :pass then nil
        when :not_needed
          updated = not_needed(entry, result, now)
          [updated, Outcome.new(id: entry.id, title: entry.title, status: "not-needed", detail: result.detail, entry: updated)]
        else
          reason = "condition: #{result.detail}"
          [failed(entry, reason, now: now), Outcome.new(id: entry.id, title: entry.title, status: "failed", detail: reason, entry: entry)]
        end
      end

      # Not needed this time: the clock moves to the next occurrence, as
      # if it had fired; no counter, no history row, no firing field changes.
      def not_needed(entry, result, now)
        entry.with(next_due: next_due_for(entry.recurrence, from: now).utc.iso8601, last_result: "not needed: #{result.detail}")
      end

      # The target session's folder (nil: run_command says it is gone).
      def condition_cwd(target)
        Session.load(target, state_dir: @state_dir).working_directory
      rescue Session::NotFound
        nil
      end

      # The scrubbed spawn env and the schedule's own keys; never the
      # ticker's SAMAGOTCHI_PARENT_SESSION (CMD is no agent's).
      def condition_env(entry, target)
        SpawnEnv.sanitized_spawn_env.merge("SAMAGOTCHI_SCHEDULE_ID" => entry.id, "SAMAGOTCHI_SCHEDULE_TITLE" => entry.title.to_s,
                                           "SAMAGOTCHI_SCHEDULE_SESSION" => target, "SAMAGOTCHI_PARENT_SESSION" => nil)
      end

      def first_line(text) = text_lines(text).first
      def last_line(text) = text_lines(text).last

      def text_lines(text)
        text.to_s.dup.force_encoding(Encoding::UTF_8).scrub.lines.map(&:strip).reject(&:empty?)
      end

      # One line of valid UTF-8, no control characters, cut.
      def condition_line(text)
        line = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub.gsub(/[[:cntrl:]]+/, " ").strip
        line.length > CONDITION_DETAIL_CHARS ? "#{line[0, CONDITION_DETAIL_CHARS - 1]}…" : line
      end

      # The command of +entry+'s condition, nil when it has none or one that
      # isn't {cmd: String}.
      def condition_cmd(entry)
        condition = entry.condition
        condition.is_a?(Hash) && condition[:cmd].is_a?(String) ? condition[:cmd] : nil
      end

      # +entry+ as the file stores it: one with a condition and a next_due
      # keeps that next_due under CONDITION_NEXT_DUE, and null in next_due.
      def hide_next_due(entry)
        return entry if entry.condition.nil? || entry.next_due.nil?

        entry.with(next_due: nil, extra: entry.extra.merge(CONDITION_NEXT_DUE => entry.next_due))
      end
    end
  end
end
