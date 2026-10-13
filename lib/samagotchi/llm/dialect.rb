# frozen_string_literal: true

module Samagotchi
  module LLM
    # How a provider's Messages API (`api: anthropic`) departs from
    # Anthropic's own: a small set of overrides on the standard wire, picked
    # per host with `dialect:` (HostConfig#dialect, HostEntry#dialect_profile).
    # A host without one is STANDARD (Anthropic, Splash, a gateway passing
    # Claude through).
    #
    # name: the config value ("standard" for none);
    # auth: the header the key goes in when the host sets no auth:
    #   (LLM::ApiKey::SCHEMES);
    # thinking_display: the `display` sent with adaptive or budget thinking,
    #   nil for none;
    # cache_breakpoints: whether chat requests carry cache_control;
    # session_header: a header that carries the session id (beside
    #   Session-Id), nil for none.
    Dialect = Data.define(:name, :auth, :thinking_display, :cache_breakpoints, :session_header) do
      # The dialect for a `dialect:` name (HostConfig#dialect); STANDARD for
      # nil or an unknown one.
      def self.for(name) = self::BY_NAME.fetch(name.to_s, self::STANDARD)

      # A hosts entry's `dialect:` as written: the name, or nil when unset.
      # An unknown name, or one on a host whose api isn't anthropic, warns
      # once (naming +where+) and is ignored.
      # @param api [Symbol, nil] the entry's api
      # @return [String, nil]
      def self.parse(value, where, api:)
        text = value.to_s.strip.downcase
        return nil if text.empty?

        require_relative "../config"

        unless self::BY_NAME.key?(text)
          ConfigFile.warn_once "Warning: #{where}: dialect must be one of #{self::BY_NAME.keys.join(", ")}; ignored"
          return nil
        end
        return text if api&.to_sym == :anthropic

        ConfigFile.warn_once "Warning: #{where}: dialect has no effect on api: #{api || "(none)"}; ignored"
        nil
      end
    end

    Dialect::STANDARD = Dialect.new(name: "standard", auth: :x_api_key, thinking_display: "summarized",
                                    cache_breakpoints: true, session_header: nil)
    # Fireworks' /v1/messages (docs.fireworks.ai, anthropic-compatibility):
    # Bearer auth, no `display` in its thinking schema (every object refuses
    # extra fields; thinking comes back by default), an automatic prefix
    # cache (no breakpoints), and x-session-affinity to keep a session on
    # one replica, where its cache is.
    Dialect::FIREWORKS = Dialect.new(name: "fireworks", auth: :bearer, thinking_display: nil,
                                     cache_breakpoints: false, session_header: "x-session-affinity")
    Dialect::BY_NAME = { "standard" => Dialect::STANDARD, "fireworks" => Dialect::FIREWORKS }.freeze
  end
end
