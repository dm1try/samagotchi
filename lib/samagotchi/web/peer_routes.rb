# frozen_string_literal: true

require "json"
require_relative "../peer_exchanges"
require_relative "../peer_mailbox"
require_relative "../peer_roster"
require_relative "../peer_say"
require_relative "request_body"

module Samagotchi
  module Web
    # A session's peers, mixed into App, all the owner's: the peers model
    # from the two stores without a worker (GET …/peers), one message's
    # text, Unpair, and a remote's pair and say (SessionAccess::RemotePeers:
    # the say waits here). See docs/internals/peers.md.
    module PeerRoutes
      ROUTES = [
        ["GET", %r{\A/api/sessions/([^/]+)/peers\z}, :handle_peers, :owner, :session],
        ["GET", %r{\A/api/sessions/([^/]+)/peers/([^/]+)/messages/([^/]+)\z}, :handle_peer_message, :owner, :session],
        ["DELETE", %r{\A/api/sessions/([^/]+)/peers/([^/]+)\z}, :handle_peer_unpair, :owner, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/peers/([^/]+)/pair\z}, :handle_peer_pair, :owner, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/peers/([^/]+)/say\z}, :handle_peer_say, :owner, :session]
      ].freeze

      private

      # GET /api/sessions/:id/peers → {peers: [{name, label, paired_at, from,
      # address, can_send, messages, exchanges}]}: a row per peer with a
      # mailbox folder (the peer chip's only feed). +exchanges+ joins chi's
      # sends (peer_exchanges.jsonl) with the answers: the log's (an older
      # pairing's) and the mailbox's messages (PeerExchanges.joined,
      # unchanged). +messages+: the newest (PeerRoster), with their receipts
      # and the receipt in chi's words (+words+: PeerRoster.state_words,
      # "held · peer turns"); no text anywhere.
      def handle_peers(_req, id)
        @session_class.load(id, state_dir: default_state_dir)
        entries = PeerExchanges.read(id, state_dir: default_state_dir).group_by { |entry| entry["peer"] }
        rows = {}
        entries.each_key { |name| rows[name] ||= peer_row(name) }
        PeerRoster.build(id, state_dir: default_state_dir).each do |peer|
          row = (rows[peer.name] ||= peer_row(peer.name))
          row.merge!(paired_at: peer.paired_at, from: peer.from, address: peer.address,
                     can_send: peer.paired? && !peer.address.nil?,
                     messages: peer.messages.map { |message| message.to_h.merge("words" => PeerRoster.state_words(message.receipt)) })
          (entries[peer.name] ||= []).concat(answer_entries(peer))
        end
        rows.each_value { |row| row[:exchanges] = PeerExchanges.joined(entries.fetch(row[:name], [])) }
        json_response(200, { peers: rows.values })
      end

      def peer_row(peer)
        { name: peer, label: PeerMailbox.label(peer), paired_at: nil, from: nil, address: nil, can_send: false, messages: [] }
      end

      # A peer's mailbox messages as the exchange log's answer lines.
      def answer_entries(peer)
        peer.messages.reverse.map do |row|
          { "t" => "answer", "peer" => peer.name, "re" => row.re, "summary" => row.summary, "serial" => row.serial,
            "wake" => row.wake, "at" => row.at }
        end
      end

      # GET /api/sessions/:id/peers/:name/messages/:serial → the message
      # (its text) and its receipt; 404 no_message.
      def handle_peer_message(req, id, name, serial)
        @session_class.load(id, state_dir: default_state_dir)
        return invalid_peer(name) unless PeerMailbox.valid_name?(name)

        box = req.GET["box"].to_s
        expected = PeerReceipts.read(id, state_dir: default_state_dir).peer(name).box
        return error_response(409, "wrong_box", "this message belongs to another session") if !box.empty? && expected != box

        message = PeerMailbox.message(id, name, serial, state_dir: default_state_dir)
        return error_response(404, "no_message", "no message #{serial.to_s[0, 20]} from #{name}") unless message

        receipt = PeerReceipts.receipt(id, name, message.serial, state_dir: default_state_dir)
        json_response(200, message.to_h.merge("receipt" => receipt&.to_h))
      end

      # DELETE /api/sessions/:id/peers/:name (Unpair) → {unpaired: whether
      # there was a pairing}; the messages stay.
      def handle_peer_unpair(_req, id, name)
        @session_class.load(id, state_dir: default_state_dir)
        return invalid_peer(name) unless PeerMailbox.valid_name?(name)

        json_response(200, { unpaired: session_access.peer_unpair(id, name) })
      end

      # POST /api/sessions/:id/peers/:name/pair {address, from} → 200
      # {status: "paired", link}; 409 {status: continued (next_id) |
      # old_worker, detail}.
      def handle_peer_pair(req, id, name)
        body = body_hash(req, RequestBody::CONTEXT_PUSH_BODY_LIMIT) or return error_response(400, "invalid_json", "invalid JSON body")
        return invalid_peer(name) unless PeerMailbox.valid_name?(name)

        address, from = body.values_at("address", "from")
        unless [address, from].all? { |value| value.nil? || value.is_a?(String) }
          return error_response(400, "invalid_fields", "address and from are strings")
        end

        paired = session_access.peer_pair(id, name, address: address, from: from)
        return json_response(200, { status: "paired", link: paired.link.to_h }) if paired.status == :paired

        json_response(409, { status: paired.status.to_s, next_id: paired.next_id, detail: paired.refusal }.compact)
      end

      # POST /api/sessions/:id/peers/:name/say {text, summary, wake, re,
      # wait} → 200 PeerSay (and its line) once the receipt came or the
      # wait (at most PeerSay::WAIT_MAX) ran out; 409 a refused say, the
      # same shape; 400 a bad name, text or wait.
      def handle_peer_say(req, id, name)
        body = body_hash(req, RequestBody::CONTEXT_PUSH_BODY_LIMIT) or return error_response(400, "invalid_json", "invalid JSON body")
        return invalid_peer(name) unless PeerMailbox.valid_name?(name)
        return error_response(400, "missing_fields", "text is required") unless body["text"].is_a?(String)

        wait = body["wait"] || 0
        unless wait.is_a?(Numeric) && wait.between?(0, PeerSay::WAIT_MAX)
          return error_response(400, "invalid_wait", "wait takes seconds from 0 to #{PeerSay::WAIT_MAX}")
        end

        said = session_access.peer_say(id, name, text: body["text"], summary: string_or_nil(body["summary"]),
                                                 wake: body["wake"] == true, re: string_or_nil(body["re"]), wait: wait)
        json_response(said.received? ? 200 : 409, said.to_h.merge("line" => said.line(name)))
      rescue PeerMailbox::Invalid => e
        error_response(400, "invalid_text", e.message)
      end

      def invalid_peer(name) = error_response(400, "invalid_peer", PeerMailbox.name_problem(name))

      def string_or_nil(value) = value.is_a?(String) ? value : nil
    end
  end
end
