# frozen_string_literal: true

module Samagotchi
  # Why a generation was cut: what CancellationController#cancel_generation!
  # is given (a bundle's stop_generation, or Engine#cut_for_steer) and what
  # the loops keep on a cut generation. +by+ is who stopped it (the hook's
  # label, or "steer"), +reason+ what it said, +steer+ true when a queued user
  # message cut it (no nudge, no retry attempt spent), +source+ that message,
  # for the steer_cut row. The same value rides a whole-turn stop
  # (stop_turn): the cancel note reads its +by+ and +reason+.
  Cut = Data.define(:by, :reason, :steer, :source) do
    def initialize(by: nil, reason: nil, steer: false, source: nil) = super

    # A hook's cut (stop_generation, or stop_turn): the bundle +by+ and its
    # +reason+.
    def self.hook(by: nil, reason: nil) = new(by: by, reason: reason)

    # Engine#cut_for_steer: a queued message cut the streaming generation.
    def self.steer(source) = new(by: "steer", reason: "a new message", steer: true, source: source)
  end
end
