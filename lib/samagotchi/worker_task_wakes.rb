# frozen_string_literal: true

require "securerandom"

require_relative "child_reports"
require_relative "kernel_loop"
require_relative "log"
require_relative "task_finish_note"
require_relative "task_watch"
require_relative "tools/task_runtime"
require_relative "worker_inbound"
require_relative "worker_wakes"

module Samagotchi
  # A worker's finish wake (docs/internals/background-tasks.md, Finish
  # wake): its TaskWatch, fed by the Engine's raw events (#observe), and
  # the TASK FINISHED notes for the tasks that finished unseen. #take
  # writes them and hands back the wake turn to run, which the Worker runs
  # (Worker#run_wake); #absorb gives them to a prompt's turn as plain notes.
  # On the loop's thread, like WorkerInbound.
  class WorkerTaskWakes
    # @return [TaskWatch]
    attr_reader :watch

    # @param wakes [WorkerWakes] the wake budget a task's wake asks
    # @param awaiting_continue [#call] whether a continue offer waits
    # @param idle [#call] nothing queued and no exit asked for: a finish
    #   may start a turn
    # @param save [#call] saves the session (a failure is the callee's to log)
    def initialize(engine:, session:, wakes:, awaiting_continue:, idle:, save:)
      @engine = engine
      @session = session
      @wakes = wakes
      @awaiting_continue = awaiting_continue
      @idle = idle
      @save = save
      @watch = TaskWatch.new
    end

    # The Engine's raw events feed the task watch (session.task_wakes not
    # off): a result that started a task or showed its end, a turn's start,
    # a user's Stop of it (M5).
    def observe(event)
      case event[:type]
      when :tool_call_completed then @watch.observe(event) unless TaskWatch.mode == "off"
      when :turn_started then @watch.turn_started
      when :turn_canceled then @watch.turn_canceled(event[:cancellation_reason])
      end
    end

    # Whether a finished task would start a wake turn now: the Engine skips
    # the turn-end warm-up then (next_turn_waiting).
    def due?
      TaskWatch.mode == "wake" && @watch.any? && @wakes.task_open?(awaiting_continue: @awaiting_continue.call) &&
        @watch.finished?
    end

    # The background tasks this session started that finished unseen
    # (TaskWatch#take_finished), each as a TASK FINISHED note
    # (TaskFinishNote): the first one not note-only starts a wake turn from
    # task:<id> when session.task_wakes is wake, nothing is queued, no exit
    # was asked for and the wake budget is open (WorkerWakes#task_open?);
    # the others, and every one otherwise, are plain notes for the next
    # turn (M2). A spent budget is announced once.
    # @return [WorkerInbound::TaskWake, nil] the wake turn to run now
    def take
      return nil if @wakes.in_grace? || !@watch.any?

      finished = take_finished
      return nil if finished.empty?

      waking = finished.find { |entry, _| !entry.note_only } if wake_open?
      task_wake = note_finished(finished, waking: waking)
      return nil if task_wake == :failed

      @save.call
      return task_wake if task_wake

      budget_notice(finished.count { |entry, _| !entry.note_only }) if TaskWatch.mode == "wake" && @wakes.spent?
      nil
    end

    # Before a prompt's turn: the finished tasks join it as plain notes.
    def absorb
      return unless @watch.any?

      finished = take_finished
      return if finished.empty?
      return if note_finished(finished) == :failed

      @save.call
    end

    private

    # Each finished task's note into the conversation: +waking+'s as the
    # wake turn's start, the others plain. A note that can't be written (a
    # log that can't be read, say) puts it and the ones after it back in
    # the watch for the next look.
    # @return [WorkerInbound::TaskWake, nil, :failed]
    def note_finished(finished, waking: nil)
      written = []
      (finished - [waking]).each do |entry, record|
        add_note(entry, record)
        written << entry
      end
      waking && add_wake_note(*waking)
    rescue StandardError => e
      Log.warn(:worker, "task_note_failed", error: e.class.name, msg: e.message)
      @watch.put_back(finished.map(&:first) - written)
      :failed
    end

    # Only the tasks the conversation still holds (a !rollback, a restored
    # turn may have dropped the result that started one). A failure to
    # read them is logged: they wait for the next look.
    def take_finished
      @watch.take_finished(keep: Tools::TaskRuntime.created_ids_in(@engine.messages_checkpoint))
    rescue StandardError => e
      Log.warn(:worker, "task_watch_failed", error: e.class.name, msg: e.message)
      []
    end

    def wake_open?
      TaskWatch.mode == "wake" && @idle.call && @wakes.task_open?(awaiting_continue: @awaiting_continue.call)
    end

    def note(entry, record, wake:, turn_id: nil)
      TaskFinishNote.note(record, limit_sec: entry.limit_sec, wake: wake, turn_id: turn_id,
                                  cap: KernelLoop.resolve_output_char_cap(nil))
    end

    def add_note(entry, record)
      @engine.add_context_note(@session, note(entry, record, wake: false))
    end

    # The wake note, in the conversation as the wake turn's first message
    # (before TurnFlow#before_prompt_turn, so a restore keeps it).
    # @return [WorkerInbound::TaskWake]
    def add_wake_note(entry, record)
      turn_id = SecureRandom.uuid
      @engine.add_context_note(@session, note(entry, record, wake: true, turn_id: turn_id))
      WorkerInbound::TaskWake.new(ids: [entry.id], turn_id: turn_id, plain_note: note(entry, record, wake: false))
    end

    # The wake budget is spent: the UIs hear once that finished tasks wait
    # as notes (one notice per stretch, shared with the other kinds).
    def budget_notice(count)
      return unless count.positive? && @wakes.notice_budget!

      @engine.announce(type: :hook_notice, hook: "task", level: :info, between_turns: true,
                       text: "#{count} finished background task#{"s" if count != 1} noted; the model reads " \
                             "#{count == 1 ? "it" : "them"} with your next message " \
                             "(#{@wakes.max} wake turn#{"s" if @wakes.max != 1} in a row, #{ChildRing::MAX_WAKES_KEY})")
    end
  end
end
