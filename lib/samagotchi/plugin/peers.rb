# frozen_string_literal: true

require_relative "../peer_mailbox"
require_relative "../peer_receipts"
require_relative "../session"

module Samagotchi
  module Plugin
    # ctx.peers (docs/plugins.md, Peers): what a peer bundle reads of its
    # peer's side of the session (PeerMailbox): the pairing (where its
    # sends go) and the peer's messages. Read only: a peer pairs and says
    # through `chi peer` (its pair script, its skill); the worker takes the
    # messages (WorkerInbound#absorb_mail). Plugin::Peer is its caller.
    class Peers
      # @param host [Host] session_id and state_dir
      # @param continues [#call] the id of the session this one continues, or nil
      def initialize(host, continues:)
        @host = host
        @continues = continues
      end

      # This session's pairing with +name+ ("claude").
      # @return [PeerMailbox::PeerLink, nil] nil when not paired (or no session yet)
      def link(name) = read_link(@host.session_id.call, name)

      # The pairing a continue left with the previous link: a continue
      # doesn't move it, so the peer is told the new id (Plugin::Peer
      # #tell_moved) and pairs again.
      # @return [PeerMailbox::PeerLink, nil] nil when this session continues none, or it wasn't paired
      def left_behind(name) = read_link(@continues.call, name)

      # +name+'s message +serial+ (its text, summary, wake, re, at).
      # @return [PeerMailbox::PeerMessage, nil] nil when it isn't there (trimmed) or isn't good
      def message(name, serial, box: nil)
        id = @host.session_id.call or return nil
        expected = @host.session_id.call && PeerReceipts.read(id, state_dir: state_dir).peer(name.to_s).box
        return nil if box && expected != box

        PeerMailbox.message(id, name.to_s, serial, state_dir: state_dir)
      rescue PeerMailbox::Invalid, SessionPaths::InvalidId
        nil
      end

      # +name+'s newest message that is still in the mailbox.
      # @return [PeerMailbox::PeerMessage, nil]
      def last_message(name)
        id = @host.session_id.call or return nil
        PeerMailbox.serials(id, name.to_s, state_dir: state_dir).reverse_each do |serial|
          found = PeerMailbox.message(id, name.to_s, serial, state_dir: state_dir)
          return found if found
        end
        nil
      rescue PeerMailbox::Invalid, SessionPaths::InvalidId
        nil
      end

      private

      def state_dir = @host.state_dir&.call || Session.default_state_dir

      def read_link(id, name)
        return nil unless id

        PeerMailbox.link(id, name.to_s, state_dir: state_dir)
      rescue PeerMailbox::Invalid, SessionPaths::InvalidId
        nil
      end
    end
  end
end
