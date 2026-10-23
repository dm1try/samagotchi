# frozen_string_literal: true

require "socket"
require_relative "../session_access"
require_relative "../session_access/remote"
require_relative "../session_access/http_transport"
require_relative "../owner_lock"
require_relative "../launch_mode"
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
      # @param err [IO] where the wait for a leaving worker is said
      def initialize(remote, session_id:, hostname: Socket.gethostname, err: $stderr)
        @remote = remote
        @session_id = session_id
        @hostname = hostname
        @err = err
      end

      # A worker there still leaving (its recap on leave) is said here
      # (LaunchMode::RECAP_WAIT, as a local attach says it) and waited for
      # by the wake, whose read then allows for that wait too.
      # @return [RemoteLink]
      # @raise [AttachLauncher::Error]
      def connect
        woke = @remote.attach_wake(@session_id, wait: AttachLauncher::BRIDGE_WAIT, read_timeout: wake_read_timeout)
        RemoteLink.new(remote: @remote, session_id: @session_id, woke: woke)
      rescue SessionManager::OwnedByTUI, SessionAccess::Refused, SessionAccess::RemoteFailed, ArgumentError => e
        raise AttachLauncher::Error, e.message
      end

      # Seconds past the transport's read timeout a wake may take beyond its
      # leave and Bridge waits there.
      WAKE_READ_SLACK = 15.0

      # nil (the transport's) unless the worker there is leaving: then its
      # leave's budget left, OwnerLock::LEAVE_MARGIN, the Bridge wait and
      # some slack, at least the transport's.
      def wake_read_timeout
        state = @remote.attach_worker(@session_id)
        return nil unless state.leaving

        @err.puts(LaunchMode::RECAP_WAIT)
        budget = state.leave_seconds.to_f + OwnerLock::LEAVE_MARGIN + AttachLauncher::BRIDGE_WAIT + WAKE_READ_SLACK
        [budget, SessionAccess::HTTPTransport::READ_TIMEOUT].max
      end

      # tui:PID@HOST (P4-D6): an interactive, human client for the UIs
      # there (ClientId), with the machine it types on (its short name).
      def self.client_id(hostname = Socket.gethostname) = "tui:#{Process.pid}@#{hostname.to_s.split(".").first}"

      def client_id = RemoteConnector.client_id(@hostname)
    end
  end
end
