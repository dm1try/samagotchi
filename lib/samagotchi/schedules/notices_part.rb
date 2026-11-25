# frozen_string_literal: true

require "fileutils"
require "time"

module Samagotchi
  class Schedules
    # The disabled notice (docs/scheduling.md): a recurring schedule a ticker
    # turned off by its budget carries {kind:, count:, reason:, at:} in
    # `disabled_notice` until a chi web claims it and pushes it. Set by
    # #skipped / #failed, whatever ran them (a cron tick, a run-now, chi
    # web's own tick); claimed by SessionHub#publish_disabled.
    module NoticesPart
      # The disabled notices whatever ticker set them (#skipped / #failed: a
      # cron `chi schedule tick`, a `run-now`, chi web's own tick), each cleared
      # here and returned once, for chi web's hub to push (SessionHub
      # #publish_disabled). A lock-free read first: with no notice (the usual
      # case) nothing is locked or written. Then the lock, non-blocking: a tick
      # can hold it for seconds through its busy checks, and the hub's scan must
      # not wait; [] then, and the next pass retries. The notices are cleared
      # before the hub emits them (at most once): the Notifier dedupes only
      # within its own process, so two chi webs on one state dir must not both
      # get the same notice; a crash between the clear and the push loses one
      # push, never sends two. An entry enabled again since (an older chi's
      # `enable` keeps the notice) and a notice older than NOTICE_MAX_AGE are
      # cleared without being returned.
      # @param now [Time]
      # @param on_lock_held [#call, nil] called when there were notices but
      #   the lock was held (the [] then is "not now", not "none": the hub
      #   retries at its next scan, SessionHub#claim_disabled_if_due)
      # @return [Array<Hash>] {id:, title:, kind:, count:, reason:, session_id:, at:}
      # @raise [Corrupt] the file stopped being readable JSON
      def claim_disabled_notices(now: @clock.call, on_lock_held: nil)
        return [] unless read.entries.any? { |entry| entry.is_a?(Entry) && entry.disabled_notice }

        claimed = []
        FileUtils.mkdir_p(@store_dir)
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          unless lock.flock(File::LOCK_EX | File::LOCK_NB)
            on_lock_held&.call
            return []
          end

          file = read(strict: true)
          links = nil
          cleared = false
          file.entries.each_with_index do |entry, position|
            next unless entry.is_a?(Entry) && entry.disabled_notice

            notice = entry.disabled_notice
            file.entries[position] = entry.with(disabled_notice: nil)
            cleared = true
            next if entry.enabled || notice_stale?(notice, now)

            links ||= links_now
            claimed << { id: entry.id, title: entry.title, kind: notice[:kind], count: notice[:count],
                         reason: notice[:reason], session_id: target_of(entry, links).first || entry.head,
                         at: notice[:at] }
          end
          write(file: file) if cleared
        end
        claimed
      end

      private

      # The skips and failures that turned off a recurring entry that was on when
      # the pass began (+before+), as the file has it now: one diff covers every
      # path that records one. A `date` one-off is spent, not disabled; an entry
      # off within budget is an owner's `chi schedule disable`. The same rule
      # (#budget_turned_off?) sets the entry's disabled notice; this cannot read
      # that notice back, since a chi web may have claimed it by now.
      def mark_disabled(outcomes, before, links: nil)
        status_by_id = outcomes.select { |outcome| %w[skipped failed].include?(outcome.status) }
                               .to_h { |outcome| [outcome.id, outcome.status] }
        on = before.select { |entry| status_by_id.key?(entry.id) }.to_h { |entry| [entry.id, entry] }
        return outcomes if on.empty?

        off = read.entries.grep(Entry).select do |entry|
          on.key?(entry.id) && budget_turned_off?(on[entry.id], entry, status_by_id[entry.id])
        end
        links ||= links_now unless off.empty?
        off.each do |entry|
          index = outcomes.rindex { |outcome| outcome.id == entry.id && %w[skipped failed].include?(outcome.status) }
          session_id = target_of(entry, links).first || entry.head
          outcomes[index] = outcomes[index].with(disabled: true, entry: entry, session_id: session_id)
        end
        outcomes
      end

      # "This skip or failure turned the entry off by its budget": +before+ was a
      # recurring entry that was on, +after+ is off with the +status+'s counter
      # at its budget. A `date` one-off is spent, not disabled; an entry off
      # within budget is an owner's disable. #skipped / #failed set the
      # disabled notice on it, #mark_disabled the CLI's `(disabled)`.
      def budget_turned_off?(before, after, status)
        return false unless before.enabled && before.recurrence[:kind] != "date" && !after.enabled

        case status
        when "skipped" then after.skips >= after.max_skips
        when "failed" then after.failures >= after.max_failures
        else false
        end
      end

      # The notice a chi web pushes for a budget turn-off (#claim_disabled_notices),
      # when this +status+ call turned +before+ off; +after+ unchanged otherwise.
      def with_disabled_notice(before, after, status, reason, now)
        return after unless budget_turned_off?(before, after, status)

        count = status == "skipped" ? after.skips : after.failures
        after.with(disabled_notice: { kind: status, count: count, reason: reason, at: now.utc.iso8601 })
      end

      def notice_stale?(notice, now)
        Time.iso8601(notice[:at].to_s) + NOTICE_MAX_AGE < now
      rescue ArgumentError
        true
      end
    end
  end
end
