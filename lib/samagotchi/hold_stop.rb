# frozen_string_literal: true

require_relative "log"
require_relative "session_manager"
require_relative "tools/task_runtime"

module Samagotchi
  # Stops what a session's user can stop themselves when they ask its worker
  # to exit: the reminders its Engine holds, the background tasks it watches
  # for a finish wake that still run, and its delegate children with a live
  # worker (docs/sessions.md, "Worker idle exit"). Called by the exit ask's
  # "stop them and exit" (Worker#exit_request with stop: true), and the same
  # step the web's Stop will use.
  #
  # What the user can't stop from here (a turn running, prompts queued, a
  # continue offer, another UI attached) is never touched: WorkerIdleExit
  # refuses the exit for those before this is called.
  class HoldStop
    # What was stopped, by kind: reminder names, task commands, children's
    # short ids. The 200's +stopped+ is this as JSON.
    Stopped = Data.define(:reminders, :tasks, :delegates) do
      def initialize(reminders: [], tasks: [], delegates: []) = super

      def any? = reminders.any? || tasks.any? || delegates.any?
    end

    # @param engine [Engine] #reminder_store
    # @param task_watch [TaskWatch, nil] this session's finish-wake watch
    #   (nil with session.task_wakes: off)
    # @param delegates [#call] the children to stop (ChildrenStatus::Child)
    # @param state_dir [String] where the child sessions live
    def initialize(engine:, task_watch:, delegates:, state_dir:)
      @engine = engine
      @task_watch = task_watch
      @delegates = delegates
      @state_dir = state_dir
    end

    # Stop every hold the user can stop, read again as it is done (one may
    # have ended in the meantime). A stop that fails is logged and left out
    # of the report.
    # @return [Stopped]
    def stop_all
      Stopped.new(reminders: stop_reminders, tasks: stop_tasks, delegates: stop_delegates)
    end

    private

    # Reminders live only in this process, so clearing the store ends them;
    # the names go to the report before it is emptied.
    def stop_reminders
      store = @engine.reminder_store
      return [] unless store

      names = store.reminders.values.map { |reminder| reminder[:name] }
      store.clear_all
      names
    end

    # The watched tasks still running, stopped the way task_stop and the
    # web's stop-task button do (TaskRuntime.stop_task, by: "user").
    def stop_tasks
      return [] unless @task_watch

      @task_watch.running.filter_map do |task|
        record, error = Tools::TaskRuntime.stop_task(task.id, by: "user")
        if record.nil?
          Log.warn(:worker, "exit_stop_task_failed", task_id: task.id, error: error.to_s)
          next nil
        end

        task.command
      end
    end

    # The delegate children, stopped as `chi sessions stop` stops a session
    # (SessionManager.stop_session: its turn canceled, its worker TERMed).
    # One owned by another terminal is left running and said so in the log.
    def stop_delegates
      @delegates.call.filter_map do |child|
        SessionManager.stop_session(child.id, state_dir: @state_dir)
        child.short_id
      rescue StandardError => e
        Log.warn(:worker, "exit_stop_delegate_failed", child: child.short_id, error: e.class.name, msg: e.message)
        nil
      end
    end
  end
end
