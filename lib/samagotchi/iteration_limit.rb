# frozen_string_literal: true

module Samagotchi
  # A turn's iteration limit (how many model ↔ tool rounds before the turn
  # stops and offers to continue), one resolver for the Engine, the worker
  # and the REPL.
  module IterationLimit
    # A turn's limit, and the loops' own default.
    DEFAULT = 100
    # A --no-interrupt / --non-interactive turn's: nobody is there to answer
    # a continue offer.
    NO_INTERRUPT = 1000

    # @param no_interrupt [Boolean] the turn runs with nobody to answer
    # @return [Integer]
    def self.for(no_interrupt: false) = no_interrupt ? NO_INTERRUPT : DEFAULT
  end
end
