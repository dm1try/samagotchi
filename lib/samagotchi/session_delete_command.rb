# frozen_string_literal: true

require_relative "session"
require_relative "session_manager"
require_relative "cli/command"
require_relative "cli/flags"
require_relative "session_access/local"

module Samagotchi
  # `chi sessions delete`: remove sessions for good (SessionManager.delete_session),
  # one line per id. A live worker's session is refused unless --force stops
  # the worker first; a one-turn chi run's never is.
  class SessionDeleteCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi sessions delete [--force] [--chain] [--stop-tasks] [--dry-run] (ID|PREFIX)...
        Deletes each session: its history, notes, images and queued input.
        This can't be undone. Deleting a chain's newest link undoes its
        continue: the previous link comes back to the lists (not started),
        with the delegates and notes that had moved on.
        -f, --force   stop a session's running worker first (without it,
                      a live session is refused); a session in a one-turn
                      chi run (chi --non-interactive) is always refused
        --chain       delete every link of the session's chain, with their
                      delegates; running delegates are left running
        --stop-tasks  stop the background tasks the deleted sessions started
                      (TERM, then KILL), then delete; without it a session
                      whose tasks still run is refused. Not --force: a live
                      worker is still refused without it
        --dry-run     print what the delete would do (what goes, what is
                      stopped first, what stays, and which of --force and
                      --stop-tasks it needs) and delete nothing; exits 1
                      when it would be refused
    TEXT
    PREVIEW_LIMIT = 60
    FLAGS = CLI::Flags.new(help: CLI::Command::HELP_WORDS) do |f|
      f.switch "-f", "--force"
      f.switch "--chain"
      f.switch "--stop-tasks"
      f.switch "--dry-run"
    end
    # The width of a --dry-run row's key ("stopped first: ").
    ROW_KEY = 15

    # @param argv [Array<String>] the arguments after "sessions delete"
    # @param access [SessionAccess::Local, nil] where the sessions are;
    #   default this machine's, in +state_dir+
    def initialize(argv, stdout: $stdout, stderr: $stderr, state_dir: nil, access: nil)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @state_dir = state_dir || Session.default_state_dir
      @access = access || SessionAccess::Local.new(state_dir: @state_dir)
    end

    # @return [Integer] exit status: 0 all deleted, 1 any refused or
    #   unknown, 2 usage; with --dry-run 0 when each would go, 1 when any
    #   would be refused or is unknown
    def run
      options = parse
      return options if options.is_a?(Integer)
      return options[:ids].uniq.map { |given| dry_run(given, chain: options[:chain]) }.all? ? 0 : 1 if options[:dry_run]

      gone = options[:ids].uniq.map do |given|
        how = { force: options[:force], stop_tasks: options[:stop_tasks] }
        options[:chain] ? delete_chain(given, **how) : delete(given, **how)
      end
      gone.all? ? 0 : 1
    end

    private

    def command_name = "chi sessions delete"

    # @return [Hash, Integer] the options, or the exit status after the
    #   help or a usage error
    def parse
      parsed = parse_flags(FLAGS, @argv, force: false, chain: false, stop_tasks: false, dry_run: false)
      return parsed if parsed.is_a?(Integer)
      return usage_error("give session ids") if parsed.args.empty?

      parsed.options.merge(ids: parsed.args)
    end

    # @return [Boolean] whether the session is gone
    def delete(given, force:, stop_tasks: false)
      id = @access.resolve_id(given)
      short = id[0, 8]
      preview = preview_of(id)
      result = stop_tasks ? @access.delete(id, force: force, stop_tasks: true) : @access.delete(id, force: force)
      @stdout.puts(["#{short}  deleted#{notes(result)}#{revived(result)}#{delegates(result, id)}", preview].compact.join("  "))
      true
    rescue SessionManager::OwnedByTUI, SessionManager::DeleteRefused => e
      refused(e.session_id && e.session_id != id ? e.session_id[0, 8] : short, e)
    rescue ArgumentError => e
      error_line("chi sessions delete: #{e.message}")
      false
    rescue SystemCallError => e
      @stdout.puts("#{short}  failed: #{e.message}")
      false
    end

    # " (stopped its worker; stopped 2 background tasks)", or "".
    def notes(result, worker: result[:stopped] == true)
      words = []
      words << "stopped its worker" if worker
      words.concat(SessionManager::RunningTasks.stop_words(result))
      words.empty? ? "" : " (#{words.join("; ")})"
    end

    # "; the previous link 1a2b3c4d is back in the lists" (D1), with the
    # delegates that went back to it.
    def revived(result)
      back = Array(result[:unarchived]).first
      return "" unless back

      moved = Array(result[:moved_back]).size
      "; the previous link #{back[0, 8]} is back in the lists" \
        "#{" with #{moved} delegate#{"s" unless moved == 1}" if moved.positive?}"
    end

    # "; 2 delegates deleted with it; 1 left running: 9d0e1f2a" (D7, a
    # chained link's own delegates).
    def delegates(result, id)
      gone = Array(result[:deleted]).size - (Array(result[:deleted]).include?(id) ? 1 : 0)
      running = Array(result[:left_running])
      words = []
      words << "#{gone} delegate#{"s" unless gone == 1} deleted with it" if gone.positive?
      words << "#{running.size} left running: #{running.map { |sid| sid[0, 8] }.join(", ")}" unless running.empty?
      words.empty? ? "" : "; #{words.join("; ")}"
    end

    # --chain: one line per link deleted, then a summary.
    # @return [Boolean] whether every link went
    def delete_chain(given, force:, stop_tasks: false)
      id = @access.resolve_id(given)
      result = stop_tasks ? @access.delete_chain(id, force: force, stop_tasks: true) : @access.delete_chain(id, force: force)
      result[:deleted].each do |sid|
        @stdout.puts("#{sid[0, 8]}  deleted#{notes(tasks_of(result, sid), worker: result[:stopped].include?(sid))}")
      end
      @stdout.puts(chain_summary(result))
      result[:left].empty?
    rescue SessionManager::OwnedByTUI, SessionManager::DeleteRefused => e
      refused((e.session_id || id).to_s[0, 8], e)
    rescue ArgumentError => e
      error_line("chi sessions delete: #{e.message}")
      false
    end

    # +result+'s task lists cut to the ones session +sid+ started.
    def tasks_of(result, sid)
      %i[tasks_stopped tasks_not_stopped].to_h do |key|
        [key, Array(result[key]).select { |task| task.session_id == sid }]
      end
    end

    def chain_summary(result)
      parts = ["#{result[:deleted].size} deleted"]
      parts << "#{result[:left].size} links kept: #{result[:refusal]}" unless result[:left].empty?
      parts << "back in the lists: #{result[:unarchived].map { |sid| sid[0, 8] }.join(", ")}" unless result[:unarchived].empty?
      unless result[:left_running].empty?
        parts << "left running, without a parent: #{result[:left_running].map { |sid| sid[0, 8] }.join(", ")}"
      end
      parts << "earlier links, cut off by a deleted link, are kept (archived)" if result[:cut_off]
      "chain: #{parts.join("; ")}"
    end

    # @return [false]
    def refused(short, error)
      line = case error
             when SessionManager::OwnedByTUI then "it is #{OwnerLock::TUI_BUSY}; let it finish first"
             else
               case error.reason
               when :still_stopping then "its worker is still shutting down; try again in a moment"
               when :worker_running then "its worker is running (--force stops it first)"
               when :tasks_running then "#{error.message} (#{SessionManager::RunningTasks.hint(nil, "delete", short)})"
               else error.message
               end
             end
      @stdout.puts("#{short}  refused: #{line}")
      false
    end

    # --dry-run: the plan the delete (+chain+: of the whole chain) would
    # follow now, as the web's sheet says it; nothing is deleted.
    # @return [Boolean] whether it would go (no refusal)
    def dry_run(given, chain:)
      id = @access.resolve_id(given)
      plan = @access.delete_plan(id)
      choice = chain && plan.chain ? plan.chain : plan.link
      short = id[0, 8]
      title = preview_of(id)
      if choice.refusal
        @stdout.puts(["#{short}  would be refused: #{refusal_words(choice.refusal, short)}", title && "\"#{title}\""].compact.join("  "))
        return false
      end

      head = "would delete#{plan_scope(plan, choice)}"
      @stdout.puts(["#{short}  #{head}", title && "\"#{title}\""].compact.join("  "))
      plan_rows(choice, id).each { |key, words| @stdout.puts("#{" " * 10}#{"#{key}:".ljust(ROW_KEY)}#{words}") }
      true
    rescue ArgumentError => e
      error_line("chi sessions delete: #{e.message}")
      false
    end

    # " its chain (3 links)", " link 2 of 3", or "" for a session in no chain.
    def plan_scope(plan, choice)
      return "" unless plan.chained
      return " its chain (#{choice.links} links)" if choice.equal?(plan.chain)

      " link #{plan.position} of #{plan.size}"
    end

    # The rows that apply, in the sheet's order: back (the undo), goes,
    # stopped first, stays; the flags the delete needs end the stopped
    # first row (or the stays row: a task chi can't verify still needs
    # --stop-tasks, which never signals it).
    # @return [Array(String, String)] key, words
    def plan_rows(choice, id)
      rows = [["back", back_words(choice)], ["goes", goes_words(choice)], ["stopped first", stopped_words(choice, id)],
              ["stays", stays_words(choice, id)]].reject { |_, words| words.empty? }
      needs = []
      needs << "--force" if choice.workers.positive?
      needs << "--stop-tasks" unless choice.tasks.empty?
      return rows if needs.empty?

      at = rows.index { |key, _| key == "stopped first" } || rows.index { |key, _| key == "stays" }
      rows[at][1] = "#{rows[at][1]} — needs #{needs.join(", ")}"
      rows
    end

    def back_words(choice)
      return "" unless choice.previous_id

      "the previous link #{choice.previous_id[0, 8]} comes back to the lists (not started)" \
        "#{", with #{counted(choice.moved, "delegate")}" if choice.moved.positive?}"
    end

    def goes_words(choice)
      parts = []
      parts << "all #{choice.links} links" if choice.links > 1
      parts << "#{counted(choice.delete.size, "stopped delegate")} (#{short_ids(choice.delete)})" unless choice.delete.empty?
      parts.join("; ")
    end

    def stopped_words(choice, id)
      parts = []
      parts << worker_words(choice) if choice.workers.positive?
      running = choice.tasks.running
      parts << "#{counted(running.size, "background task")} (#{task_names(running, id)})" unless running.empty?
      parts.join("; ")
    end

    def worker_words(choice)
      if choice.links == 1 then choice.turns.positive? ? "its running turn" : "its worker"
      else
        "#{counted(choice.workers, "worker")}#{" (#{choice.turns} running a turn)" if choice.turns.positive?}"
      end
    end

    def stays_words(choice, id)
      parts = []
      running, under = choice.leave.partition(&:running)
      unless running.empty?
        with = " with #{running.size == 1 ? "its" : "their"} #{counted(under.size, "delegate")}" unless under.empty?
        parts << "#{counted(running.size, "running delegate")} (#{short_ids(running.map(&:id))})#{with}, without a parent"
      end
      doubtful = choice.tasks.unverified + choice.tasks.unreadable
      unless doubtful.empty?
        parts << "#{counted(doubtful.size, "task")} chi can't verify (#{task_names(doubtful, id, short: true)}), left as it is"
      end
      parts.join("; ")
    end

    # Each task by its command (+short+: by its id), "9d0e1f2a: rspec" for
    # another session's, cut to three, then "+N more".
    def task_names(tasks, id, short: false)
      tasks_module = SessionManager::RunningTasks
      names = tasks.map do |task|
        name = short ? "task #{tasks_module.short_task(task.id)}" : tasks_module.command_name(task)
        task.session_id == id ? name : "#{task.session_id[0, 8]}: #{name}"
      end
      tasks_module.cut(names)
    end

    def short_ids(ids) = SessionManager::RunningTasks.cut(ids.map { |sid| sid[0, 8] })

    def counted(count, noun) = "#{count} #{noun}#{"s" unless count == 1}"

    # The refusal the plan carries, in the words the delete's own
    # refusal line uses.
    def refusal_words(refusal, short)
      case refusal.reason
      when "owned_by_tui" then "it is #{OwnerLock::TUI_BUSY}; let it finish first"
      when "tasks_running" then "#{refusal.message} (#{SessionManager::RunningTasks.hint(nil, "delete", short)})"
      else refusal.message
      end
    end

    def preview_of(id)
      text = @access.show(id).display_title.gsub(/\s+/, " ").strip
      return nil if text.empty?

      text.length > PREVIEW_LIMIT ? "#{text[0, PREVIEW_LIMIT - 1]}…" : text
    rescue ArgumentError, JSON::ParserError
      nil
    end
  end
end
