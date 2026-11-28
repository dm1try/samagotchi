# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require_relative "../archive_store"
require_relative "../atomic_file"
require_relative "../log"
require_relative "../session"
require_relative "../session_inbox_delivery"

module Samagotchi
  module Web
    # A thin client's `last` (POST /api/sessions/last/ask,
    # docs/thin-clients.md "Your last session"): the session that most
    # recently got an owner's thin-client ask (an /ask, or a create that
    # answers its first turn), kept as one id in FILE beside the sessions
    # folder (as Schedules keeps its file), and the fallback when it is gone.
    # Only AskRoutes records it, and only for the owner's own lines (an
    # agent's or chi send's leave it): it is the owner's conversation.
    module LastAsk
      module_function

      # The address a thin client asks in place of an id.
      ADDRESS = "last"
      FILE = "last_ask.json"
      NOT_FOUND = "no session to ask as last: start one with POST /api/sessions"

      def path(state_dir:) = File.join(File.dirname(File.expand_path(state_dir)), FILE)

      # +session_id+ as the last one asked. Never raises: a write that
      # can't happen is logged, and the ask still answers.
      def record(session_id, state_dir:, at: Time.now)
        file = path(state_dir: state_dir)
        FileUtils.mkdir_p(File.dirname(file))
        AtomicFile.write(file, JSON.generate({ "session_id" => session_id, "at" => at.utc.iso8601(3) }), perm: 0o600)
      rescue StandardError => e
        Log.warn(:web, "last_ask_write_failed", session_id: session_id, msg: "#{e.class}: #{e.message}")
      end

      # @return [String, nil] the recorded id; nil when none, or the file
      #   is unreadable or holds no session id
      def recorded(state_dir:)
        data = JSON.parse(File.read(path(state_dir: state_dir)))
        id = data["session_id"] if data.is_a?(Hash)
        Session.valid_id?(id) ? id : nil
      rescue SystemCallError, IOError, JSON::ParserError
        nil
      end

      # The session `last` names: the recorded one while its file is there
      # and it is not archived with nothing continuing it (a continued one
      # keeps its id: the ask follows the chain to its newest link, a
      # continue in flight included); else #recent.
      # @param head [#call] id → SessionInbox::Resolved (a send's chain walk)
      # @return [String, nil] nil: no session to ask
      def target(state_dir:, head: ->(id) { SessionInbox::Head.resolve(:send, id, state_dir: state_dir) })
        id = recorded(state_dir: state_dir)
        return recent(state_dir: state_dir) unless id && Session.exist?(id, state_dir: state_dir)
        return id if head.call(id).id != id
        return id unless ArchiveStore.archived?(Session.session_dir(id, state_dir: state_dir))

        recent(state_dir: state_dir)
      rescue ArgumentError # degrade-ok: deleted while resolving: the fallback
        recent(state_dir: state_dir)
      end

      # The newest of the owner's own sessions (Session.list: archived left
      # out, updated_at desc): not a chi scratch one, a delegate, one an
      # agent drives, or a test run.
      # @return [String, nil]
      def recent(state_dir:)
        Session.list(state_dir: state_dir)
               .find { |s| !s.scratch && !s.delegate? && s.driver.nil? && !s.test_run }&.id
      end
    end
  end
end
