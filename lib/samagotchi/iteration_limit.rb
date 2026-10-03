# frozen_string_literal: true

require_relative "config"
require_relative "log"

module Samagotchi
  # A turn's iteration limit (how many model ↔ tool rounds before the turn
  # stops and offers to continue), one resolver for the Engine, the worker
  # and the REPL.
  module IterationLimit
    KEY = "turn.max_iterations"
    # A turn's limit unless turn.max_iterations says otherwise, and the
    # loops' own default.
    DEFAULT = 100
    # A --no-interrupt / --non-interactive turn's, at least: nobody is there
    # to answer a continue offer.
    NO_INTERRUPT = 1000

    # @param no_interrupt [Boolean] the turn runs with nobody to answer: the
    #   larger of NO_INTERRUPT and the configured limit, so a configured one
    #   above 1000 is never lowered
    # @return [Integer]
    def self.for(no_interrupt: false) = no_interrupt ? [NO_INTERRUPT, configured].max : configured

    # turn.max_iterations (env SAMAGOTCHI_TURN_MAX_ITERATIONS); one below 1
    # is DEFAULT, with a warning.
    # @return [Integer]
    def self.configured
      value = Config.get(KEY)
      return DEFAULT if value.nil?
      return value if value.is_a?(Integer) && value >= 1

      Log.warn(:config, "invalid_value", echo: "Warning: #{KEY} must be 1 or more, got #{value.inspect} — using #{DEFAULT}",
                                         key: KEY)
      DEFAULT
    end
  end
end
