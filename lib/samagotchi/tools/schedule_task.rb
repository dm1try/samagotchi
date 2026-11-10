# frozen_string_literal: true

module Samagotchi
  module Tools
    # Register a durable schedule for this session (docs/scheduling.md): a
    # prompt that runs on a clock, out of the worker's memory, until it is
    # cancelled. The default mode is `chain`: each firing is the next link of
    # this session's chain, so a long-running routine keeps a fresh context.
    # Unlike register_reminder, a schedule needs no live worker — a tick run by
    # cron (or chi web's hub) wakes one — and it never holds an idle worker up.
    class ScheduleTask
      NAME = "schedule_task"

      def self.name = NAME

      def self.call(content, title: nil, prompt: nil, every: nil, weekday: nil, time: nil, date: nil,
                    mode: nil, keep_links: nil, peers: nil)
        # Required here, not at the top of the file: the kit does not pay
        # for the session lifecycle until a schedule is actually used.
        require_relative "../schedules"
        return "Error: this session's id is not known here" unless peers&.session_id

        prompt = content.to_s if prompt.to_s.strip.empty?
        schedules = Schedules.new(state_dir: peers.state_dir)
        entry = schedules.add(
          target: peers.session_id, prompt: prompt, title: title,
          recurrence: Schedules.recurrence(every: every, weekday: weekday, time: time, date: date),
          mode: mode.nil? || mode.to_s.strip.empty? ? Schedules::CHAIN : mode.to_s.strip,
          keep_links: keep_links
        )
        result = "Scheduled #{entry.id}: #{entry.target_words} · #{entry.recurrence_words} · next #{entry.next_due}. " \
                 "It fires outside this worker (chi schedule tick, run by cron or chi web's hub); " \
                 "chi schedule list and cancel_schedule show and stop it."
        warning = schedules.tick_warning
        warning ? "#{result}\n#{warning}" : result
      rescue Schedules::Usage, Session::NotFound, Session::AmbiguousId => e
        "Error: #{e.message}"
      end
    end
  end
end
