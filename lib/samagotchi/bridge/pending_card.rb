# frozen_string_literal: true

require "json"
require "fileutils"

module Samagotchi
  class Bridge
    # The running turn's open card with actions (check-in's Nudge / Keep
    # going / Stop) as a file in the session's folder, pending_card.json
    # {id:, bundle:}, for `chi web`'s session hub: it watches files, not
    # workers, and a tab behind notifies from its summary (notify.js), as
    # for a pending question. A persistent observer, like CardStore.
    #
    # Written when such a card shows; removed when that card comes again
    # without actions (resolved), when the turn ends, and when the Bridge
    # starts or stops. A card with no actions (loop-guard's warn) never
    # writes it, nor does a card between turns.
    class PendingCard
      FILE = "pending_card.json"
      TURN_ENDS = %i[turn_completed turn_canceled turn_failed].freeze

      # @param session_dir [String] the session's folder
      # @return [Hash, nil] {id:, bundle:}, nil without a readable file
      def self.read(session_dir)
        data = JSON.parse(File.read(File.join(session_dir, FILE)))
        return nil unless data.is_a?(Hash) && !data["id"].to_s.empty?

        { id: data["id"].to_s, bundle: data["bundle"].to_s }
      rescue StandardError
        nil
      end

      def initialize(session_dir)
        @path = File.join(session_dir, FILE)
        @mutex = Mutex.new
        @id = nil
      end

      def call(event)
        @mutex.synchronize { fold(event) }
      rescue StandardError
        nil # never break the running turn
      end

      # No card is open (a start after a worker that died with one, a stop).
      def clear
        @mutex.synchronize do
          @id = nil
          FileUtils.rm_f(@path)
        end
      rescue StandardError
        nil
      end

      private

      def fold(event)
        case event[:type]
        when :card then card(event)
        when *TURN_ENDS then remove
        end
      end

      def card(event)
        asks = Array(event[:actions]).any?
        if event[:in_turn] && asks
          write(event[:id].to_s, event[:source].to_s)
        elsif @id && event[:id].to_s == @id
          remove
        end
      end

      def write(id, bundle)
        FileUtils.mkdir_p(File.dirname(@path))
        temp = "#{@path}.tmp"
        File.write(temp, JSON.generate({ "id" => id, "bundle" => bundle }))
        File.rename(temp, @path)
        @id = id
      end

      def remove
        return unless @id

        @id = nil
        FileUtils.rm_f(@path)
      end
    end
  end
end
