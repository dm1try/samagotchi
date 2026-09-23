# frozen_string_literal: true

module Samagotchi
  class Bridge
    # The SSE id of an event: `<seq>-<epoch>`, the seq first so that a reader
    # taking it as a number (`to_i`, `parseInt`) still gets the seq.
    module EventId
      PATTERN = /\A(\d+)(?:-([0-9A-Za-z]+))?\z/

      module_function

      # @return [String] "<seq>-<epoch>", or the bare seq without an epoch
      def format(seq, epoch)
        epoch ? "#{seq}-#{epoch}" : seq.to_s
      end

      # @return [Array(Integer, String|nil)] the seq and the epoch (nil for a
      #   plain seq). Anything else reads with `to_i`, as before.
      def parse(cursor)
        m = PATTERN.match(cursor.to_s.strip)
        m ? [m[1].to_i, m[2]] : [cursor.to_s.to_i, nil]
      end
    end
  end
end
