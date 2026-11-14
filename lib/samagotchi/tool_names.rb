# frozen_string_literal: true

module Samagotchi
  # chi's built-in tools' names, and the fixed texts some of them write into
  # their results, apart from the tool classes: the code that only names a
  # tool or matches a result to draw a row (ToolActivity, ToolView, FileRef,
  # ObjectivesBacking) reads them here and loads no tool class (Tools::Execute
  # alone brings TaskRuntime, Shell, Leftovers, the process group…).
  #
  # Each tool class keeps its own constants, read from here
  # (Tools::Execute::NAME = ToolNames::Execute::NAME): code that loads the
  # class still names them on it, and bundles do (the bundle boundary allows
  # Tools::Execute::NAME and ::HANDED_OVER; slow-commands looks Execute's stop
  # texts up by reflection). A new built-in adds its module here
  # (spec/tool_names_spec.rb holds the two in step).
  #
  # No requires: it is a leaf every client can load.
  module ToolNames
    module Execute
      NAME = "execute"
      NOT_RUN_ON_STOP = "Error: not run, the user stopped the turn"
      # The first words of a command the user's Stop killed.
      STOPPED_BY_USER = "Error: command stopped by the user"
      # The same two when a signal to chi (a worker's TERM, HUP or INT)
      # stopped the turn: its cancel reason is :signal.
      NOT_RUN_ON_SIGNAL = "Error: not run, a signal to chi stopped the turn"
      STOPPED_BY_SIGNAL = "Error: command stopped by a signal to chi"
      # The same two when a session stop (chi sessions stop, the web's stop,
      # a parent stopping its delegate) canceled the turn: :session_stopped.
      NOT_RUN_ON_SESSION_STOP = "Error: not run, the session was stopped"
      STOPPED_BY_SESSION_STOP = "Error: command stopped as the session was stopped"
      # The texts above by the stop's reason; any other is the user's Stop.
      NOT_RUN = { signal: NOT_RUN_ON_SIGNAL, session_stopped: NOT_RUN_ON_SESSION_STOP }.freeze
      STOPPED_BY = { signal: STOPPED_BY_SIGNAL, session_stopped: STOPPED_BY_SESSION_STOP }.freeze
      # The first words of a command still running and handed over as a
      # task (handed_over_line at the limit, early_handed_over_line for a
      # message). TaskRuntime.handed_over_id, the web's task_stop.js and the
      # slow-commands bundle match on them; the bundle reads only the limit's
      # form, "at the 120s limit".
      HANDED_OVER = "Still running at the"
      # What follows HANDED_OVER on the first line, as regexp source: "120s
      # limit:" (the limit) or "4s mark:" (a message from the user ended the
      # wait early). Every matcher of the line builds on it.
      HANDED_OVER_AFTER = "(?:\\d+s limit|\\d+s mark):"
    end

    module Read
      NAME = "read"
    end

    module Write
      NAME = "write"
    end

    module MemoryRead
      NAME = "memory_read"
    end

    module MemoryWrite
      NAME = "memory_write"
    end

    module Edit
      NAME = "edit"
    end

    module TaskCreate
      NAME = "task_create"
    end

    module TaskGet
      NAME = "task_get"
    end

    module TaskList
      NAME = "task_list"
    end

    module TaskStop
      NAME = "task_stop"
    end

    module TaskWait
      NAME = "task_wait"
      TIMEOUT_DEFAULT = 600
    end

    module WebFetch
      NAME = "web_fetch"
    end

    module RegisterReminder
      NAME = "register_reminder"
    end

    module CancelReminder
      NAME = "cancel_reminder"
    end

    module ListReminders
      NAME = "list_reminders"
    end

    module ScheduleTask
      NAME = "schedule_task"
    end

    module ListSchedules
      NAME = "list_schedules"
    end

    module CancelSchedule
      NAME = "cancel_schedule"
    end

    module ListSessions
      NAME = "list_sessions"
    end

    module SendNote
      NAME = "send_note"
    end

    module ContextRead
      NAME = "context_read"
    end

    module Delegate
      NAME = "delegate"
    end

    module DelegateResult
      NAME = "delegate_result"
    end

    module AskUserQuestion
      NAME = "ask_user_question"
    end

    module ObjectivesTool
      NAME = "objectives"
      PROPOSE = "propose"
      # A move's states the row shows (ObjectivesTool::STATES has progress too).
      BLOCKED = "blocked"
      DONE = "done"
    end

    module ForgetOutputs
      NAME = "forget_outputs"
    end
  end
end
