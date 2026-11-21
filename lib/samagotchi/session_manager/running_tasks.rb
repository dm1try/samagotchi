# frozen_string_literal: true

require "json"
require_relative "../log"
require_relative "../process_group"
require_relative "../session"
require_relative "../task_files"
require_relative "../task_transcript"
require_relative "../tools/task_record"

module Samagotchi
  class SessionManager
    # The background tasks a session started that still run (its
    # task_create tasks and the executes it handed over), and the one rule a
    # delete, an archive and restart's fallback apply to them: with doubt,
    # ask, and never kill. Read from disk only (the session file, then each
    # task.json under its working directory), so an old worker needs
    # nothing. Stopping loads Tools::TaskRuntime at call time.
    # See docs/internals/background-tasks.md.
    module RunningTasks
      # One task a session started: +root+ is the session's working
      # directory (where tmp/tasks is), nil when rebuilt from a 409 body.
      RunningTask = Data.define(:session_id, :id, :command, :root) do
        def initialize(session_id:, id:, command: nil, root: nil) = super

        # The wire form (no root: chi web's folders are its own business).
        def to_wire = { "session_id" => session_id, "id" => id, "command" => command }

        def self.from_wire(data)
          data = {} unless data.is_a?(Hash)
          new(session_id: data["session_id"].to_s, id: data["id"].to_s, command: data["command"])
        end
      end

      # What #of found: +running+ (verified: the pid still leads the group
      # chi started, at the start time it read then), +unverified+ (a pid
      # that leads a group, with no start time to compare: a record from
      # before 2026-10-09, or a ps that read nothing now) and +unreadable+
      # (a task.json that can't be read). Each is an Array<RunningTask>.
      Listing = Data.define(:running, :unverified, :unreadable) do
        def initialize(running: [], unverified: [], unreadable: []) = super

        def empty? = running.empty? && unverified.empty? && unreadable.empty?
        def all = running + unverified + unreadable
        def size = all.size

        def to_wire = to_h.transform_keys(&:to_s).transform_values { |tasks| tasks.map(&:to_wire) }

        def self.from_wire(data)
          data = {} unless data.is_a?(Hash)
          new(**members.to_h { |key| [key, Array(data[key.to_s]).map { |task| RunningTask.from_wire(task) }] })
        end
      end

      EMPTY = Listing.new

      # What one op's stops came to, one outcome per task (the first one
      # wins: a stop thread that answers after the deadline doesn't change
      # an +unconfirmed+): :stopped (the record now says stopped), :ended
      # (it had already finished, or its pid isn't chi's any more),
      # :failed (an error), :unconfirmed (the wait ran out), :unverified
      # and :unreadable (never signalled). All but :stopped and :ended are
      # "not stopped".
      class Tally
        Outcome = Data.define(:task, :outcome, :error)
        NOT_STOPPED = %i[failed unconfirmed unverified unreadable].freeze

        def initialize
          @lock = Mutex.new
          @outcomes = {}
        end

        def add(task, outcome, error = nil)
          @lock.synchronize { @outcomes[[task.session_id, task.id]] ||= Outcome.new(task: task, outcome: outcome, error: error) }
        end

        def outcomes = @lock.synchronize { @outcomes.values }
        def stopped = pick(:stopped)
        def ended = pick(:ended)
        def not_stopped = outcomes.select { |o| NOT_STOPPED.include?(o.outcome) }.map(&:task)

        private

        def pick(kind) = outcomes.select { |o| o.outcome == kind }.map(&:task)
      end

      # How an op treats running tasks: :ignore (today's: they keep
      # running), :refuse (DeleteRefused/ArchiveRefused :tasks_running) or
      # :stop (stopped by +by+, "user", "retention" or "scratch", their
      # outcomes in +tally+). A stop with +only+ (task ids: the ones the
      # delete sheet named) refuses, :tasks_running, where it would stop a
      # verified task not in it, before anything of the op's batch goes;
      # without it (--stop-tasks, an older page) it stops whatever runs.
      Policy = Data.define(:mode, :by, :tally, :only) do
        def initialize(mode:, by:, tally:, only: nil) = super

        def self.stop(by:, only: nil) = new(mode: :stop, by: by.to_s, tally: Tally.new, only: only&.map(&:to_s)&.freeze)

        def ignore? = mode == :ignore
        def refuse? = mode == :refuse
        def stop? = mode == :stop

        # +listing+'s verified tasks this stop was not given (none without
        # +only+): the ones it refuses on. Unverified and unreadable ones are
        # never signalled, so never refused on.
        def unnamed(listing)
          return [] unless stop? && only

          listing.running.reject { |task| only.include?(task.id) }
        end

        # The result keys a delete adds for a stop: the tasks the op
        # stopped, did not stop and found ended ({} unless +stop?+, so a
        # delete's result is today's).
        def result_fields
          return {} unless tally

          { tasks_stopped: tally.stopped, tasks_not_stopped: tally.not_stopped, tasks_ended: tally.ended }
        end
      end
      Policy::IGNORE = Policy.new(mode: :ignore, by: nil, tally: nil)
      Policy::REFUSE = Policy.new(mode: :refuse, by: nil, tally: nil)

      # The words restart's hold and the refusals lead with.
      LEAD = "background tasks it started are still running"
      # How many tasks the words name before "+N more" (running_tasks.js NAMED_MAX).
      MAX_NAMED = 3
      # A task's command is cut to this many characters (running_tasks.js cutCommand).
      COMMAND_CHARS = 42
      # The log tag of a session file or task.json the check can't read.
      CHECK_FAILED = "session_task_check_failed"

      module_function

      # Whose worker a refusal says was stopped: +worker_stopped+ is false,
      # true (+session_id+'s) or a session id. nil for none.
      def stopped_worker(session_id, worker_stopped)
        return nil if worker_stopped.nil? || worker_stopped == false

        worker_stopped == true ? session_id.to_s : worker_stopped.to_s
      end

      # "; its worker was stopped" (+stopped_worker+ is +session_id+),
      # "; 9d0e1f2a's worker was stopped" (another), "" (none); with +all+
      # of more than one (an archive's tree), "; 2 workers were stopped: its
      # own, 9d0e1f2a".
      def worker_words(session_id, stopped_worker, all: [])
        return "" unless stopped_worker

        if all.size > 1
          names = all.map { |sid| sid.to_s == session_id.to_s ? "its own" : sid.to_s[0, 8] }
          return "; #{all.size} workers were stopped: #{cut(names)}"
        end
        return "; its worker was stopped" if stopped_worker == session_id.to_s

        "; #{stopped_worker[0, 8]}'s worker was stopped"
      end

      # The policy a batch's removals get once the batch was listed under its
      # locks (SessionChain::Delete): the batch's check was the last word, so
      # no id is refused after another of the batch went. A REFUSE does no
      # per-id re-check, a stop with +only+ stops what each id runs (the same
      # tally); IGNORE and a plain stop are unchanged.
      def after_check(policy)
        return Policy::IGNORE if policy.refuse?

        policy.stop? && policy.only ? policy.with(only: nil) : policy
      end

      # REFUSE's one listing of a whole batch under its locks, and a stop
      # with +only+'s: the batch's DeleteRefused :tasks_running (+refusal+
      # builds it) before anything of it goes, on any task (REFUSE) or on
      # one the stop wasn't given (Policy#unnamed). Nothing for another
      # policy.
      def refuse_batch!(ids, state_dir:, policy:, &refusal)
        return unless policy.refuse? || (policy.stop? && policy.only)

        listing = of(ids, state_dir: state_dir)
        refused = policy.refuse? ? !listing.empty? : !policy.unnamed(listing).empty?
        raise yield(listing) if refused
      end

      # The tasks the sessions +ids+ started that may still run; never
      # writes, never loads TaskRuntime. A session with no file (a folder
      # left alone) is skipped, one that can't be read too (with a warn).
      # @return [Listing]
      def of(ids, state_dir:)
        found = { running: [], unverified: [], unreadable: [] }
        Array(ids).each do |sid|
          session = readable_session(sid, state_dir)
          next unless session

          root = session.working_directory.to_s
          next if root.empty?

          TaskTranscript.created_ids_in(session.messages).each do |id|
            kind, task = classify(sid, id, root)
            found[kind] << task if kind
          end
        end
        Listing.new(**found)
      end

      # +listing+ of +ids+ when +policy+ refuses on it, raised as the op's
      # refusal (+refusal+ builds it from the listing); else the listing
      # (EMPTY unless the policy refuses: a stop lists again where it stops).
      # @return [Listing]
      def check!(ids, state_dir:, policy:, &refusal)
        return EMPTY unless policy.refuse?

        listing = of(ids, state_dir: state_dir)
        raise yield(listing) unless listing.empty?

        listing
      end

      # Stops +listing+'s verified tasks, each on its own thread under its
      # session's folder (TaskFiles.with_root), all joined against one
      # deadline; the unverified and unreadable ones are never signalled.
      # Every outcome goes into +policy.tally+. Doesn't log: the caller does,
      # with no command text (a command line can carry tokens).
      # @return [Tally]
      def stop!(listing, policy:)
        tally = policy.tally || Tally.new
        listing.unverified.each { |task| tally.add(task, :unverified) }
        listing.unreadable.each { |task| tally.add(task, :unreadable) }
        return tally if listing.running.empty?

        require_relative "../tools/task_runtime"
        runtime = Tools::TaskRuntime
        deadline = monotonic + runtime::STOP_GRACE_SEC + ProcessGroup::KILL_WAIT_SEC + 0.5
        threads = listing.running.map { |task| [task, stop_thread(task, policy.by, tally)] }
        threads.each do |task, thread|
          tally.add(task, :unconfirmed) unless thread.join([deadline - monotonic, 0].max)
        end
        tally
      end

      # Automatic cleanup logs only ids and outcome categories, never commands
      # or error text, which can contain secrets.
      def log_automatic!(policy)
        policy.tally.outcomes.each do |outcome|
          task = outcome.task
          if outcome.outcome == :stopped
            Log.info(:worker, "#{policy.by}_task_stopped", sid: task.session_id, task_id: task.id)
          elsif Tally::NOT_STOPPED.include?(outcome.outcome)
            Log.warn(:worker, "#{policy.by}_task_not_stopped", sid: task.session_id, task_id: task.id, why: outcome.outcome)
          end
        end
      end

      # One task's stop, its outcome into +tally+.
      def stop_thread(task, by, tally)
        Thread.new do
          Thread.current.report_on_exception = false
          record, error = TaskFiles.with_root(task.root) { Tools::TaskRuntime.stop_task(task.id, by: by) }
          if error
            tally.add(task, :failed, error)
          else
            tally.add(task, record&.status == "stopped" ? :stopped : :ended)
          end
        rescue StandardError => e
          tally.add(task, :failed, "#{e.class}: #{e.message}")
        end
      end

      # "background tasks it started are still running: npm run dev, rspec",
      # and for a task of another session in +tasks+ "its delegate
      # 9d0e1f2a's background tasks are still running: …" (or "link
      # 9d0e1f2a's" for one of +links+, a chain delete's other links).
      # @param tasks [Listing, Array<RunningTask>]
      def words(session_id, tasks, links: [])
        named = tasks.is_a?(Listing) ? named_tasks(tasks) : tasks.map { |task| [task, command_name(task)] }
        named.group_by { |task, _| task.session_id }.map do |sid, group|
          names = cut(group.map(&:last))
          if sid == session_id.to_s then "#{LEAD}: #{names}"
          elsif links.include?(sid) then "link #{sid[0, 8]}'s background tasks are still running: #{names}"
          else "its delegate #{sid[0, 8]}'s background tasks are still running: #{names}"
          end
        end.join("; ")
      end

      # The --stop-tasks hint after a refusal: the short form for a CLI
      # line (+via+ nil), the full command (ChiInvocation) for a terminal's.
      def hint(via, op, id)
        return "--stop-tasks stops them first" unless via

        "#{via.command("sessions #{op} --stop-tasks #{id}")} stops them first"
      end

      # What a delete/archive line adds for a stop: "stopped 2 background
      # tasks", "1 not stopped: task 3f9a2c1d (may still be running)";
      # empty when nothing was stopped or left.
      # @return [Array<String>]
      def stop_words(result)
        stopped = Array(result[:tasks_stopped])
        left = Array(result[:tasks_not_stopped])
        parts = []
        parts << "stopped #{stopped.size} background task#{"s" unless stopped.size == 1}" unless stopped.empty?
        parts << "#{left.size} not stopped: #{cut(left.map { |task| command_name(task) })}" unless left.empty?
        parts
      end

      # Each task of +listing+ with the name the words give it.
      def named_tasks(listing)
        listing.running.map { |task| [task, command_name(task)] } +
          listing.unverified.map { |task| [task, "task #{short_task(task.id)} (may still be running)"] } +
          listing.unreadable.map { |task| [task, "task #{short_task(task.id)} (record unreadable)"] }
      end

      def command_name(task)
        command = task.command.to_s.strip.gsub(/\s+/, " ")
        return "task #{short_task(task.id)}" if command.empty?

        command.length > COMMAND_CHARS ? "#{command[0, COMMAND_CHARS]}…" : command
      end

      # A task id's hex part (20261027123456-3f9a2c1d → 3f9a2c1d).
      def short_task(id) = id.to_s.split("-").last.to_s[0, 8]

      def cut(names)
        return names.join(", ") if names.size <= MAX_NAMED

        "#{names.first(MAX_NAMED).join(", ")} +#{names.size - MAX_NAMED} more"
      end

      def readable_session(sid, state_dir)
        Session.load(sid, state_dir: state_dir)
      rescue Session::NotFound
        nil
      rescue ArgumentError, SystemCallError => e
        Log.warn(:worker, CHECK_FAILED, sid: sid, error: e.class.name)
        nil
      end

      # [kind, RunningTask] for a task that may still run, else nil.
      def classify(sid, id, root)
        return nil unless TaskFiles::TASK_ID.match?(id)

        path = File.join(root, TaskFiles::TASKS_DIR, id, TaskFiles::METADATA_FILENAME)
        return nil unless File.file?(path)

        record = Tools::TaskRecord.from_file(JSON.parse(File.read(path)))
        raise JSON::ParserError, "not a task record" unless record
        return nil unless record.running?

        kind = liveness(record)
        kind && [kind, RunningTask.new(session_id: sid, id: id, command: record.command.to_s, root: root)]
      rescue JSON::ParserError, SystemCallError => e
        Log.warn(:worker, CHECK_FAILED, sid: sid, task_id: id, error: e.class.name)
        [:unreadable, RunningTask.new(session_id: sid, id: id, root: root)]
      end

      # :running for a pid that leads the group chi started, at the start
      # time read then; :unverified for one that leads a group with no
      # start time to compare (none recorded, or none readable now); nil
      # for a dead pid or one another process reuses.
      def liveness(record)
        pid = record.pid
        return nil unless ProcessGroup.leader?(pid)

        started = record.pid_started
        return :unverified if started.nil?

        now = ProcessGroup.start_time(pid)
        return :unverified if now.nil?

        now == started ? :running : nil
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      private_class_method :stop_thread, :named_tasks, :command_name, :short_task, :cut, :readable_session,
                           :classify, :liveness, :monotonic
    end
  end
end
