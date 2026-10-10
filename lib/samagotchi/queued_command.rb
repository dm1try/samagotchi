# frozen_string_literal: true

require "securerandom"

module Samagotchi
  # A session command on its way from the Bridge (POST /command, a command
  # sent as a message, the worker's own Bridge#queue_command) to the
  # worker's command queue. +card+: a card's action (the step-limit
  # question's answer), whose line the UIs leave out. The worker adds
  # where it waits (Worker#on_command): +mid_turn+ (the policy it got:
  # :queue, :refuse, :loop), +after_seq+ (the event count then, so a
  # turn's end knows it came before) and +after_file+ (the input file it
  # runs after, a basename).
  QueuedCommand = Data.define(:command_id, :client_id, :line, :card, :mid_turn, :after_seq, :after_file) do
    def initialize(command_id:, line:, client_id: nil, card: false, mid_turn: nil, after_seq: nil, after_file: nil) = super

    # A new command with a fresh id.
    def self.mint(line, client_id: nil, card: false)
      new(command_id: SecureRandom.uuid, client_id: client_id, line: line, card: card ? true : false)
    end

    # The fields its command_queued and command_ran name: card only when
    # it is a card's.
    # @return [Hash]
    def event_fields
      fields = { command_id: command_id, client_id: client_id, line: line }
      fields[:card] = true if card
      fields
    end

    # Whether it waits for the running turn's end (its line was shown at
    # its command_queued).
    def waits_for_turn_end? = mid_turn == :queue
  end
end
