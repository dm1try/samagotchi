# frozen_string_literal: true

module Samagotchi
  class Schedules
    # `chi schedule edit` (docs/scheduling.md): change a schedule's title,
    # prompt, recurrence, catch-up or budgets in place, keeping its id, its
    # session and mode (cancel and add for those), its counters, `enabled`
    # (a spent `date` one-off stays disabled) and the firing fields.
    module EditPart
      # A recurrence edit while a firing is in flight: a state, not a usage
      # error (`chi schedule edit` exits 1).
      class InFlight < StandardError
        def initialize(msg = "a run is in progress; edit the time after it settles") = super
      end

      # Each argument nil keeps the field; only the fields given change.
      # @param recurrence [Hash, nil] a whole one, from Schedules.recurrence
      # @param condition [String, :none, nil] the owner's `--if CMD`, :none
      #   to drop it (`--no-if`); the CLI's only, never a tool's
      # @return [Entry, nil] the entry as edited; nil when no schedule matches
      #   (or it is gone by the time the lock is held)
      # @raise [Usage] nothing to change, a field that is wrong, a duplicate
      #   in the chain
      # @raise [InFlight] a recurrence edit while a firing is in flight
      def edit(id_or_name, title: nil, prompt: nil, recurrence: nil, catch_up: nil, keep_links: nil, max_failures: nil,
               max_skips: nil, condition: nil)
        entry = lookup(id_or_name)
        return nil if entry.nil?

        changes = differing(entry, edit_changes(title: title, prompt: prompt, recurrence: recurrence, catch_up: catch_up,
                                                keep_links: keep_links, max_failures: max_failures, max_skips: max_skips))
        changes.merge!(condition_change(entry, condition, changes.fetch(:recurrence, entry.recurrence)))
        # A condition kept, on a recurrence edited to a one-off.
        refuse_dated_condition!(changes[:recurrence]) if changes.key?(:recurrence) && changes.fetch(:condition, entry.condition)
        raise Usage, "nothing to change" if changes.empty?

        # Each duplicate test only on what the edit changes: a clash in a field
        # it leaves alone (a twin `enable` let in) is not of its making.
        by_title = changes.key?(:title)
        by_content = changes.key?(:prompt) || changes.key?(:recurrence)
        if by_title || by_content
          same = duplicate_in_chain(entry.anchor, prompt: changes.fetch(:prompt, entry.prompt),
                                                  title: changes.fetch(:title, entry.title),
                                                  recurrence: changes.fetch(:recurrence, entry.recurrence), except: entry.id,
                                                  by_title: by_title, by_content: by_content)
          refuse_duplicate!(same, entry.mode) if same
        end

        result = nil
        write_under_lock do |file|
          position = file.entries.index { |candidate| candidate.is_a?(Entry) && candidate.id == entry.id }
          next if position.nil?

          result = file.entries[position] = edited(file.entries[position], changes)
        end
        result
      end

      # The duplicate rule #add and #edit share: an enabled schedule of the
      # same chain that says the same thing, the same prompt and recurrence
      # or the same title. An edit passes +except+ (its own entry is no
      # duplicate of itself) and turns off the test whose fields it leaves
      # alone (+by_content+: the prompt and recurrence; +by_title+).
      # @return [Entry, nil]
      def duplicate_in_chain(session_id, prompt:, title:, recurrence:, except: nil, by_content: true, by_title: true)
        given_title = title.to_s.strip
        ids = chain_of(session_id)
        entries.find do |entry|
          next if entry.id == except
          next unless ids.include?(entry.anchor) || ids.include?(entry.head)

          (by_content && entry.prompt == prompt && entry.recurrence == recurrence) ||
            (by_title && !given_title.empty? && entry.title.to_s.strip.casecmp?(given_title))
        end
      end

      # @raise [Usage] naming the schedule that already says the same thing
      def refuse_duplicate!(same, mode)
        raise Usage, "#{same.id} already schedules this (#{same.recurrence_words}, #{mode}: #{same.prompt}); " \
                     "cancel it with chi schedule cancel #{same.id} to change it"
      end

      private

      # The +changes+ whose value is not +entry+'s already (`--title ""` on
      # an untitled entry changes nothing). A condition is the same when its
      # command is: a new set_at alone is no change.
      def differing(entry, changes)
        changes.reject do |field, value|
          field == :condition ? same_condition?(entry.condition, value) : entry.public_send(field) == value
        end
      end

      def same_condition?(stored, given)
        return stored.nil? if given.nil?

        stored.is_a?(Hash) && stored[:cmd] == given[:cmd] && stored[:by] == given[:by]
      end

      # {condition: …} when +condition+ changes it: a command checked as #add
      # checks it, :none for none; {} for nil (kept) or the same command.
      def condition_change(entry, condition, recurrence)
        return {} if condition.nil?

        differing(entry, condition: condition == :none ? nil : condition_for(condition, recurrence))
      end

      # The fields given, checked as #add checks them.
      def edit_changes(title:, prompt:, recurrence:, catch_up:, **budgets)
        changes = {}
        changes[:title] = title.to_s.strip.empty? ? nil : title.to_s.strip unless title.nil?
        changes[:prompt] = validate_prompt!(prompt) unless prompt.nil?
        changes[:recurrence] = recurrence unless recurrence.nil?
        unless catch_up.nil?
          changes[:catch_up] = catch_up.to_s.strip
          validate_catch_up!(changes[:catch_up])
        end
        { keep_links: 0, max_failures: 1, max_skips: 1 }.each do |field, min|
          value = int_value(budgets[field], min: min, name: field.to_s)
          changes[field] = value unless value.nil?
        end
        changes
      end

      # +stored+ with +changes+, under the lock. A new recurrence's clock
      # starts now, as #add's does; while a firing is in flight it is refused:
      # #record would put that firing's due_was back over the new clock.
      def edited(stored, changes)
        # Against the entry as stored now: what another writer already set is no change.
        changes = differing(stored, changes)
        return stored if changes.empty?

        now = @clock.call
        updated = stored.with(**changes)
        if changes.key?(:recurrence)
          raise InFlight if stored.firing_since || stored.pending_turn_id

          updated = updated.with(next_due: next_due_for(changes[:recurrence], from: now).utc.iso8601, due_was: nil)
        end
        with_history(updated, "edited", changes.keys.join(", "), at: now)
      end
    end
  end
end
