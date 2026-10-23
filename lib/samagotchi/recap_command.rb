# frozen_string_literal: true

require_relative "config"

module Samagotchi
  # /recap on|off|default, the setting form of /recap (the bare /recap,
  # which shows the recap, is the UIs' own): this session's own
  # recap.enabled (Engine#recap_override=), the same value
  # `chi --set recap.enabled=…` saves, applied at once (the idle recap job
  # is rebuilt or dropped). `default` removes it, and config.yml (or env)
  # decides again. The session's value beats config.yml's: `/recap on`
  # turns it on under `recap: false` too. It doesn't save: its host does
  # on the reply's changed: [:recap] (Worker#run_command).
  class RecapCommand
    NAME = "/recap"
    CHOICES = { "on" => true, "off" => false, "default" => nil }.freeze
    USAGE = "usage: #{NAME} [on|off|default]".freeze

    # @param engine [Engine] #session, #recap_override=, #recap
    def initialize(engine:)
      @engine = engine
    end

    # @param args [String] what follows /recap
    # @return [Array(String, Boolean, Symbol)] the reply, whether this
    #   session's recap setting changed, and :ok or :error
    def run(args)
      word = args.to_s.strip.downcase
      return [USAGE, false, :error] unless CHOICES.key?(word)
      return ["no session yet", false, :error] unless @engine.session

      value = CHOICES.fetch(word)
      changed = @engine.recap_override != value
      @engine.recap_override = value if changed
      [status_line(value), changed, :ok]
    end

    # "recap: off (this session; config.yml: on)", "recap: on (config.yml)".
    # @param own [Boolean, nil] the session's own value, nil for none
    def status_line(own)
      from_config = self.class.config_status
      line = if own.nil?
               "recap: #{word(from_config[:on])} (#{from_config[:source]})"
             else
               "recap: #{word(own)} (this session; #{from_config[:source]}: #{word(from_config[:on])})"
             end
      # On by its own word, yet no job: a pinned recap host or model that
      # doesn't resolve (warned in the log), or an embedder's recap: false.
      on = own.nil? ? from_config[:on] : own
      on && @engine.recap.nil? ? "#{line}; no recap is written: its host or model doesn't resolve (see the log)" : line
    end

    # Whether the recap is on without the session's own value: off by a
    # scalar `recap: false`, `recap: {enabled: false}` or
    # SAMAGOTCHI_RECAP_ENABLED=false (ConfigFile.recap_config sees all
    # three), else on (the default).
    # @return [Hash] {on: Boolean, source: "config.yml" or "env"}
    def self.config_status
      on = ConfigFile.recap_config != false
      _value, origin = Config.get_with_origin("recap.enabled")
      { on: on, source: origin == :env ? "env" : "config.yml" }
    end

    private

    def word(enabled) = enabled ? "on" : "off"
  end
end
