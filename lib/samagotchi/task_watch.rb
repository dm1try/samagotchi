# frozen_string_literal: true

require_relative "log"
require_relative "tools/task_runtime"

module Samagotchi
  # The background tasks a worker's session started that the model hasn't
  # seen finish (docs/internals/background-tasks.md, Finish wake). Held by
  # the Worker (the --no-shared REPL has none) and fed by the Engine's raw
  # :tool_call_completed events (#observe), the input Bridge#own_task_ids
  # reads too; the idle loop takes the finished ones (#take_finished) for a
  # wake turn or a plain note. In memory only: a crash loses them, and they
  # behave as before (the model sees them at its next look).
  #
  # Thread-safe: the turn thread feeds it, the loop's thread takes from it,
  # and anytime commands run on threads of their own.
  class TaskWatch
    # A watched task: +limit_sec+, the limit an execute handed it over at
    # (nil for task_create's); +note_only+, the user stopped the turn that
    # started or waited on it (M5): its finish is a plain note, no wake.
    Entry = Data.define(:id, :limit_sec, :note_only) do
      def initialize(id:, limit_sec: nil, note_only: false) = super
    end

    # The cancel reasons that are the user's own Stop (Bridge::CANCEL_REASONS
    # less session_stopped, and the TUI's ctrl_c).
    USER_CANCEL_REASONS = %i[manual user ctrl_c].freeze

    # The first line of a task tool's result, after a gate-corrected call's
    # "ran as: …" line and the optional "[tool]" lead.
    TASK_LINE = /\A#{Tools::TaskRuntime::RAN_AS_LINE}(?:\[task_(?:wait|get|stop)\]\n)?task_id: (\S+)/
    LOOK_TOOLS = %w[task_wait task_get task_stop].freeze
    HANDED_OVER_LIMIT = /#{Regexp.escape(Tools::Execute::HANDED_OVER)} (\d+)s limit/

    def initialize
      @mutex = Mutex.new
      @entries = {}
      @turn_ids = []
    end

    # A raw Engine event: a result that started a task adds it, one that
    # shows the model the task's end removes it (#seen_id).
    def observe(event)
      return unless event[:type] == :tool_call_completed

      tool = event[:tool].to_s
      output = event[:output].to_s
      output = output.scrub unless output.valid_encoding?
      if (id = Tools::TaskRuntime.created_id(tool, output))
        add(id, limit_sec: tool == Tools::Execute::NAME ? output[HANDED_OVER_LIMIT, 1]&.to_i : nil)
      elsif LOOK_TOOLS.include?(tool) && (id = output[TASK_LINE, 1])
        touched(id)
        remove(id) if seen?(tool, output)
      end
    end

    def add(id, limit_sec: nil)
      @mutex.synchronize do
        @entries[id] = Entry.new(id: id, limit_sec: limit_sec)
        @turn_ids << id
      end
    end

    def remove(id)
      @mutex.synchronize { @entries.delete(id) }
    end

    # A turn begins: the tasks it starts or waits on are its own (#turn_canceled).
    def turn_started
      @mutex.synchronize { @turn_ids = [] }
    end

    # A turn ended canceled for +reason+: the user's Stop makes that turn's
    # tasks note-only (M5); a signal's, a hook's or a session stop's don't.
    def turn_canceled(reason)
      return unless USER_CANCEL_REASONS.include?(reason&.to_sym)

      @mutex.synchronize do
        @turn_ids.each { |id| @entries[id] &&= @entries[id].with(note_only: true) }
      end
    end

    def ids = @mutex.synchronize { @entries.keys }

    def entry(id) = @mutex.synchronize { @entries[id] }

    def any? = @mutex.synchronize { @entries.any? }

    # The watched tasks that finished, taken out of the watch with their
    # records ([Entry, TaskRecord], oldest first). One the user stopped (the
    # web's stop-task button) or whose record is gone is dropped, not
    # returned. +keep+: the ids the conversation still holds
    # (TaskRuntime.created_ids_in): a !rollback or a restored turn may have
    # dropped the result that added one, which is dropped too. One `ps` per
    # running task (TaskRuntime.get_record); nothing with an empty watch.
    # @return [Array<Array(Entry, Tools::TaskRecord)>]
    def take_finished(keep: nil)
      entries = @mutex.synchronize { @entries.values }
      return [] if entries.empty?

      entries.filter_map do |entry|
        # Safe for any llm_context strategy: stale and forget stubs are drawn
        # in the view sent to the model (LLMContextView, the entry's edits),
        # never written over the saved tool_response text; only a !rollback
        # or a restored turn takes the result that names the id out.
        next drop(entry, log: "not_in_conversation") if keep && !keep.include?(entry.id)

        record, error = Tools::TaskRuntime.get_record(entry.id)
        next drop(entry) if error || record.nil?
        next nil if record.running?
        # Removed by a look meanwhile (a task_wait on an anytime command's thread).
        next nil unless drop(entry, kept: true)
        next nil if record.stopped_by_user?

        [entry, record]
      end
    end

    # The watched tasks still running ({id:, command:}), for the idle exit
    # and /exit (WorkerIdleExit's running_tasks).
    # @return [Array<Hash>]
    def running
      ids.filter_map do |id|
        record, = Tools::TaskRuntime.get_record(id)
        { id: id, command: record.command.to_s } if record&.running?
      end
    end

    private

    # Removes +entry+; nil (a filter_map's skip), or with +kept+ whether it
    # was there. +log+: why a task leaves without a note (debug).
    def drop(entry, kept: false, log: nil)
      removed = !remove(entry.id).nil?
      Log.debug(:worker, "task_watch_dropped", task_id: entry.id, reason: log) if log && removed
      kept ? removed : nil
    end

    def touched(id)
      @mutex.synchronize { @turn_ids << id unless @turn_ids.include?(id) }
    end

    # Whether +tool+'s +output+ for a task shows the model its end:
    # task_wait's final status or a done_pattern match (D5), task_get's
    # final status (the status alone is enough), any task_stop.
    def seen?(tool, output)
      status = output[/^status: (\S+)/, 1]
      case tool
      when "task_stop" then true
      when "task_get" then final?(status)
      when "task_wait" then final?(status) || output.match?(/^wait_result: pattern_matched$/)
      else false
      end
    end

    def final?(status) = !status.nil? && status != "running"
  end
end
