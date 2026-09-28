# frozen_string_literal: true

require_relative "session"
require_relative "session_manager"

module Samagotchi
  # `chi sessions archive|unarchive`: hide sessions from every list and keep
  # them for good, or bring them back (SessionManager.archive_session /
  # unarchive_session), one line per id. Delegated children follow their
  # parent.
  class SessionArchiveCommand
    USAGE = {
      "archive" => <<~TEXT,
        Usage: chi sessions archive (ID|PREFIX)...
          Hides each session (and its delegates) from every list and keeps it
          for good: the retention sweep never deletes it. A live worker is
          stopped first; a session running a turn, or open in a chi REPL, is
          refused. chi sessions list --archived shows them; a message you send
          to one brings it back.
      TEXT
      "unarchive" => <<~TEXT
        Usage: chi sessions unarchive (ID|PREFIX)...
          Brings archived sessions (and their delegates) back to the lists.
      TEXT
    }.freeze

    # @param action [String] "archive" or "unarchive"
    # @param argv [Array<String>] the arguments after "sessions <action>"
    def initialize(action, argv, stdout: $stdout, stderr: $stderr, state_dir: nil)
      @action = action
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @state_dir = state_dir || Session.default_state_dir
    end

    # @return [Integer] exit status: 0 all done, 1 any refused or unknown, 2 usage
    def run
      if @argv.any? { |arg| %w[-h --help help].include?(arg) }
        @stdout.puts(USAGE.fetch(@action))
        return 0
      end
      bad = @argv.find { |arg| arg.start_with?("-") }
      return usage_error(bad ? "unknown option #{bad}" : "give session ids") if bad || @argv.empty?

      @argv.uniq.map { |given| @action == "archive" ? archive(given) : unarchive(given) }.all? ? 0 : 1
    end

    private

    def archive(given)
      id = Session.resolve_id(given, state_dir: @state_dir)
      short = id[0, 8]
      result = SessionManager.archive_session(id, state_dir: @state_dir)
      if result[:archived].include?(id)
        notes = []
        notes << "stopped its worker" if result[:stopped].include?(id)
        others = result[:archived].size - 1
        notes << "and #{others} delegate#{"s" if others != 1}" if others.positive?
        @stdout.puts("#{short}  archived#{" (#{notes.join(", ")})" unless notes.empty?}")
      else
        @stdout.puts("#{short}  empty session discarded")
      end
      true
    rescue SessionManager::OwnedByTUI => e
      where = e.session_id == id ? "it is" : "a delegate of it is"
      @stdout.puts("#{short}  refused: #{where} open in a chi REPL; close it there first")
      false
    rescue SessionManager::ArchiveRefused => e
      @stdout.puts("#{short}  refused: #{e.message}")
      false
    rescue ArgumentError => e
      error_line("chi sessions archive: #{e.is_a?(Session::AmbiguousId) ? e.message : "no session #{given}"}")
      false
    rescue SystemCallError => e
      @stdout.puts("#{short}  failed: #{e.message}")
      false
    end

    def unarchive(given)
      id = Session.resolve_id(given, state_dir: @state_dir)
      short = id[0, 8]
      result = SessionManager.unarchive_session(id, state_dir: @state_dir)
      @stdout.puts(result[:unarchived].empty? ? "#{short}  not archived" : "#{short}  unarchived")
      true
    rescue ArgumentError => e
      error_line("chi sessions unarchive: #{e.is_a?(Session::AmbiguousId) ? e.message : "no session #{given}"}")
      false
    rescue SystemCallError => e
      @stdout.puts("#{short}  failed: #{e.message}")
      false
    end

    # stdout is buffered when it's a pipe: flush the lines already printed,
    # so the output keeps the order of the ids given.
    def error_line(text)
      @stdout.flush
      @stderr.puts(text)
    end

    def usage_error(message)
      error_line("chi sessions #{@action}: #{message}")
      @stderr.puts(USAGE.fetch(@action))
      2
    end
  end
end
