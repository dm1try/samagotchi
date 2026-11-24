# frozen_string_literal: true

require_relative "../session_access"
require_relative "../peer_mailbox"
require_relative "../peer_roster"
require_relative "../peer_say"

module Samagotchi
  module SessionAccess
    # SessionAccess::Remote's chi peer: chi web's …/peers routes, the twins
    # of Local#peer_pair, #peer_unpair, #peer_list and #peer_say. Uses the
    # Remote's request, session_path, raise_refusal and entry.
    module RemotePeers
      # How long a say's request may take beyond its wait: the server
      # starts a worker first.
      PEER_SAY_SLACK = 30

      # @return [PeerPaired]
      def peer_pair(id, peer, address:, from:)
        PeerMailbox.check_name!(peer)
        reply = peer_request(:post, "#{session_path(id)}/peers/#{peer}/pair", body: { address: address, from: from })
        case reply.status
        when 200
          link = PeerMailbox::PeerLink.from_h(reply.json["link"]) or raise RemoteFailed, "#{@entry.label}: no link in its answer"
          PeerPaired.new(status: :paired, link: link)
        when 409
          status = %w[continued old_worker].find { |known| known == reply.json["status"] } or raise_refusal(reply)
          PeerPaired.new(status: status.to_sym, next_id: reply.json["next_id"]&.to_s)
        else raise_refusal(reply)
        end
      end

      # @return [Boolean] whether there was a pairing
      def peer_unpair(id, peer)
        PeerMailbox.check_name!(peer)
        reply = peer_request(:delete, "#{session_path(id)}/peers/#{peer}")
        raise_refusal(reply) unless reply.status == 200

        reply.json["unpaired"] == true
      end

      # @return [Array<PeerRoster::Peer>]
      def peer_list(id)
        reply = peer_request(:get, "#{session_path(id)}/peers")
        raise_refusal(reply) unless reply.status == 200

        Array(reply.json["peers"]).filter_map { |row| PeerRoster::Peer.from_h(row) }
      end

      # The say, and its wait, on the remote's chi web (POST …/say, wait:):
      # its PeerSay, so the line is the remote's.
      # @return [PeerSay]
      def peer_say(id, peer, text:, summary:, wake:, re:, wait: 0, **)
        PeerMailbox.check_name!(peer)
        reply = peer_request(:post, "#{session_path(id)}/peers/#{peer}/say",
                             body: { text: text, summary: summary, wake: wake, re: re, wait: wait },
                             read_timeout: wait.to_f + PEER_SAY_SLACK)
        return PeerSay.new(status: :gone) if reply.status == 404 && reply.error == "not_found"
        raise BadRequest.new(reply.json["detail"].to_s, code: reply.error) if reply.status == 400

        said = PeerSay.from_h(reply.json) if [200, 409].include?(reply.status)
        said || raise_refusal(reply)
      end

      private

      # A …/peers request; an older chi web (no such route) says it has no chi peer.
      def peer_request(method, path, **)
        request(method, path, **)
      rescue RemoteTooOld
        raise RemoteTooOld, "chi web on #{@entry.name} is older: it has no chi peer (update chi there: chi update)"
      end
    end
  end
end
