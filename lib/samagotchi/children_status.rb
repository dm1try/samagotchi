# frozen_string_literal: true

require "time"
require_relative "session"
require_relative "archive_store"
require_relative "memory_paths"
require_relative "reply_wait"
require_relative "tools/delegate"
require_relative "tools/delegate_cursor"

module Samagotchi
  # Loaded on first use: session_manager requires terminal_ui, which
  # requires KernelLoop and so the tools (a require cycle otherwise).
  autoload :SessionManager, File.expand_path("session_manager", __dir__)

  # A parent's children as `/children` and the glance views show them: one
  # Child per child session, read from the files layer 1 already writes
  # (the session JSON, its output/ replies, the parent's delegates.json).
  # Nothing here runs git or a subprocess.
  module ChildrenStatus
    # One child of a session.
    # @!attribute state [String] waiting, running, failed, stopped, done or
    #   idle (STATES, in the order they are decided)
    # @!attribute waiting [String, nil] what it waits for: question,
    #   approval, hook or continue
    # @!attribute delegate [Boolean] a `delegate` child; false for a fork
    # @!attribute branch [String, nil] the branch checked out in its folder
    #   (a short sha when detached); nil outside git
    # @!attribute last_reply [String, nil] the first line of its newest reply
    # @!attribute reported [Boolean] the parent was already given that reply
    #   (a delegate report or a wait); false when there is none
    Child = Data.define(:id, :short_id, :title, :state, :waiting, :live, :delegate, :cwd, :branch,
                        :last_reply, :last_reply_at, :reported, :updated_at, :archived)

    # The glance views' numbers: children running, waiting for an answer,
    # and with a reply the parent wasn't given yet.
    Counts = Data.define(:running, :waiting, :unreported) do
      def self.none = new(running: 0, waiting: 0, unreported: 0)
    end

    STATES = %w[waiting running failed stopped done idle].freeze

    module_function

    # Every child of +parent_id+, newest first: delegates and forks (a fork
    # is delegate: false), archived ones only with +include_archived+. Scans
    # every session (SessionManager.children_of): for on-demand use.
    # @return [Array<Child>]
    def of(parent_id, state_dir:, include_archived: false)
      cursors = Tools::DelegateCursors.read(parent_id, state_dir: state_dir)
      SessionManager.children_of(parent_id, state_dir: state_dir).filter_map do |row|
        next if row[:archived] && !include_archived

        session = load(row[:id], state_dir: state_dir)
        session && child(session, row, cursors, state_dir: state_dir)
      end
    end

    # The cheap path for the glance views: only the children in the
    # parent's delegates.json (one Session.load and an owner check each, no
    # scan). Its keys can also name a fork the model passed to delegate
    # session: or a deleted child: only live delegates of this parent count,
    # archived ones don't.
    # @return [Counts]
    def counts(parent_id, state_dir:)
      cursors = Tools::DelegateCursors.read(parent_id, state_dir: state_dir)
      children = cursors.keys.filter_map do |id|
        session = load(id, state_dir: state_dir)
        next unless session&.delegate? && session.parent_id == parent_id
        next if ArchiveStore.archived?(Session.session_dir(id, state_dir: state_dir))

        child(session, summary_of(session, state_dir: state_dir), cursors, state_dir: state_dir)
      end
      Counts.new(running: children.count { |c| c.state == "running" },
                 waiting: children.count { |c| c.state == "waiting" },
                 unreported: children.count { |c| c.last_reply && !c.reported })
    end

    # @param row [Hash] a children_of row, or summary_of's keys
    # @param cursors [Hash] the parent's delegates.json
    def child(session, row, cursors, state_dir:)
      reply = ReplyWait.newest_reply(session.id, state_dir: state_dir)
      cursor = Tools::DelegateCursors.get_from(cursors, session.id)
      Child.new(id: session.id, short_id: session.id[0, 8], title: row[:preview].to_s,
                state: state_of(session, row, reply), waiting: row[:waiting], live: !!row[:live],
                delegate: session.delegate?, cwd: session.working_directory, branch: branch(session.working_directory),
                last_reply: reply && first_line(session.id, reply, state_dir: state_dir),
                last_reply_at: reply && reply_time(reply), reported: !reply.nil? && cursor.reply_file == reply,
                updated_at: session.updated_at, archived: !!row[:archived])
    end
    private_class_method :child

    def state_of(session, row, reply)
      return "waiting" if row[:waiting]
      return "running" if Tools::Delegate.running?(row)
      return "stopped" if session.status == Session::STATUS_STOPPED

      outcome = session.last_turn.is_a?(Hash) ? session.last_turn["outcome"] : nil
      return "failed" if session.status == Session::STATUS_ERROR || outcome == "failed"
      return "done" if outcome == "completed" && reply

      "idle"
    end
    private_class_method :state_of

    # The keys of a children_of row that state_of and child read, for a
    # session counts loaded itself.
    def summary_of(session, state_dir:)
      live = SessionManager.worker_live?(session.id, state_dir: state_dir)
      { live: live, busy: live && session.status == Session::STATUS_RUNNING, status: session.status,
        updated_at: session.updated_at, waiting: session.waiting_question(live: live)&.dig(:kind),
        preview: session.last_prompt.to_s }
    end
    private_class_method :summary_of

    # The branch from the folder's own HEAD file (a linked worktree's is
    # under .git/worktrees/<name>), read without git.
    # @return [String, nil]
    def branch(cwd)
      dir = MemoryPaths.git_dir(cwd.to_s)
      head = dir && File.read(File.join(dir, "HEAD"), 512).strip
      return nil if head.nil? || head.empty?

      head.start_with?("ref:") ? head.delete_prefix("ref:").strip.delete_prefix("refs/heads/") : head[0, 8]
    rescue SystemCallError
      nil
    end
    private_class_method :branch

    def first_line(id, file, state_dir:)
      text = File.read(File.join(ReplyWait.reply_dir(id, state_dir: state_dir), file), 4096)
      text.each_line.map(&:strip).find { |line| !line.empty? }.to_s
    rescue SystemCallError
      nil
    end
    private_class_method :first_line

    # Reply files are named by the local time they were written
    # (SessionInbox.write_output, %Y%m%d%H%M%S then nanoseconds).
    # @return [Time, nil] nil for a name that isn't one
    def reply_time(file)
      Time.strptime(File.basename(file, ".txt")[0, 14], "%Y%m%d%H%M%S")
    rescue ArgumentError, TypeError
      nil
    end
    private_class_method :reply_time

    def load(id, state_dir:)
      return nil unless Session.exist?(id, state_dir: state_dir)

      Session.load(id, state_dir: state_dir)
    rescue ArgumentError
      nil
    end
    private_class_method :load
  end
end
