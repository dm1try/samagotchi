# frozen_string_literal: true

require "socket"
require_relative "../session_access"
require_relative "../session_access/remote"
require_relative "attach_launcher"
require_relative "remote_link"

module Samagotchi
  class TerminalUI
    # AttachLauncher.run's connector for a session on another machine: POST
    # …/wake through that machine's chi web (the live worker, else one
    # started there) and the RemoteLink the attached loop runs on. Its
    # failures are AttachLauncher::Error, in the words chi web sent (the
    # exceptions' own: one condition, one message).
    class RemoteConnector
      # @param remote [SessionAccess::Remote]
      # @param session_id [String] resolved there already
      # @param hostname [String] this machine's, for #client_id
      def initialize(remote, session_id:, hostname: Socket.gethostname)
        @remote = remote
        @session_id = session_id
        @hostname = hostname
      end

      # @return [RemoteLink]
      # @raise [AttachLauncher::Error]
      def connect
        woke = @remote.attach_wake(@session_id, wait: AttachLauncher::BRIDGE_WAIT)
        RemoteLink.new(remote: @remote, session_id: @session_id, woke: woke)
      rescue SessionManager::OwnedByTUI, SessionAccess::Refused, SessionAccess::RemoteFailed, ArgumentError => e
        raise AttachLauncher::Error, e.message
      end

      # tui:PID@HOST (P4-D6): an interactive, human client for the UIs
      # there (ClientId), with the machine it types on (its short name).
      def self.client_id(hostname = Socket.gethostname) = "tui:#{Process.pid}@#{hostname.to_s.split(".").first}"

      def client_id = RemoteConnector.client_id(@hostname)
    end
  end
end
