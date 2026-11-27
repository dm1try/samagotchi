# frozen_string_literal: true

require_relative "peer_mailbox"
require_relative "peer_receipts"
require_relative "session_chain/successor"

module Samagotchi
  # What chi peer say tells the peer, in chi's own words: the message's
  # number, then what chi did with it (a receipt within the wait), or why it
  # can't say yet, or why the say was refused; then the peer's other
  # messages held and unread now. Built where the say ran (SessionAccess::
  # Local#peer_say: this machine, or the remote's chi web) and drawn by
  # #line, so a --remote say prints the remote's line.
  #
  # +status+: :received, or a refusal (nothing written): :gone (no such
  # session), :deleting, :continued (+next_id+), :not_paired, :old_worker
  # (a live worker without the peer mail), :full (UNTAKEN_MAX unread).
  # +serial+: the message's. +wake+: what the say saw at once, when it
  # didn't wait: :running (a turn runs), :starting, :stopped, :archived,
  # :owned (a one-turn chi run's), :start_failed, :no_turn (no turn yet),
  # :not_running (no worker, none asked), :deleting; nil when it waited.
  # +receipt+: the worker's (PeerReceipts::Receipt) within the wait, nil
  # without one. +earlier+: [[serial, reason]…] of the peer's other held
  # messages. +turns+: the wakes in a row that a held receipt's reason
  # names (peer turns or max wakes), as configured where the say ran.
  PeerSay = Data.define(:status, :serial, :wake, :receipt, :earlier, :next_id, :turns) do
    def initialize(status:, serial: nil, wake: nil, receipt: nil, earlier: [], next_id: nil, turns: nil) = super

    def received? = status == :received

    # The line for +peer+ (its name): "#12 received · woke chi".
    def line(peer)
      return PeerSay.refusal(status, peer, next_id) unless received?

      parts = ["##{serial} received", tail(peer)]
      parts << "also held: #{PeerSay.held_list(earlier)}" unless earlier.empty?
      parts.join(" · ")
    end

    def to_h
      { "status" => status.to_s, "serial" => serial, "wake" => wake&.to_s, "receipt" => receipt&.to_h,
        "earlier" => earlier, "next_id" => next_id, "turns" => turns }.compact
    end

    # The JSON a chi web answered (#to_h); nil for another shape.
    def self.from_h(data)
      return nil unless data.is_a?(Hash) && PeerSay::STATUSES.include?(data["status"].to_s)

      earlier = Array(data["earlier"]).select { |pair| pair.is_a?(Array) && pair[0].is_a?(Integer) }
                                       .map { |serial, reason| [serial, reason.to_s] }
      new(status: data["status"].to_sym, serial: (data["serial"] if data["serial"].is_a?(Integer)),
          wake: (data["wake"].to_sym if PeerSay::WAKES.include?(data["wake"].to_s)),
          receipt: PeerReceipts::Receipt.from_h(data["receipt"]), earlier: earlier,
          next_id: data["next_id"]&.to_s, turns: (data["turns"] if data["turns"].is_a?(Integer)))
    end

    # The words of a refused say, nothing written.
    def self.refusal(status, peer, next_id)
      case status
      when :gone then "no such session"
      when :deleting then "this session is being deleted"
      when :continued then "#{SessionChain::Continued.new(nil, next_id).message}: say it there"
      when :not_paired then "not paired: run the pair script"
      when :old_worker then "this session's chi is older than chi peer: restart the session (chi sessions restart)"
      when :full then "chi has #{PeerMailbox::UNTAKEN_MAX} unread messages from #{peer}"
      else status.to_s
      end
    end

    # "#10, #11 (paused)", a run of one reason at a time.
    def self.held_list(earlier)
      earlier.chunk_while { |a, b| a[1] == b[1] }.map do |run|
        "#{run.map { |serial, _| "##{serial}" }.join(", ")} (#{PeerSay::SHORT_WORDS.fetch(run.first[1], run.first[1].tr("_", " "))})"
      end.join(", ")
    end

    private

    def tail(peer)
      return PeerSay::AT_ONCE.fetch(wake) if wake
      return "no answer from chi yet" unless receipt

      case receipt.state
      when "woke" then "woke chi"
      when "noted" then "noted"
      when "read" then "chi is reading it"
      when "ended" then "chi read it (#{receipt.outcome == "canceled" ? "stopped" : receipt.outcome})"
      when "held" then "held: #{held_words(receipt.reason)} · #{PeerSay::HELD_UNTIL.fetch(receipt.reason, PeerSay::HELD_UNTIL["paused"])}"
      else "refused: #{refused_words(receipt.reason, peer)}"
      end
    end

    def held_words(reason)
      count = turns || 0
      case reason
      when "peer_turns" then "#{count} peer turn#{"s" unless count == 1} in a row (#{PeerSay::PEER_TURNS_KEY})"
      when "max_wakes" then "#{count} wake turn#{"s" unless count == 1} in a row (session.max_wakes)"
      else PeerSay::HELD_WORDS.fetch(reason, reason.to_s.tr("_", " "))
      end
    end

    def refused_words(reason, peer)
      return "no bundle in that session declares peer #{peer}" if reason == "undeclared"

      "chi couldn't read that message file"
    end
  end

  # The longest a say waits for chi's answer (--wait).
  PeerSay::WAIT_MAX = 30
  # Between two looks at the receipts while it waits.
  PeerSay::POLL_SECONDS = 0.25

  # What chi peer pair did: :paired (+link+), or a refusal (nothing
  # written): :continued (+next_id+), :old_worker (a live worker without
  # the peer mail).
  PeerPaired = Data.define(:status, :link, :next_id) do
    def initialize(status:, link: nil, next_id: nil) = super

    def refusal
      case status
      when :continued then "#{SessionChain::Continued.new(nil, next_id).message}: pair with it"
      when :old_worker then PeerSay.refusal(:old_worker, nil, nil)
      end
    end
  end

  PeerSay::STATUSES = %w[received gone deleting continued not_paired old_worker full].freeze
  PeerSay::WAKES = %w[running starting stopped archived owned start_failed no_turn not_running deleting].freeze
  # The setting a peer_turns hold names (WorkerWakes::PEER_TURNS_KEY: the
  # CLI loads no worker).
  PeerSay::PEER_TURNS_KEY = "peer.turns"
  # What the say says at once, without waiting for a receipt.
  PeerSay::AT_ONCE = {
    running: "chi is in a turn: it reads this when the turn ends",
    starting: "chi is starting",
    stopped: "chi is stopped: it reads this at its next start",
    archived: "this session is archived: it reads this if you reopen it",
    owned: "a one-turn chi run has this session: it reads this at its next start",
    start_failed: "chi's worker isn't running and couldn't be started from here: it reads this at its next start",
    no_turn: "chi hasn't had a turn yet: it reads this with its first",
    not_running: "chi's worker isn't running: it reads this at its next start",
    deleting: "this session is being deleted"
  }.freeze
  # A held receipt's reason in a sentence (peer_turns and max_wakes count).
  PeerSay::HELD_WORDS = {
    "off" => "#{PeerSay::PEER_TURNS_KEY} is 0",
    "paused" => "wakes are paused after a failed wake turn",
    "continue" => "a continue offer waits for the user",
    "queued" => "a message is queued ahead of it",
    "exit" => "chi is exiting",
    "leaving" => "chi's worker is leaving",
    "before_turn" => "a turn is starting"
  }.freeze
  # And until when it waits.
  PeerSay::HELD_UNTIL = {
    "off" => "waits for the user's next message", "paused" => "waits for the user's next message",
    "continue" => "waits for the user's next message", "max_wakes" => "waits for the user's next message",
    "peer_turns" => "waits for the user's next message",
    "queued" => "chi reads it in its next turn", "before_turn" => "chi reads it in that turn",
    "exit" => "it reads this at its next start", "leaving" => "it reads this at its next start"
  }.freeze
  # A reason in a few words (the "also held" list, the chip's).
  PeerSay::SHORT_WORDS = {
    "off" => "off", "paused" => "paused", "continue" => "continue offer", "max_wakes" => "max wakes",
    "peer_turns" => "peer turns", "queued" => "queued", "exit" => "exit", "leaving" => "leaving",
    "before_turn" => "before a turn"
  }.freeze
end
