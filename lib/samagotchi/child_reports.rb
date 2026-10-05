# frozen_string_literal: true

require "fileutils"
require_relative "session"
require_relative "session_inbox"
require_relative "reply_wait"
require_relative "steer"
require_relative "log"
require_relative "config"
require_relative "tools/delegate_wait"
require_relative "tools/delegate_cursor"

module Samagotchi
  # Loaded on first use: session_manager requires terminal_ui, which
  # requires KernelLoop and so the tools (a require cycle otherwise).
  autoload :SessionManager, File.expand_path("session_manager", __dir__)

  # A delegate child's news reaching its parent by itself (the delegate
  # tool's wait: false). The child rings (ChildRing): a small file in the
  # parent's children/ dir. The parent's worker reads the rings
  # (ChildReports) and asks each child what happened, as delegate_result
  # would, and hands the model a report: mid-turn at the next iteration
  # boundary, or in a turn of its own when the parent was idle (Worker).
  # The rings stay on disk until the turn that took them is kept, so a
  # worker that exits, restarts or crashes meanwhile loses nothing.
  module ChildRing
    MODE_KEY = "session.delegate_reports"
    MODES = %w[wake queue off].freeze
    # Turns an idle parent runs for reports in a row with no human input.
    MAX_WAKES_KEY = "session.max_wakes"
    MAX_WAKES_DEFAULT = 10

    module_function

    # wake: an idle parent runs a turn for a report; queue: reports wait
    # for its next turn; off: no rings at all.
    def mode
      value = Config.get(MODE_KEY).to_s
      MODES.include?(value) ? value : "wake"
    rescue StandardError
      "wake"
    end

    # Ring +child+'s parent; best effort (a failure is logged, never
    # raised). A parent with no worker is woken on a thread
    # (SessionManager.wake_for_report decides whether it may be).
    # @param child [Session] a delegate child
    # @param why [String] "turn_end", "question" or "crash"
    # @param wake [#call, nil] (parent id) wakes a parent with no worker;
    #   nil: SessionManager.wake_for_report on a thread
    # @return [String, nil] the ring file, nil when none was written
    def ring(child, why:, state_dir:, wake: nil)
      return nil if mode == "off"
      return nil unless child&.delegate? && child.parent_id
      # A deleted parent gets no orphan dir.
      return nil unless Session.exist?(child.parent_id, state_dir: state_dir)

      parent_dir = Session.session_dir(child.parent_id, state_dir: state_dir)
      path = SessionInbox.write_ring(parent_dir, child_id: child.id, why: why)
      Log.info(:worker, "delegate_rang", parent: child.parent_id[0, 8], why: why)
      wake_parent(child.parent_id, state_dir: state_dir, wake: wake) if mode == "wake"
      path
    rescue StandardError => e
      Log.warn(:worker, "delegate_ring_failed", parent: child&.parent_id.to_s[0, 8], error: e.class.name, msg: e.message)
      nil
    end

    # A live parent worker sees the ring on its next pass; one with no
    # worker is woken.
    def wake_parent(parent_id, state_dir:, wake:)
      return if SessionManager.session_owner(parent_id, state_dir: state_dir)

      if wake
        wake.call(parent_id)
      else
        Thread.new do
          SessionManager.wake_for_report(parent_id, state_dir: state_dir)
        rescue StandardError => e
          Log.warn(:worker, "delegate_wake_failed", parent: parent_id[0, 8], error: e.class.name, msg: e.message)
        end
      end
    end
  end

  # The parent's side: reads the rings in its children/ dir and turns them
  # into reports for its model. One per worker; the turn thread and the
  # loop thread both call it (never at once: worker turns run on the loop
  # thread, the drain inside them).
  #
  # A turn takes reports (#take, at each boundary) and the worker settles
  # them as the turn ends: #commit when it is kept (completed or canceled):
  # the cursors move on (DelegateCursors) and the rings go; #release when it
  # failed: the next turn reads the same rings again.
  class ChildReports
    SOURCE = Steer::DELEGATE_REPORT
    CLIENT_PREFIX = Steer::CHILD_CLIENT_PREFIX

    # A report for the model: the text delegate_result would return
    # (DelegateWait.finish, its report variant), the cursor it moves the child to,
    # and the cursor it was read from (a commit after the model moved it
    # itself, with delegate_result, leaves it alone).
    Report = Data.define(:child_id, :text, :before, :after, :rings) do
      def line(mark: nil) = Steer::Line.new(text: text, source: ChildReports::SOURCE, mark: mark)
      def origin = { client_id: "#{ChildReports::CLIENT_PREFIX}#{child_id[0, 8]}" }
    end

    def initialize(session_id:, state_dir:)
      @session_id = session_id
      @state_dir = state_dir
      @session_dir = Session.session_dir(session_id, state_dir: state_dir)
      # child id → the Report this turn took for it (rings merged).
      @taken = {}
    end

    # Whether a ring this turn hasn't taken waits (the idle loop's check).
    def waiting?
      return false if ChildRing.mode == "off"

      taken = taken_rings
      SessionInbox.find_ring_files(@session_dir).any? { |file| !taken.include?(file) }
    end

    # The reports for rings this turn hasn't taken yet, recorded as taken.
    # A ring that turns out to say nothing new (the reply was already given,
    # an approval the user answers on the child's card) is deleted.
    # @return [Array<Report>]
    def take
      return [] if ChildRing.mode == "off"

      taken = taken_rings
      fresh = SessionInbox.find_ring_files(@session_dir).reject { |file| taken.include?(file) }
      by_child = fresh.group_by { |file| SessionInbox.read_ring(file)&.dig(:child_id) }
      by_child.filter_map do |child_id, rings|
        report = child_id && report_for(child_id, rings)
        unless report
          delete_rings(rings)
          next
        end

        @taken[child_id] = merge_taken(@taken[child_id], report)
        report
      end
    end

    # The turn that took the reports was kept: move each child's cursor on
    # (unless something else moved it since: the model's own
    # delegate_result), then delete the rings.
    def commit
      @taken.each_value do |report|
        Tools::DelegateCursors.update(@session_id, report.child_id, state_dir: @state_dir) do |cursor|
          cursor == report.before ? report.after : cursor
        end
        delete_rings(report.rings)
      rescue StandardError => e
        Log.warn(:worker, "delegate_commit_failed", child: report.child_id[0, 8], error: e.class.name, msg: e.message)
      end
      @taken = {}
    end

    # The turn failed (rolled back): its rings stay for the next one.
    def release
      @taken = {}
    end

    private

    def taken_rings
      @taken.values.flat_map(&:rings)
    end

    # A second ring for a child taken earlier in this turn: read from where
    # the first report left the cursor, keeping the first one's +before+.
    def merge_taken(earlier, report)
      return report unless earlier

      report.with(before: earlier.before, rings: earlier.rings + report.rings)
    end

    # @return [Report, nil] nil when the child has nothing to report
    def report_for(child_id, rings)
      child = Session.load(child_id, state_dir: @state_dir)
      return nil unless child.parent_id == @session_id

      before = @taken[child_id]&.after || Tools::DelegateCursors.get(@session_id, child_id, state_dir: @state_dir)
      wait = ReplyWait.call(child_id, state_dir: @state_dir, cursor: before.reply_file, baseline: before.baseline,
                                      timeout: 0)
      return nil unless reportable?(wait)

      after = before.with(reply_file: wait.status == :done ? wait.file : before.reply_file)
                    .with_baseline(ReplyWait.baseline_of(wait.session))
      text = Tools::DelegateWait.finish(wait, child_id, timeout: 0, report: true)
      Report.new(child_id: child_id, text: text, before: before, after: after, rings: rings)
    rescue ArgumentError
      nil # the child is gone
    end

    # A reply, a turn that left none, a crash, or a question the parent's
    # model decides (its own ask_user_question, the step-limit continue).
    # Approvals and hooks' questions are the user's, on the child's card.
    def reportable?(wait)
      case wait.status
      when :done, :no_reply, :error then true
      when :waiting_for_answer then [nil, "", "continue"].include?(wait.question&.dig(:kind)&.to_s)
      else false
      end
    end

    def delete_rings(rings)
      rings.each { |file| FileUtils.rm_f(file) }
    end
  end
end
