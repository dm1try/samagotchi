# frozen_string_literal: true

module Samagotchi
  class Schedules
    # `chi schedule edit` (docs/scheduling.md): change a schedule's title,
    # prompt, recurrence, catch-up or budgets in place, keeping its id, its
    # session and mode (cancel and add for those), its counters, `enabled`
    # (a spent `date` one-off stays disabled) and the firing fields.
    module EditPart
      # Each argument nil keeps the field; only the fields given change.
      # @param recurrence [Hash, nil] a whole one, from Schedules.recurrence
      # @return [Entry, nil] the entry as edited; nil when no schedule matches
      #   (or it is gone by the time the lock is held)
      # @raise [Usage] nothing to change, a field that is wrong, a duplicate
      #   in the chain, or a recurrence edit while a firing is in flight
      def edit(id_or_name, title: nil, prompt: nil, recurrence: nil, catch_up: nil, keep_links: nil, max_failures: nil,
               max_skips: nil)
        entry = lookup(id_or_name)
        return nil if entry.nil?

        changes = edit_changes(title: title, prompt: prompt, recurrence: recurrence, catch_up: catch_up,
                               keep_links: keep_links, max_failures: max_failures, max_skips: max_skips)
        raise Usage, "nothing to change" if changes.empty?

        # Only an edit of what a duplicate is judged on: a budget edit of a
        # disabled entry whose twin is on must not be refused.
        if changes.key?(:title) || changes.key?(:prompt) || changes.key?(:recurrence)
          same = duplicate_in_chain(entry.anchor, prompt: changes.fetch(:prompt, entry.prompt),
                                                  title: changes.fetch(:title, entry.title),
                                                  recurrence: changes.fetch(:recurrence, entry.recurrence), except: entry.id)
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

      private

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
        now = @clock.call
        updated = stored.with(**changes)
        if changes.key?(:recurrence)
          if stored.firing_since || stored.pending_turn_id
            raise Usage, "a run is in progress; edit the time after it settles"
          end

          updated = updated.with(next_due: next_due_for(changes[:recurrence], from: now).utc.iso8601, due_was: nil)
        end
        with_history(updated, "edited", changes.keys.join(", "), at: now)
      end
    end
  end
end
