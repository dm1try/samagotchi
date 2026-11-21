# frozen_string_literal: true

require "securerandom"
require "samagotchi/ref"

module Samagotchi
  module Plugin
    # A card's checked event (docs/plugins.md, Cards): what Engine#show_card
    # routes and the bundle test kit records.
    module Card
      LEVELS = %i[info warn].freeze
      MAX_ACTIONS = 6
      # An authorize address can be longer than a ref's (RefAction::MAX_URL).
      MAX_URL = 4_096

      module_function

      # @return [Hash] {type: :card, id:, source:, title:, body:, level:,
      #   actions: [{label:, command:} | {label:, url:}]}; a new id when none
      #   is given. A +url+ action opens that http(s) address in a new tab
      #   (the web) or prints it (the TUI); it never sends to the session.
      # @raise [ArgumentError] a card without a title, a bad level or action
      def build(source:, title:, body:, actions:, level:, id:)
        title = title.to_s.strip
        raise ArgumentError, "a card needs a title" if title.empty?

        level = level.to_s.to_sym
        raise ArgumentError, "card level must be one of #{LEVELS.join(", ")}" unless LEVELS.include?(level)

        actions = Array(actions)
        raise ArgumentError, "a card has at most #{MAX_ACTIONS} actions" if actions.size > MAX_ACTIONS

        actions = actions.map { |action| build_action(action) }
        id = id.to_s.strip
        { type: :card, id: id.empty? ? SecureRandom.hex(4) : id, source: source.to_s, title: title, body: body.to_s,
          level: level, actions: actions }
      end

      # @raise [ArgumentError] not a Hash, both or neither of command / url,
      #   a bad command, a url that isn't http(s) with a host (no userinfo,
      #   at most MAX_URL characters), a url action without a label
      def build_action(action)
        raise ArgumentError, "a card action is a Hash {label:, command:} or {label:, url:}" unless action.is_a?(Hash)

        action = action.transform_keys(&:to_sym)
        label = action[:label].to_s.strip
        has_command = action.key?(:command) && !action[:command].nil?
        has_url = action.key?(:url) && !action[:url].nil?
        raise ArgumentError, "a card action has a command or a url, not both" if has_command && has_url

        return url_action(label, action[:url].to_s.strip) if has_url

        command = action[:command].to_s.strip
        raise ArgumentError, "a card action needs a command" if command.empty? || command.include?("\n")

        { label: label.empty? ? command : label, command: command }
      end

      def url_action(label, url)
        unless RefAction.http_url?(url, max: MAX_URL)
          raise ArgumentError, "a card action's url must be http(s) with a host, at most #{MAX_URL} characters"
        end
        raise ArgumentError, "a card action with a url needs a label" if label.empty?

        { label: label, url: url }
      end
    end
  end
end
