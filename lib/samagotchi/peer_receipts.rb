# frozen_string_literal: true

require "json"
require_relative "session_paths"

module Samagotchi
  # chi's side of a session's peer mail: what the worker did with each
  # message (a Receipt), the last serial it took (+taken+) and the session's
  # +box+ per peer, in sessions/<id>/peer_receipts.json. Written by the
  # worker alone (on its loop thread); read by the CLI (chi peer say's
  # line, ls) and chi web. A peer's own folder (PeerMailbox) holds none of
  # it, so nothing a peer writes moves chi's counters.
  #   {"peers": {"<peer>": {"box": "a1b2c3", "taken": 12, "receipts": [Receipt…]}}}
  class PeerReceipts
    FILE = "peer_receipts.json"
    # The receipt's states: woke (its wake turn ran), held (it asked; a
    # +reason+ held it), noted (it didn't ask), read (a turn read it,
    # +turn+), ended (that turn's +outcome+: completed, failed, stopped),
    # refused (+reason+: undeclared, invalid).
    STATES = %w[woke held noted read ended refused].freeze

    # What the worker did with one message.
    Receipt = Data.define(:serial, :state, :reason, :turn, :outcome, :at) do
      def initialize(serial:, state:, at:, reason: nil, turn: nil, outcome: nil) = super

      def to_h = { "serial" => serial, "state" => state, "reason" => reason, "turn" => turn, "outcome" => outcome,
                   "at" => at }.compact

      # @return [Receipt, nil] nil for a value of the wrong shape
      def self.from_h(data)
        return nil unless data.is_a?(Hash) && data["serial"].is_a?(Integer) && STATES.include?(data["state"])
        return nil unless %w[reason turn outcome at].all? { |key| data[key].nil? || data[key].is_a?(String) }

        new(serial: data["serial"], state: data["state"], reason: data["reason"], turn: data["turn"],
            outcome: data["outcome"], at: data["at"])
      end
    end

    # One peer's part: its +box+ (6 hex the worker mints with the peer's
    # first message: the note ids' mailbox part), the last serial taken,
    # the receipts (oldest first).
    Peer = Data.define(:box, :taken, :receipts) do
      def self.empty = new(box: nil, taken: 0, receipts: [])

      def to_h = { "box" => box, "taken" => taken, "receipts" => receipts.map(&:to_h) }.compact

      def self.from_h(data)
        return empty unless data.is_a?(Hash)

        box = data["box"].is_a?(String) && data["box"].match?(/\A[0-9a-f]{6}\z/) ? data["box"] : nil
        taken = data["taken"].is_a?(Integer) && data["taken"].positive? ? data["taken"] : 0
        receipts = data["receipts"].is_a?(Array) ? data["receipts"].filter_map { |item| Receipt.from_h(item) } : []
        new(box: box, taken: taken, receipts: receipts)
      end

      # @return [Receipt, nil] the receipt for +serial+
      def receipt(serial) = receipts.reverse_each.find { |item| item.serial == serial }
    end

    # The whole file: Peer by name.
    Book = Data.define(:peers) do
      def self.empty = new(peers: {})

      def peer(name) = peers[name.to_s] || Peer.empty

      def to_h = { "peers" => peers.transform_values(&:to_h) }

      def self.from_h(data)
        peers = data.is_a?(Hash) && data["peers"].is_a?(Hash) ? data["peers"] : {}
        new(peers: peers.select { |name, _| name.is_a?(String) }.transform_values { |value| Peer.from_h(value) })
      end
    end

    class << self
      def path(session_id, state_dir: nil)
        File.join(SessionPaths.session_dir(session_id, state_dir: state_dir || SessionPaths.default_state_dir), FILE)
      end

      # The file as it is now; an absent or broken one is empty.
      # @return [Book]
      def read(session_id, state_dir: nil)
        file = path(session_id, state_dir: state_dir)
        return Book.empty unless File.file?(file)

        Book.from_h(JSON.parse(File.read(file)))
      rescue JSON::ParserError, SystemCallError, EncodingError
        Book.empty
      end

      # @return [Integer] the last serial the worker took from +peer+ (0: none)
      def taken(session_id, peer, state_dir: nil) = read(session_id, state_dir: state_dir).peer(peer).taken

      # @return [Receipt, nil]
      def receipt(session_id, peer, serial, state_dir: nil)
        read(session_id, state_dir: state_dir).peer(peer).receipt(serial)
      end
    end
  end
end
