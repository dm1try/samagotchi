# frozen_string_literal: true

require_relative "session"
require_relative "session_inbox"
require_relative "session_manager"

module Samagotchi
  # `chi note`: push text into sessions as a context note (background the
  # model sees on its next turn), never as a prompt; nothing wakes. For a
  # script, e.g. an Automator action:
  #   pbpaste | chi note --source slack $(chi sessions list --live --scope=all --format tsv | cut -f1)
  class NoteCommand
    USAGE = <<~TEXT
      Usage: chi note [--source NAME] [-m TEXT] (ID|PREFIX)... | --all
        Adds TEXT (or stdin) to each session as a context note: background
        the model sees on its next turn, not a prompt. It starts no turn.
        --source NAME  where it came from, shown to the model (default: cli)
        -m TEXT        the note; without it, stdin is read
        --all          every session a worker runs now, in every project
        Find ids with: chi sessions list --live [--scope=all] [--format tsv]
    TEXT

    # @param argv [Array<String>] the arguments after "note"
    def initialize(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr, state_dir: nil)
      @argv = argv.dup
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @state_dir = state_dir || Session.default_state_dir
    end

    # @return [Integer] exit status: 0 all queued, 1 any refused or failed,
    #   2 usage
    def run
      options = parse or return 2
      return 0 if options[:help]

      text = utf8(options[:text] || read_stdin)
      unless text
        usage_error("no note text: pass -m TEXT or pipe it in")
        return 2
      end
      begin
        text = SessionInbox.checked_text(text)
      rescue SessionInbox::NoteRejected => e
        @stderr.puts("chi note: #{e.message}")
        return 1
      end

      return deliver_to_live(text, options[:source]) if options[:all]

      # One id at a time, so each line follows the order of the ids given.
      seen = {}
      results = options[:ids].uniq.map do |given|
        id = resolve(given)
        next false unless id
        next true if seen[id]

        seen[id] = true
        deliver(id, text, options[:source])
      end
      results.all? ? 0 : 1
    end

    private

    def parse
      options = { source: "cli", ids: [] }
      until @argv.empty?
        arg = @argv.shift
        case arg
        when "-h", "--help", "help"
          @stdout.puts(USAGE)
          return { help: true }
        when "--all" then options[:all] = true
        when "--source", "-m", "--message"
          value = @argv.shift or return usage_error("#{arg} needs a value")
          options[arg == "--source" ? :source : :text] = value
        when /\A--source=(.*)\z/m then options[:source] = Regexp.last_match(1)
        when /\A--message=(.*)\z/m then options[:text] = Regexp.last_match(1)
        when /\A-/ then return usage_error("unknown option #{arg}")
        else options[:ids] << arg
        end
      end
      return usage_error("give session ids or --all") if options[:ids].empty? && !options[:all]
      return usage_error("--all takes no ids") if options[:all] && options[:ids].any?

      options
    end

    # Only a pipe or a file is read, as chi send does. A terminal means
    # nobody piped a note in, and a socket a launcher or an agent's shell
    # passes down may never close: waiting on either would hang a script.
    def read_stdin
      return nil if @stdin.respond_to?(:tty?) && @stdin.tty?
      if @stdin.respond_to?(:stat)
        stat = @stdin.stat
        return nil unless stat.pipe? || stat.file?
      end

      @stdin.read
    end

    # --all: every live session. @return [Integer] exit status
    def deliver_to_live(text, source)
      ids = SessionManager.session_summaries(live: true, include_tests: Session.test_session_env?,
                                             state_dir: @state_dir).map { |s| s[:id] }
      if ids.empty?
        error_line("chi note: no live sessions (chi sessions list --live --scope=all)")
        return 1
      end

      ids.map { |id| deliver(id, text, source) }.all? ? 0 : 1
    end

    def resolve(given)
      id = Session.resolve_id(given, state_dir: @state_dir)
      Session.load(id, state_dir: @state_dir)
      id
    rescue ArgumentError => e
      message = e.is_a?(Session::AmbiguousId) ? e.message : "no session #{given}"
      error_line("chi note: #{message}")
      nil
    end

    # @return [Boolean] whether the note was queued
    def deliver(id, text, source)
      short = id[0, 8]
      owner = SessionManager.session_owner(id, state_dir: @state_dir)
      if owner && owner["kind"] == "tui"
        @stdout.puts("#{short}  refused: it is open in a chi REPL; notes need attached mode")
        return false
      end

      path = SessionInbox.write_note(id, text: text, source: source, state_dir: @state_dir)
      if owner
        @stdout.puts("#{short}  queued: its worker adds it within a few seconds")
      else
        queued = SessionInbox.find_new_note_files(File.dirname(File.dirname(path))).size
        @stdout.puts("#{short}  waits for the session's next start (#{queued} #{queued == 1 ? "note" : "notes"} queued)")
      end
      true
    end

    # The note as UTF-8 whatever the locale says: with no LANG/LC_* (an app
    # started from Finder, launchd) stdin reads as US-ASCII and ARGV as
    # binary. Invalid bytes become U+FFFD rather than an error.
    def utf8(text)
      text&.dup&.force_encoding(Encoding::UTF_8)&.scrub
    end

    # stderr isn't buffered, stdout is when it's a pipe: flush the lines
    # already printed, so the output keeps the order of the ids given.
    def error_line(text)
      @stdout.flush
      @stderr.puts(text)
    end

    def usage_error(message)
      error_line("chi note: #{message}")
      @stderr.puts(USAGE)
      nil
    end
  end
end
