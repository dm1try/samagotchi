# frozen_string_literal: true

require_relative "../session_protection"

module Samagotchi
  class Schedules
    # Schedules as a SessionProtection protector: an enabled schedule holds
    # its anchor, its head and its resolved target (#target_of). A disabled
    # one holds nothing.
    module ProtectionPart
      # @return [Array<String>] the ids retention keeps
      def protected_ids
        links = links_now
        entries.flat_map { |entry| [entry.anchor, entry.head, target_of(entry, links).first] }.compact.uniq
      end

      # The enabled schedule a delete of +session_id+ would break: one whose
      # anchor or head it is, else one whose target (#protecting) it is. A
      # head deleted would make the schedule fall back to its anchor (an
      # archived link) and fail.
      # @return [SessionProtection::Hold, nil] reason :scheduled
      def hold(session_id)
        list = entries
        entry = list.find { |candidate| candidate.anchor == session_id || candidate.head == session_id } ||
                protecting(session_id, list)
        entry && SessionProtection::Hold.new(session_id: session_id, reason: :scheduled, ref: entry.id)
      end

      # The first enabled schedule on the chain +session_id+ belongs to
      # (#for_chain), which a chain's delete would take.
      # @return [SessionProtection::Hold, nil] reason :chain_scheduled
      def chain_hold(session_id)
        entry = for_chain(session_id).first
        entry && SessionProtection::Hold.new(session_id: session_id, reason: :chain_scheduled, ref: entry.id)
      end

      private

      def protecting(session_id, list)
        links = links_now
        list.find { |entry| target_of(entry, links).first == session_id }
      end
    end
  end
end
