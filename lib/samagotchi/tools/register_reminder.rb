# frozen_string_literal: true

require_relative "../reminder_store"

module Samagotchi
  module Tools
    # Registers a periodic reminder. The harness will inject a [SYSTEM:] message
    # into the next idle turn's conversation.
    #
    # The agent can use this to schedule checks (API health, file changes, etc.)
    # without blocking the main turn. The reminder fires when the agent is idle
    # and a new turn is about to start.
    class RegisterReminder
      NAME        = "register_reminder"

      def self.name        = NAME

      def self.call(content, reminder_store: nil, description: nil, interval_minutes: nil)
        return "Error: reminder_store not configured" unless reminder_store

        # Parse params from content string (JSON-like)
        params = parse_params(content)
        # Merge explicit params from kernel normalizer (overrides parsed content)
        unless content.to_s.strip.empty?
          params[:name] ||= content.to_s.strip
        end
        params[:description] ||= description if description
        params[:interval_minutes] ||= interval_minutes if interval_minutes
        reminder_store.register(params)
      end

      def self.parse_params(content)
        return {} if content.to_s.strip.empty?

        # Try JSON first
        begin
          parsed = JSON.parse(content.to_s)
          return parsed if parsed.is_a?(Hash)
        rescue JSON::ParserError
          # fall through to key=value parsing
        end

        # Fallback: key=value pairs
        params = {}
        content.to_s.split(",").each do |pair|
          key, value = pair.split(":", 2).map(&:strip)
          params[key] = value if key && !value.nil?
        end
        params
      end
    end
  end
end
