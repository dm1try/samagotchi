# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"
require_relative "atomic_file"
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

    # One message the worker took or refused, for #absorbed: +asked+ its
    # wake, +refused+ nil or the reason (undeclared, invalid).
    Absorbed = Data.define(:peer, :serial, :asked, :refused)

    # Receipts kept per peer (the newest); a held or noted one is never trimmed.
    KEPT = 20
    # The receipts a turn's end settles.
    OPEN = %w[woke read].freeze

    # The worker's side: the file in memory (read once), each change written
    # whole. Its loop thread alone calls it.
    def initialize(session_id:, state_dir: nil, clock: -> { Time.now })
      @session_id = session_id
      @state_dir = state_dir
      @clock = clock
      @book = self.class.read(session_id, state_dir: state_dir)
    end

    # @return [Peer]
    def peer(name) = @book.peer(name)

    # The session's box for +name+'s note ids, minted (6 random hex) and
    # written at once with its first message, so a crash before the
    # receipts can't mint another (the ids must survive to dedupe).
    # @return [String]
    def box_for(name)
      current = peer(name)
      return current.box if current.box

      update(name, current.with(box: SecureRandom.hex(3)))
      peer(name).box
    end

    # What #absorb_mail did with +batch+ (Absorbed), after the session
    # holding its notes was saved: woke (+waking+: the wake turn's id) for
    # each that asked in a batch that wakes; held (+hold+: the reason) for
    # one that asked in a batch that doesn't; noted for one that didn't ask;
    # refused with its reason. taken moves past all but an undeclared
    # peer's messages.
    def absorbed(batch, waking:, hold:)
      return if batch.empty?

      previous = @book
      at = now
      batch.group_by(&:peer).each do |name, items|
        current = peer(name)
        rows = items.map do |item|
          if item.refused
            Receipt.new(serial: item.serial, state: "refused", reason: item.refused, at: at)
          elsif item.asked && waking
            Receipt.new(serial: item.serial, state: "woke", turn: waking, at: at)
          elsif item.asked
            Receipt.new(serial: item.serial, state: "held", reason: hold.to_s, at: at)
          else
            Receipt.new(serial: item.serial, state: "noted", at: at)
          end
        end
        taken = items.reject { |item| item.refused == "undeclared" }.map(&:serial).max
        receipts = current.receipts.reject { |row| items.any? { |item| item.serial == row.serial } } + rows
        update_peer(name, current.with(taken: [current.taken, taken.to_i].max, receipts: receipts))
      end
      write
    rescue SystemCallError, IOError
      @book = previous
      raise
    end

    # A turn starts (+turn_id+): every held or noted receipt is read by it.
    def turn_started(turn_id)
      changed = change_all { |row| %w[held noted].include?(row.state) ? row.with(state: "read", reason: nil, turn: turn_id, at: now) : row }
      write if changed
    end

    # The turn +turn_id+ ended, +outcome+ (:completed, :failed, :canceled
    # or :stopped), +unmarked+: its note went back plain (#unmark_wake: a
    # failed or stopped wake that kept nothing). The receipts it woke or
    # read: ended with the outcome, or held: paused when unmarked.
    def turn_ended(turn_id, outcome:, unmarked:)
      return if turn_id.nil?

      word = outcome.to_s == "canceled" ? "stopped" : outcome.to_s
      changed = change_all do |row|
        next row unless row.turn == turn_id && OPEN.include?(row.state)

        if unmarked
          row.with(state: "held", reason: "paused", turn: nil, outcome: nil, at: now)
        else
          row.with(state: "ended", outcome: word, at: now)
        end
      end
      write if changed
    end

    # At a worker's start no turn runs: a receipt left woke or read is a
    # dead worker's turn, ended failed.
    def settle_open
      changed = change_all { |row| OPEN.include?(row.state) ? row.with(state: "ended", outcome: "failed", at: now) : row }
      write if changed
    end

    private

    def now = @clock.call.utc.iso8601(3)

    def update(name, value)
      update_peer(name, value)
      write
    end

    def update_peer(name, value)
      @book = @book.with(peers: @book.peers.merge(name.to_s => value.with(receipts: trimmed(value.receipts))))
    end

    # The newest KEPT, and every held or noted one.
    def trimmed(rows)
      keep = rows.last(KEPT)
      rows.select { |row| keep.include?(row) || %w[held noted].include?(row.state) }
    end

    # Each receipt through the block; whether any changed.
    def change_all
      changed = false
      peers = @book.peers.transform_values do |value|
        rows = value.receipts.map do |row|
          new_row = yield(row)
          changed ||= new_row != row
          new_row
        end
        value.with(receipts: rows)
      end
      @book = @book.with(peers: peers) if changed
      changed
    end

    def write = self.class.write(@session_id, @book, state_dir: @state_dir)

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

      # Replaces the file with +book+ (the worker's, on its loop thread).
      # @return [String] the path
      def write(session_id, book, state_dir: nil)
        file = path(session_id, state_dir: state_dir)
        FileUtils.mkdir_p(File.dirname(file))
        AtomicFile.write(file, "#{JSON.generate(book.to_h)}\n")
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
