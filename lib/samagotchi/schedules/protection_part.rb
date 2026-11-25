# frozen_string_literal: true

require "json"
require_relative "../session_protection"
require_relative "../state_format"

module Samagotchi
  class Schedules
    # Schedules as a SessionProtection protector: an enabled schedule holds
    # its anchor, its head and its resolved target (#target_of). A disabled
    # one holds nothing. The file is read strict (#protection_entries): one
    # that is there but doesn't read, or holds an entry that doesn't, raises
    # SessionProtection::Unreadable (the tick and the other readers keep
    # their own rules; chi schedule cancel ID drops such an entry,
    # #cancel_unreadable). A missing file holds nothing.
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

      # The stored fields of the record #read keeps but can't read whose id
      # is exactly +id+ (lenient read: what chi schedule cancel ID drops,
      # #cancel_unreadable), for a caller that must look before it cancels
      # (the cancel_schedule tool's chain check). nil when there is none.
      # @return [Hash, nil]
      def unreadable_record(id)
        record = read.entries.find { |entry| !entry.is_a?(Entry) && entry.raw.is_a?(Hash) && entry.raw["id"] == id }
        record&.raw
      end

      private

      def protecting(session_id, list)
        links = links_now
        list.find { |entry| target_of(entry, links).first == session_id }
      end

      # The enabled entries, the earliest due first (as #entries), from a
      # strict read of its own: no log line (the caller logs the refusal
      # once), a `schedules` member that isn't a list, a file chi can't open
      # (permissions, a directory) and one entry that doesn't read are all
      # Unreadable. A missing file holds nothing.
      # @raise [SessionProtection::Unreadable]
      def protection_entries
        return [] unless File.exist?(path)

        raw = JSON.parse(File.read(path))
        if raw.is_a?(Hash) && raw.key?("schedules") && !raw["schedules"].is_a?(Array)
          raise StateFormat::InvalidDocument, "schedules must be a list"
        end

        records = FORMAT.read(raw, collection: "schedules").entries
        bad = records.find { |record| !record.readable? }
        raise unreadable_entry(bad) if bad

        records.map { |record| Entry.from_record(record) }.select(&:enabled).sort_by { |entry| [entry.next_due.to_s, entry.id] }
      rescue JSON::ParserError, StateFormat::InvalidDocument, SystemCallError => e
        raise SessionProtection::Unreadable.new(FILE, e.message)
      end

      # One entry that doesn't read: named by its id when it has one, so
      # chi schedule cancel can drop it (#cancel_unreadable).
      def unreadable_entry(record)
        id = record.raw.is_a?(Hash) ? record.raw["id"] : nil
        lacks = "lacks #{record.missing.join(", ")}"
        return SessionProtection::Unreadable.new(FILE, lacks, entry: id) if id.is_a?(String) && !id.empty?

        SessionProtection::Unreadable.new(FILE, "a schedule without an id #{lacks}")
      end

      # chi schedule cancel ID of a record #read keeps but can't read (#entries
      # and #lookup never see it): removed by its exact id, under the lock,
      # the way out of an Unreadable hold. nil when there is none.
      def cancel_unreadable(id)
        unreadable = ->(record) { !record.is_a?(Entry) && record.raw.is_a?(Hash) && record.raw["id"] == id }
        # The lenient read first: a store that isn't JSON has no such record
        # and stays as it is (no strict read, no rewrite).
        return nil unless read.entries.any?(&unreadable)

        removed = nil
        write_under_lock do |file|
          removed = file.entries.find(&unreadable)
          file.entries.delete(removed) if removed
        end
        removed
      end
    end
  end
end
