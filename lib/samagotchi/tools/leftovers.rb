# frozen_string_literal: true

require_relative "../process_group"

module Samagotchi
  module Tools
    # What a command's shell left running once it exited (`server &`), the
    # rule execute applies (and task_create's tasks): chi holds the
    # command's logs with a shared flock across the spawn, so every process
    # the command started inherits them, and a fresh exclusive flock fails
    # while any of them still has one open (held?). A holder gets a grace,
    # then the command's group is stopped; one that left the group (setsid)
    # and still holds them is out of reach and left running; one that holds
    # none (`nohup cmd >f 2>&1 &`) was never in question.
    module Leftovers
      # How long the logs may stay held once the shell has exited.
      GRACE_SEC = 1.5
      POLL_SEC = 0.05

      # What a check found and did. +wait+: :done (nothing held, or released
      # within the grace), :grace (the grace ran out: the group was
      # stopped), :timeout (the caller's deadline), :cancelled (its Stop).
      # +leftovers+: :stopped, :detached (a holder outside the group, left
      # running) or nil (nothing to say).
      Outcome = Data.define(:wait, :leftovers)

      # The hint's two endings, by what happened to the holder.
      WHAT = { stopped: "was stopped", detached: "was left running" }.freeze
      # What each tool's hint tells the model to do instead. Never just
      # "with task_create": a `server &` there is stopped too. The task
      # side never says "use task_create" (that is how it got there), and a
      # holder left running is told how to end it.
      EXECUTE_ADVICE = "to keep a server or long job running, start it with task_create in the foreground (no `&`)"
      TASK_ADVICE = {
        stopped: "to keep one running, run it in the foreground or end the command with `wait`",
        detached: "it left the task's process group, so task_stop can't reach it: kill it if it shouldn't run; " \
                  "next time, run it in the foreground or end the command with `wait`"
      }.freeze

      module_function

      # A tool's hint for +kind+ (:stopped, :detached): +held+ names what
      # the process kept open ("the output", "the task's log"), +advice+
      # what to do instead. The wording lives here, for every tool.
      def hint(kind, held:, advice:) = "(a background process kept #{held} open and #{WHAT.fetch(kind)}; #{advice})"

      # execute's hint (Execute::BACKGROUND_HINT, BACKGROUND_DETACHED_HINT).
      def execute_hint(kind) = hint(kind, held: "the output", advice: EXECUTE_ADVICE)

      # A task's hint (TaskRuntime.leftovers_note: task_get, task_wait, the
      # finish note, task_list).
      def task_hint(kind) = hint(kind, held: "the task's log", advice: TASK_ADVICE.fetch(kind))

      # After the shell exited: a holder of +logs+ gets +grace+, then the
      # group +pgid+ is stopped (stop_group), unless the deadline or
      # +cancelled+ came first.
      # @return [Outcome]
      def check(pgid, logs, grace:, stop_grace:, poll:, deadline:, cancelled:)
        return Outcome.new(wait: :done, leftovers: nil) unless held?(logs)

        wait = await_release(logs, until_time: monotonic + grace, deadline: deadline, cancelled: cancelled, poll: poll)
        return Outcome.new(wait: wait, leftovers: nil) if wait == :done

        found = stop_group(pgid, logs, grace: stop_grace, poll: poll)
        Outcome.new(wait: wait, leftovers: wait == :grace ? found : nil)
      end

      # Stops what is left of the group +pgid+ once its leader is dead and
      # reaped: TERM, +grace+, KILL (ProcessGroup.stop, the groups its
      # members started too). Only while the group still has members: a pgid
      # isn't reused while its group has any (POSIX), so they are the
      # command's; logs held with the group empty mean a holder that left it
      # (setsid), and nothing is signalled. Done once the group is empty or
      # nothing holds the logs, so no KILL goes out to an emptied group.
      # @param kill_wait [Numeric, nil] ProcessGroup.stop's (nil: its default)
      # @return [Symbol, nil] :stopped, :detached when the logs are still
      #   held, nil when the group was empty and nothing holds them (an
      #   earlier held? that read another probe's lock: nothing to say)
      def stop_group(pgid, logs, grace:, poll:, kill_wait: nil)
        alive = ProcessGroup.group_alive?(pgid)
        if alive
          options = kill_wait ? { kill_wait: kill_wait } : {}
          ProcessGroup.stop(pgid, grace: grace, poll: poll, quiet: ProcessGroup::QUIET,
                                  stopped: -> { !ProcessGroup.group_alive?(pgid) || !held?(logs) }, **options)
        end
        return :detached if held?(logs)

        alive ? :stopped : nil
      end

      # Whether some process still has one of +paths+ open from the spawn:
      # a flock belongs to the open file description, so an exclusive try
      # fails while any inherited copy is open (~0.2 ms; no lsof, no /proc).
      def held?(paths)
        paths.any? do |path|
          File.open(path, "r") do |file|
            got = file.flock(File::LOCK_EX | File::LOCK_NB)
            file.flock(File::LOCK_UN) if got
            !got
          end
        rescue Errno::ENOENT
          false
        end
      end

      # Polls the logs until no one holds them (+until_time+), the overall
      # +deadline+ or a Stop. Returns :done, :grace, :timeout or :cancelled.
      def await_release(paths, until_time:, deadline:, cancelled:, poll: POLL_SEC)
        loop do
          return :done unless held?(paths)
          return :cancelled if cancelled.call
          return :timeout if deadline && monotonic > deadline
          return :grace if monotonic > until_time

          sleep(poll)
        end
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
