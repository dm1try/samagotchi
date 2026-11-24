# frozen_string_literal: true

require_relative "peer_mailbox"
require_relative "peer_receipts"
require_relative "peer_say"

module Samagotchi
  # A session's peers as chi peer ls and chi web's GET …/peers show them,
  # read from the two stores without a worker: each peer folder (paired:
  # its link.json, PeerMailbox) with its newest messages and what the
  # worker did with each (PeerReceipts). No text: GET …/peers/NAME/messages/N
  # reads one.
  module PeerRoster
    # The newest messages a peer's entry lists.
    LAST = 20

    # One message's row: the message's fields but its text, and its receipt.
    Row = Data.define(:serial, :summary, :re, :at, :wake, :receipt) do
      def to_h = { "serial" => serial, "summary" => summary, "re" => re, "at" => at, "wake" => wake,
                   "receipt" => receipt&.to_h }

      def self.from_h(data)
        return nil unless data.is_a?(Hash) && data["serial"].is_a?(Integer)

        new(serial: data["serial"], summary: data["summary"]&.to_s, re: data["re"]&.to_s, at: data["at"]&.to_s,
            wake: data["wake"] == true, receipt: PeerReceipts::Receipt.from_h(data["receipt"]))
      end
    end

    # One peer: its +name+ and +label+, the link's fields (nil: not
    # paired), the newest +messages+ (Row, newest first).
    Peer = Data.define(:name, :label, :paired_at, :from, :address, :messages) do
      def paired? = !paired_at.nil?

      def to_h = { "name" => name, "label" => label, "paired_at" => paired_at, "from" => from, "address" => address,
                   "messages" => messages.map(&:to_h) }

      def self.from_h(data)
        return nil unless data.is_a?(Hash) && PeerMailbox.valid_name?(data["name"])

        new(name: data["name"], label: PeerMailbox.label(data["name"]), paired_at: data["paired_at"]&.to_s,
            from: data["from"]&.to_s, address: data["address"]&.to_s,
            messages: Array(data["messages"]).filter_map { |row| Row.from_h(row) })
      end
    end

    module_function

    # A receipt in a few words, as the list shows it: "held · peer turns",
    # "read", "completed"; "unread" without one.
    def state_words(receipt)
      return "unread" unless receipt

      case receipt.state
      when "held" then "held · #{PeerSay::SHORT_WORDS.fetch(receipt.reason.to_s, receipt.reason.to_s.tr("_", " "))}"
      when "refused" then "refused · #{receipt.reason}"
      when "ended" then receipt.outcome == "canceled" ? "stopped" : receipt.outcome.to_s
      else receipt.state
      end
    end

    # @return [Array<Peer>] by name
    def build(session_id, state_dir: nil, last: LAST)
      book = PeerReceipts.read(session_id, state_dir: state_dir)
      PeerMailbox.peers(session_id, state_dir: state_dir).map do |name|
        link = PeerMailbox.link(session_id, name, state_dir: state_dir)
        receipts = book.peer(name)
        serials = PeerMailbox.serials(session_id, name, state_dir: state_dir).last(last).reverse
        rows = serials.filter_map do |serial|
          message = PeerMailbox.message(session_id, name, serial, state_dir: state_dir) or next
          Row.new(serial: serial, summary: message.summary, re: message.re, at: message.at, wake: message.wake,
                  receipt: receipts.receipt(serial))
        end
        Peer.new(name: name, label: PeerMailbox.label(name), paired_at: link&.paired_at, from: link&.from,
                 address: link&.address, messages: rows)
      end
    end
  end
end
