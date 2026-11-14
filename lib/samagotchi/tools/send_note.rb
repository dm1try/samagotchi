# frozen_string_literal: true

require_relative "../session"
require_relative "../context_note"
require_relative "../session_inbox"
require_relative "../note_delivery"
require_relative "peers"
require_relative "../tool_names"

module Samagotchi
  module Tools
    # Tell another chi session something: a context note it sees on its next
    # turn as background from this session. It never starts a turn there.
    class SendNote
      NAME = ToolNames::SendNote::NAME

      def self.name = NAME

      # @param content [String] the note
      # @param session [String] the target's id or a unique prefix
      # @param peers [Peers, nil]
      def self.call(content, session: nil, peers: nil)
        return "Error: this session's id is not known here" unless peers&.session_id
        return "Error: give the target session's id (list_sessions shows them)" if session.to_s.strip.empty?

        id = Session.resolve!(session.to_s.strip, state_dir: peers.state_dir)
        Session.load(id, state_dir: peers.state_dir)
        return "Error: #{id[0, 8]} is this session; send_note is for other sessions" if id == peers.session_id

        # A link continued into this one: the note would come back here.
        head = SessionInbox::Head.resolve(:note, id, state_dir: peers.state_dir)
        return "Error: #{id[0, 8]} was continued into this session; send_note is for other sessions" if head.id == peers.session_id

        result = NoteDelivery.deliver(id, text: content, source: "session", from_session: peers.session_id,
                                          from_cwd: peers.cwd, state_dir: peers.state_dir, resolved: head)
        target = result.id[0, 8]
        return "Error: session #{target}: #{result.refusal}" if result.scratch
        return "Error: session #{target} is #{OwnerLock::TUI_BUSY}, which can't take notes" unless result.delivered?

        where = result.status == :queued ? "its worker adds it before its next turn" : "it has no worker now, so it waits for its next start"
        via = result.continued? ? " (#{id[0, 8]} was continued: #{target} is its chain's newest link)" : ""
        "Queued a note for session #{target}#{via}: #{where}. It does not start a turn there."
      rescue Session::NotFound => e
        "Error: #{e.message} (list_sessions shows them)"
      rescue ArgumentError => e # AmbiguousId, SessionInbox::NoteRejected, a file that won't load
        "Error: #{e.message}"
      end
    end
  end
end
