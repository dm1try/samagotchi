# frozen_string_literal: true

require_relative "../session"
require_relative "peers"
require_relative "delegate"
require_relative "delegate_wait"

module Samagotchi
  # Loaded on first use: session_manager requires terminal_ui, which
  # requires KernelLoop and so these tools (a require cycle otherwise).
  autoload :SessionManager, File.expand_path("../session_manager", __dir__)

  module Tools
    # Wait for a delegated session's next reply: the one named, or this
    # session's newest running child.
    class DelegateResult
      NAME = "delegate_result"

      def self.name = NAME

      # @param session [String, nil] a child's id or prefix
      # @param timeout [Integer, String, nil] seconds (default DelegateWait::TIMEOUT_DEFAULT)
      # @param peers [Peers, nil]
      def self.call(_content = nil, session: nil, timeout: nil, peers: nil)
        return "Error: this session's id is not known here" unless peers&.session_id

        sd = peers.state_dir || Session.default_state_dir
        child_id = if session.to_s.strip.empty?
                     newest_running_child(peers.session_id, state_dir: sd) ||
                       (return "No running delegate; list_sessions shows finished ones.")
                   else
                     id = Session.resolve_id(session.to_s.strip, state_dir: sd)
                     child = Session.load(id, state_dir: sd)
                     unless child.parent_id == peers.session_id
                       return "Error: #{id[0, 8]} is not a delegate of this session (list_sessions marks them child)"
                     end

                     id
                   end
        DelegateWait.call(child_id, peers: peers, timeout: Delegate.parse_timeout(timeout))
      rescue Session::AmbiguousId => e
        "Error: #{e.message}"
      rescue ArgumentError
        "Error: no session #{session.to_s.strip} (list_sessions shows them)"
      end

      def self.newest_running_child(parent_id, state_dir:)
        SessionManager.children_of(parent_id, state_dir: state_dir).find { |s| s[:busy] }&.fetch(:id)
      end
      private_class_method :newest_running_child
    end
  end
end
