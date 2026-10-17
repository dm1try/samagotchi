# frozen_string_literal: true

require "securerandom"

module Samagotchi
  module Plugin
    # A card's checked event (docs/plugins.md, Cards): what Engine#show_card
    # routes and the bundle test kit records.
    module Card
      LEVELS = %i[info warn].freeze
      MAX_ACTIONS = 6

      module_function

      # @return [Hash] {type: :card, id:, source:, title:, body:, level:,
      #   actions: [{label:, command:}]}; a new id when none is given
      # @raise [ArgumentError] a card without a title, a bad level or action
      def build(source:, title:, body:, actions:, level:, id:)
        title = title.to_s.strip
        raise ArgumentError, "a card needs a title" if title.empty?

        level = level.to_s.to_sym
        raise ArgumentError, "card level must be one of #{LEVELS.join(", ")}" unless LEVELS.include?(level)

        actions = Array(actions)
        raise ArgumentError, "a card has at most #{MAX_ACTIONS} actions" if actions.size > MAX_ACTIONS

        actions = actions.map do |action|
          raise ArgumentError, "a card action is a Hash {label:, command:}" unless action.is_a?(Hash)

          action = action.transform_keys(&:to_sym)
          command = action[:command].to_s.strip
          raise ArgumentError, "a card action needs a command" if command.empty? || command.include?("\n")

          label = action[:label].to_s.strip
          { label: label.empty? ? command : label, command: command }
        end
        id = id.to_s.strip
        { type: :card, id: id.empty? ? SecureRandom.hex(4) : id, source: source.to_s, title: title, body: body.to_s,
          level: level, actions: actions }
      end
    end
  end
end
