# frozen_string_literal: true

module Samagotchi
  class Bridge
    # What a running turn's plugin card waits as, from its data: "asks" (an
    # action with a command: check-in's Nudge / Keep going / Stop), else
    # "warn" (level warn: it stays in sight), else nil. The Ruby twin of the
    # page's card_kinds.js cardWait for an in-turn card (TurnAccumulator folds
    # in-turn cards only); spec/shared/card_wait_cases.json pins both.
    module CardWait
      module_function

      # @param event [Hash] a card event or a drawing's card part event
      #   (symbol or string keys)
      # @return [String, nil] "asks", "warn" or nil
      def kind(event)
        return nil unless event.is_a?(Hash)
        return "asks" if Array(field(event, :actions)).any? { |action| command?(action) }

        field(event, :level).to_s == "warn" ? "warn" : nil
      end

      # A JavaScript-truthy command (card_kinds.js: `a && a.command`).
      def command?(action)
        return false unless action.is_a?(Hash)

        command = field(action, :command)
        !(command.nil? || command == false || command == "" || command == 0)
      end

      def field(hash, key) = hash.key?(key) ? hash[key] : hash[key.to_s]
    end
  end
end
