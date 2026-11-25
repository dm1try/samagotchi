# frozen_string_literal: true

require "time"

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
    module ConditionPart
      # The member that holds a condition entry's real next_due in the file.
      CONDITION_NEXT_DUE = "condition_next_due"
      # Who set a condition: the owner, from the CLI. Any other value fails
      # closed (the tick records a failure and never runs it).
      CONDITION_BY = "cli"
      CONDITION_MAX_BYTES = 1024

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
