# frozen_string_literal: true

require_relative "session"
require_relative "session_manager"
require_relative "cli/command"
require_relative "cli/flags"
require_relative "session_access/local"

module Samagotchi
  # `chi sessions archive|unarchive`: hide sessions from every list and keep
  # them for good, or bring them back (SessionManager.archive_session /
  # unarchive_session), one line per id. Delegated children follow their
  # parent.
  class SessionArchiveCommand
    include CLI::Command

    USAGE = {
      "archive" => <<~TEXT,
        Usage: chi sessions archive [--stop-tasks] (ID|PREFIX)...
          Hides each session (and its delegates) from every list and keeps it
          for good: the retention sweep never deletes it. A live worker is
          stopped first; a session running a turn, or in a one-turn chi run, is
          refused, and so is one whose background tasks still run. chi sessions
          list --archived shows them; a message you send to one brings it back.
          --stop-tasks  stop the background tasks it and its delegates started
                        (TERM, then KILL), then archive
      TEXT
      "unarchive" => <<~TEXT
        Usage: chi sessions unarchive (ID|PREFIX)...
          Brings archived sessions (and their delegates) back to the lists.
      TEXT
    }.freeze
    # archive's flags (unarchive takes none).
    FLAGS = CLI::Flags.new(help: CLI::Command::HELP_WORDS) do |f|
      f.switch "--stop-tasks"
    end

    # @param action [String] "archive" or "unarchive"
    # @param argv [Array<String>] the arguments after "sessions <action>"
    # @param access [SessionAccess::Local, nil] where the sessions are;
    #   default this machine's, in +state_dir+
    def initialize(action, argv, stdout: $stdout, stderr: $stderr, state_dir: nil, access: nil)
      @action = action
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @state_dir = state_dir || Session.default_state_dir
      @access = access || SessionAccess::Local.new(state_dir: @state_dir)
    end

    # @return [Integer] exit status: 0 all done, 1 any refused or unknown, 2 usage
    def run
      # Help anywhere wins, even after an unknown option.
      if @argv.any? { |arg| HELP_WORDS.include?(arg) }
        @stdout.puts(usage_text)
        return 0
      end
      ids, stop_tasks = parse
      return ids if ids.is_a?(Integer)

      if ids.uniq.map { |given| @action == "archive" ? archive(given, stop_tasks: stop_tasks) : unarchive(given) }.all?
        0
      else
        1
      end
    end

    private

    # @return [Array(Array<String>, Boolean), Integer] the ids and
    #   --stop-tasks, or the usage exit status
    def parse
      if @action == "archive"
        parsed = parse_flags(FLAGS, @argv, stop_tasks: false)
        return parsed if parsed.is_a?(Integer)

        args = parsed.args
        stop_tasks = parsed.options[:stop_tasks]
      else
        args = @argv
        stop_tasks = false
      end
      bad = args.find { |arg| arg.start_with?("-") }
      return usage_error(bad ? "unknown option #{bad}" : "give session ids") if bad || args.empty?

      [args, stop_tasks]
    end

    def archive(given, stop_tasks: false)
      id = @access.resolve_id(given)
      short = id[0, 8]
      result = stop_tasks ? @access.archive(id, stop_tasks: true) : @access.archive(id)
      if result.archived.include?(id)
        notes = []
        notes << "stopped its worker" if result.stopped.include?(id)
        notes.concat(SessionManager::RunningTasks.stop_words(result.to_h))
        others = result.archived.size - 1
        notes << "and #{others} delegate#{"s" if others != 1}" if others.positive?
        @stdout.puts("#{short}  archived#{" (#{notes.join("; ")})" unless notes.empty?}")
      else
        @stdout.puts("#{short}  empty session discarded")
      end
      true
    rescue SessionManager::OwnedByTUI => e
      where = e.session_id == id ? "it is" : "a delegate of it is"
      @stdout.puts("#{short}  refused: #{where} #{OwnerLock::TUI_BUSY}; let it finish first")
      false
    rescue SessionManager::ArchiveRefused => e
      hint = " (#{SessionManager::RunningTasks.hint(nil, "archive", short)})" if e.reason == :tasks_running
      @stdout.puts("#{short}  refused: #{e.message}#{hint}")
      false
    rescue ArgumentError => e
      error_line("chi sessions archive: #{e.message}")
      false
    rescue SystemCallError => e
      @stdout.puts("#{short}  failed: #{e.message}")
      false
    end

    def unarchive(given)
      id = @access.resolve_id(given)
      short = id[0, 8]
      result = @access.unarchive(id)
      @stdout.puts(result[:unarchived].empty? ? "#{short}  not archived" : "#{short}  unarchived")
      true
    rescue ArgumentError => e
      error_line("chi sessions unarchive: #{e.message}")
      false
    rescue SystemCallError => e
      @stdout.puts("#{short}  failed: #{e.message}")
      false
    end

    def command_name = "chi sessions #{@action}"
    def usage_text = USAGE.fetch(@action)
  end
end
