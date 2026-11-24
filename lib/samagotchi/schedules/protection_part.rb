# frozen_string_literal: true

require_relative "../session_protection"

module Samagotchi
  class Schedules
    # Schedules as a SessionProtection protector: an enabled schedule holds
    # its anchor, its head and its resolved target (#target_of). A disabled
    # one holds nothing. The file is read strict (#protection_entries): one
    # that is there but doesn't read, or holds an entry that doesn't, raises
    # SessionProtection::Unreadable (the tick and the other readers keep
    # their own rules). A missing file holds nothing.
    module ProtectionPart
      # @return [Array<String>] the ids retention keeps
      def protected_ids
        links = links_now
        protection_entries.flat_map { |entry| [entry.anchor, entry.head, target_of(entry, links).first] }.compact.uniq
      end

      # The enabled schedule a delete of +session_id+ would break: one whose
      # anchor or head it is, else one whose target (#protecting) it is. A
      # head deleted would make the schedule fall back to its anchor (an
      # archived link) and fail.
      # @return [SessionProtection::Hold, nil] reason :scheduled
      def hold(session_id)
        list = protection_entries
        entry = list.find { |candidate| candidate.anchor == session_id || candidate.head == session_id } ||
                protecting(session_id, list)
        entry && SessionProtection::Hold.new(session_id: session_id, reason: :scheduled, ref: entry.id)
      end

      # The first enabled schedule on the chain +session_id+ belongs to (as
      # #for_chain: its anchor or head a link of it), which a chain's delete
      # would take.
      # @return [SessionProtection::Hold, nil] reason :chain_scheduled
      def chain_hold(session_id)
        ids = chain_of(session_id)
        entry = protection_entries.find { |candidate| ids.include?(candidate.anchor) || ids.include?(candidate.head) }
        entry && SessionProtection::Hold.new(session_id: session_id, reason: :chain_scheduled, ref: entry.id)
      end

      private

      def protecting(session_id, list)
        links = links_now
        list.find { |entry| target_of(entry, links).first == session_id }
      end

      # The enabled entries, the earliest due first (as #entries), from a
      # strict read.
      # @raise [SessionProtection::Unreadable]
      def protection_entries
        file = read(strict: true)
        bad = file.entries.find { |record| !record.is_a?(Entry) }
        raise SessionProtection::Unreadable.new(FILE, unreadable_entry_words(bad)) if bad

        file.entries.select(&:enabled).sort_by { |entry| [entry.next_due.to_s, entry.id] }
      rescue Corrupt => e
        # Corrupt's own words are for changing schedules; the cause is why.
        raise SessionProtection::Unreadable.new(FILE, (e.cause || e).message)
      end

      def unreadable_entry_words(record)
        id = record.raw.is_a?(Hash) ? record.raw["id"] : nil
        "schedule #{id || "without an id"} lacks #{record.missing.join(", ")}"
      end
    end
  end
end
